import AppCore
import AppDatabase
import XCTest

@testable import Itogo

/// Saving the editor of a saved operation — the inspector of the Transactions window, the
/// sheet of the main window. Every way to save keeps the rules of «Save», and the edit lands
/// on the operation as it is when saved, not as it was when the editor opened: the inspector
/// holds one operation while the owner works elsewhere.
@MainActor
final class TransactionEditorTests: XCTestCase {
  private var repository: TransactionRepository!
  private var references: ReferenceRepository!
  private var store: TransactionsStore!
  private var environment: AppEnvironment!
  private var stack: DatabaseStack?

  /// Built inside each test, on the main actor: the store and the editor belong there. The
  /// store writes planning too, as the app's does: a debt payment and its journal line go
  /// through it.
  private func makeStore() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    self.stack = stack
    repository = TransactionRepository(writer: stack.writer)
    references = ReferenceRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(
      repository, references: references, planning: PlanningRepository(writer: stack.writer))
    environment = AppEnvironment()
  }

  private var evening: Date {
    CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18))
      .addingTimeInterval(20 * 3600)
  }

  /// Dinner for two, Alex's half waiting to come back, as it is saved and listed.
  private func saveDinner() throws -> TransactionEntry {
    try makeStore()
    let alex = Person(name: "Alex")
    try references.save(alex)
    var draft = TransactionDraft(
      occurredAt: evening, amount: AmountE4(whole: 3_400), note: "Dinner")
    draft.parts = [
      PartDraft(amount: AmountE4(whole: 1_700)),
      PartDraft(
        amount: AmountE4(whole: 1_700), forWhom: .friends, reimbursable: true,
        debtorPersonId: alex.id),
    ]
    let dinner = try draft.materialize()
    try repository.save(dinner)
    return dinner
  }

  /// «Save» is inactive over a total of zero or parts that do not add up. The question asked
  /// when another operation is opened saves through the same model, so the model keeps the
  /// rule itself: nothing is written, and nothing is left to undo.
  func testAnOperationThatCannotBeSavedIsNotSavedAnyWay() throws {
    let dinner = try saveDinner()
    let editor = TransactionEditorModel(entry: dinner, environment: environment)

    // «0» or «100-100» in the amount of a split: the total is zero.
    editor.draft.draft.amount = .zero
    for index in editor.draft.draft.parts.indices { editor.draft.draft.parts[index].amount = .zero }
    XCTAssertTrue(editor.draft.draft.isBalanced)
    XCTAssertFalse(editor.canSave(in: store))
    XCTAssertFalse(editor.save(store: store, environment: environment))
    XCTAssertEqual(editor.errorKey, "entry.error.amountMissing")

    editor.draft.draft.amount = AmountE4(whole: 500)
    XCTAssertFalse(editor.save(store: store, environment: environment))
    XCTAssertEqual(editor.errorKey, "entry.error.notBalanced")

    let stored = try XCTUnwrap(try repository.entry(id: dinner.id))
    XCTAssertEqual(stored.transaction.amountE4, AmountE4(whole: 3_400))
    XCTAssertEqual(stored.parts.map(\.amountE4), dinner.parts.map(\.amountE4))
    XCTAssertFalse(store.canUndo)
  }

  /// The editor keeps the rules of the panel: a part below zero that still adds up, or a part
  /// paid for someone whose debtor was cleared, is refused and nothing is written.
  func testANegativePartOrAPartWithoutItsDebtorIsNotSavedFromTheEditor() throws {
    let dinner = try saveDinner()
    let editor = TransactionEditorModel(entry: dinner, environment: environment)

    editor.draft.draft.parts[0].amount = AmountE4(whole: 3_700)
    editor.draft.draft.parts[1].amount = AmountE4(whole: -300)
    XCTAssertTrue(editor.draft.draft.isBalanced)
    XCTAssertFalse(editor.canSave(in: store))
    XCTAssertFalse(editor.save(store: store, environment: environment))
    XCTAssertEqual(editor.errorKey, "entry.error.amountNotPositive")

    editor.draft.draft.parts[0].amount = AmountE4(whole: 1_700)
    editor.draft.draft.parts[1].amount = AmountE4(whole: 1_700)
    editor.draft.draft.parts[1].debtorPersonId = nil
    XCTAssertFalse(editor.canSave(in: store))
    XCTAssertFalse(editor.save(store: store, environment: environment))
    XCTAssertEqual(editor.errorKey, "entry.error.debtorMissing")

    let stored = try XCTUnwrap(try repository.entry(id: dinner.id))
    XCTAssertEqual(stored.parts.map(\.amountE4), dinner.parts.map(\.amountE4))
    XCTAssertEqual(stored.parts.map(\.debtorPersonId), dinner.parts.map(\.debtorPersonId))
    XCTAssertFalse(store.canUndo)
  }

  /// The inspector was opened on the dinner and its note changed; before «Save», Alex's half
  /// was written off in the main window. The save changes the note and leaves the part
  /// written off — writing back the «expected» of the copy the editor holds would list it
  /// as owed again. ⌘Z takes back the note, not the write-off.
  func testASaveKeepsWhatHappenedToTheOperationElsewhere() throws {
    let dinner = try saveDinner()
    let editor = TransactionEditorModel(entry: dinner, environment: environment)
    editor.draft.draft.note = "Dinner with Alex"

    try repository.writeOffPart(id: dinner.parts[1].id)
    XCTAssertTrue(editor.save(store: store, environment: environment))
    XCTAssertNil(editor.errorKey)

    let saved = try XCTUnwrap(try repository.entry(id: dinner.id))
    XCTAssertEqual(saved.transaction.note, "Dinner with Alex")
    XCTAssertEqual(saved.parts.map(\.reimbursementStatus), [nil, .writtenOff])
    XCTAssertEqual(saved.parts.map(\.id), dinner.parts.map(\.id))

    store.undo()
    let undone = try XCTUnwrap(try repository.entry(id: dinner.id))
    XCTAssertEqual(undone.transaction.note, "Dinner")
    XCTAssertEqual(undone.parts.map(\.reimbursementStatus), [nil, .writtenOff])
  }

  /// Deleted elsewhere while the editor held changes: the save is refused and says why, and
  /// the operation stays deleted instead of coming back with the old copy.
  func testAnOperationDeletedWhileItWasEditedStaysDeleted() throws {
    let dinner = try saveDinner()
    let editor = TransactionEditorModel(entry: dinner, environment: environment)
    editor.draft.draft.note = "Dinner with Alex"

    try repository.softDelete(id: dinner.id)
    XCTAssertFalse(editor.save(store: store, environment: environment))
    XCTAssertEqual(editor.errorKey, "entry.error.gone")
    XCTAssertEqual(try repository.count(), 0)
    XCTAssertFalse(store.canUndo)
  }

  /// The inspector follows the operation it holds as the data changes. With
  /// nothing typed it closes over a deleted operation and shows a changed one as it is now;
  /// with an edit typed it keeps the edit whatever happened, says the operation was deleted
  /// while it is gone, and stops saying so when it comes back.
  func testTheInspectorKeepsAnUnsavedEditOfAnOperationDeletedElsewhere() throws {
    let dinner = try saveDinner()
    var renamed = dinner
    renamed.transaction.note = "Dinner, renamed elsewhere"

    let untouched = TransactionEditorModel(entry: dinner, environment: environment)
    XCTAssertEqual(untouched.follow(dinner), .stay)
    XCTAssertEqual(untouched.follow(renamed), .reopen(renamed))
    XCTAssertEqual(untouched.follow(nil), .close)

    let edited = TransactionEditorModel(entry: dinner, environment: environment)
    edited.draft.draft.note = "Dinner with Alex"
    XCTAssertEqual(edited.follow(renamed), .stay)
    XCTAssertNil(edited.errorKey)
    XCTAssertEqual(edited.follow(nil), .stay)
    XCTAssertEqual(edited.errorKey, "entry.error.gone")
    XCTAssertEqual(edited.draft.draft.note, "Dinner with Alex")
    XCTAssertEqual(edited.follow(dinner), .stay)
    XCTAssertNil(edited.errorKey)

    // Another reason stays: it is about the edit, not about the operation being there.
    edited.errorKey = "entry.error.notBalanced"
    XCTAssertEqual(edited.follow(dinner), .stay)
    XCTAssertEqual(edited.errorKey, "entry.error.notBalanced")
  }

  /// While a large write lands off the main thread «Save» waits, as «Delete…» does: the
  /// write may be deleting this very operation, and a save queued before it would leave a
  /// step of ⌘Z above the deletion that brings the operation back. Once the deletion has
  /// landed there is nothing left to save.
  func testNothingIsSavedWhileALargeWriteLands() async throws {
    let dinner = try saveDinner()
    let start = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 1))
    let others = try (0..<TransactionsStore.backgroundThreshold).map { index in
      var draft = TransactionDraft(
        occurredAt: start.addingTimeInterval(TimeInterval(index) * 60),
        amount: AmountE4(whole: 100), note: "row \(index)")
      draft.normalizeSinglePart()
      return try draft.materialize()
    }
    try repository.insert(others)
    let editor = TransactionEditorModel(entry: dinner, environment: environment)
    editor.draft.draft.note = "Dinner with Alex"
    XCTAssertTrue(editor.canSave(in: store))

    XCTAssertTrue(store.delete(ids: [dinner.id] + others.map(\.id)))
    XCTAssertTrue(store.isWritingInBackground)
    XCTAssertFalse(editor.canSave(in: store))
    XCTAssertFalse(editor.save(store: store, environment: environment))

    let write = try XCTUnwrap(store.backgroundWrite)
    let landed = await write.value
    XCTAssertTrue(landed)
    XCTAssertEqual(try repository.count(), 0)
    XCTAssertFalse(editor.save(store: store, environment: environment))
    XCTAssertEqual(editor.errorKey, "entry.error.gone")
    XCTAssertEqual(try repository.count(), 0)

    // One step of ⌘Z — the deletion — and everything is back as it was.
    store.undo()
    let undone = try XCTUnwrap(store.backgroundWrite)
    let restored = await undone.value
    XCTAssertTrue(restored)
    XCTAssertEqual(try repository.entry(id: dinner.id)?.transaction.note, "Dinner")
    XCTAssertFalse(store.canUndo)
  }

  // MARK: Operations that move a debt

  private var noon: Date {
    environment.calendar.startOfDay(DateOnly(year: 2026, month: 9, day: 18))
      .addingTimeInterval(12 * 3600)
  }

  /// A debt, written the way the Debts section writes one.
  private func makeDebt(
    _ name: String, currency: CurrencyCode = .rub, balance: Int64 = 100_000,
    origin: DebtOrigin = .existing
  ) throws -> Debt {
    let debt = Debt(
      direction: .iOwe, type: origin == .purchase ? .installment : .loan, name: name,
      currency: currency, paymentsAreExpenses: origin == .existing, origin: origin)
    var rows = PlanningRows.empty
    rows.debts = [debt]
    if balance > 0 {
      rows.debtEntries = [
        try DebtRules.opening(
          of: debt, balance: AmountE4(whole: balance), date: DateOnly(year: 2026, month: 9, day: 1))
      ]
    }
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    return debt
  }

  /// «платёж Кредит 8500»: the operation and its journal line, in one write, as the entry
  /// line saves them (`EntryCommit`).
  private func pay(_ debt: Debt, _ amount: Int64) throws -> TransactionEntry {
    let payment = try TransactionDraft(
      occurredAt: noon, amount: AmountE4(whole: amount), note: "Loan", debtId: debt.id,
      parts: [PartDraft(amount: AmountE4(whole: amount))]
    ).materialize()
    let change = try XCTUnwrap(
      EntryCommit.change(
        entry: payment, openedCredit: nil, paidDebt: debt, expectedIncomeId: nil,
        day: environment.calendar.day(of: noon)))
    XCTAssertTrue(store.apply(change))
    return try XCTUnwrap(try repository.entry(id: payment.id))
  }

  private func balance(_ debt: Debt) throws -> AmountE4 {
    DebtRules.balance(entries: try references.debtEntries(debtId: debt.id))
  }

  private func paymentLines(_ debt: Debt) throws -> [DebtEntry] {
    try references.debtEntries(debtId: debt.id).filter { $0.transactionId != nil }
  }

  /// The payment of 8 500 corrected to 8 000 in the editor: the debt follows the operation
  /// (spec, «Платёж одновременно уменьшает долг»), and one ⌘Z brings both back.
  func testCorrectingTheAmountOfADebtPaymentMovesItsJournalLine() throws {
    try makeStore()
    let loan = try makeDebt("Loan")
    let payment = try pay(loan, 8_500)
    XCTAssertEqual(try balance(loan), AmountE4(whole: 91_500))

    let editor = TransactionEditorModel(entry: payment, environment: environment)
    editor.draft.draft.amount = AmountE4(whole: 8_000)
    editor.draft.draft.parts[0].amount = AmountE4(whole: 8_000)
    XCTAssertTrue(editor.save(store: store, environment: environment))

    XCTAssertEqual(try paymentLines(loan).map(\.amountE4), [AmountE4(whole: -8_000)])
    XCTAssertEqual(try paymentLines(loan).map(\.transactionId), [payment.id])
    XCTAssertEqual(try balance(loan), AmountE4(whole: 92_000))

    store.undo()
    XCTAssertEqual(try paymentLines(loan).map(\.amountE4), [AmountE4(whole: -8_500)])
    XCTAssertEqual(try balance(loan), AmountE4(whole: 91_500))
    XCTAssertEqual(
      try repository.entry(id: payment.id)?.transaction.amountE4, AmountE4(whole: 8_500))
  }

  /// A taxi typed as «(1000+600)/2» and corrected to 900 in the inspector: the row must not
  /// show the formula over 900 ₽ (spec, «Строка ввода»: the formula is kept in `amount_expr`).
  func testCorrectingTheAmountOfAnOperationTypedAsAFormulaDropsTheFormula() throws {
    try makeStore()
    var draft = TransactionDraft(
      occurredAt: evening, amount: AmountE4(whole: 800), amountExpression: "(1000+600)/2",
      note: "taxi")
    draft.normalizeSinglePart()
    let taxi = try draft.materialize()
    try repository.save(taxi)

    let editor = TransactionEditorModel(entry: taxi, environment: environment)
    editor.draft.setTotal(AmountE4(whole: 800), typed: "800")
    XCTAssertEqual(editor.draft.draft.amountExpression, "(1000+600)/2")
    editor.draft.setTotal(AmountE4(whole: 900), typed: "900")
    XCTAssertTrue(editor.save(store: store, environment: environment))

    let stored = try XCTUnwrap(try repository.entry(id: taxi.id)).transaction
    XCTAssertEqual(stored.amountE4, AmountE4(whole: 900))
    XCTAssertNil(stored.amountExpr)
  }

  /// Moved to another month and to another debt: the line goes with it — its date, which
  /// «paid this month» reads, and its debt — and ⌘Z puts it back on the first one.
  func testMovingADebtPaymentToAnotherDayAndDebtMovesItsJournalLine() throws {
    try makeStore()
    let loan = try makeDebt("Loan")
    let card = try makeDebt("Card", balance: 40_000)
    let payment = try pay(loan, 8_500)
    let october = DateOnly(year: 2026, month: 10, day: 3)

    let editor = TransactionEditorModel(entry: payment, environment: environment)
    editor.draft.draft.occurredAt = environment.calendar.startOfDay(october)
      .addingTimeInterval(12 * 3600)
    editor.draft.draft.debtId = card.id
    XCTAssertTrue(editor.save(store: store, environment: environment))

    XCTAssertEqual(try paymentLines(loan), [])
    XCTAssertEqual(try balance(loan), AmountE4(whole: 100_000))
    let moved = try paymentLines(card)
    XCTAssertEqual(moved.map(\.amountE4), [AmountE4(whole: -8_500)])
    XCTAssertEqual(moved.map(\.date), [october])
    XCTAssertEqual(try balance(card), AmountE4(whole: 31_500))

    store.undo()
    XCTAssertEqual(try paymentLines(card), [])
    let back = try paymentLines(loan)
    XCTAssertEqual(back.map(\.amountE4), [AmountE4(whole: -8_500)])
    XCTAssertEqual(back.map(\.date), [DateOnly(year: 2026, month: 9, day: 18)])
  }

  /// A purchase on credit corrected from 60 000 to 55 000: the debt it opened starts at the
  /// new price.
  func testCorrectingThePriceOfAPurchaseOnCreditMovesTheDebtItOpened() throws {
    try makeStore()
    let phone = Debt(
      direction: .iOwe, type: .installment, name: "Phone", paymentsAreExpenses: false,
      origin: .purchase)
    let purchase = try TransactionDraft(
      occurredAt: noon, amount: AmountE4(whole: 60_000), note: "Phone", creditDebtId: phone.id,
      parts: [PartDraft(amount: AmountE4(whole: 60_000))]
    ).materialize()
    XCTAssertTrue(
      store.apply(
        try XCTUnwrap(
          EntryCommit.change(
            entry: purchase, openedCredit: phone, paidDebt: nil, expectedIncomeId: nil,
            day: environment.calendar.day(of: noon)))))
    XCTAssertEqual(try balance(phone), AmountE4(whole: 60_000))

    let saved = try XCTUnwrap(try repository.entry(id: purchase.id))
    let editor = TransactionEditorModel(entry: saved, environment: environment)
    editor.draft.draft.amount = AmountE4(whole: 55_000)
    editor.draft.draft.parts[0].amount = AmountE4(whole: 55_000)
    XCTAssertTrue(editor.save(store: store, environment: environment))
    XCTAssertEqual(try balance(phone), AmountE4(whole: 55_000))

    store.undo()
    XCTAssertEqual(try balance(phone), AmountE4(whole: 60_000))
  }

  /// Every reason the store gives for not writing an edit is said in words, in both languages.
  func testEveryRefusalOfAnEditHasWordsInBothLanguages() {
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for refusal in EditRefusal.allCases {
        let key = TransactionEditorModel.errorKey(of: refusal)
        XCTAssertNotEqual(language(key, table: "Entry"), key, "\(choice) \(refusal)")
      }
    }
  }

  // MARK: Money given back

  /// Alex gives back 1 500 of the 1 700 of his half: the reimbursement closes the part through
  /// its link, and the 200 not returned is my spending — a shortfall written with it.
  private func recordAlexsReturn(of dinner: TransactionEntry) throws -> ReimbursementRecording {
    let owed = try XCTUnwrap(try repository.owedParts().first { $0.partId == dinner.parts[1].id })
    let recording = try ReimbursementRecording.make(
      id: UUID(), received: AmountE4(whole: 1_500), closing: [owed],
      distribution: ReimbursementDistribution(), personId: nil, now: evening,
      setting: ReimbursementRecording.Setting(
        surchargesCategoryId: nil, categories: CategoryTree(), history: .empty,
        surplusNote: "Surplus", shortfallNote: "Shortfall"))
    try repository.apply(
      recording.outcome, reimbursement: recording.reimbursement, extra: recording.extra)
    return recording
  }

  /// The links, the closed part and the shortfall were worked out from the money that came
  /// back (spec, «Возврат денег от человека»). Another amount written over the reimbursement
  /// or over its shortfall would leave all of that telling the old story: the edit is refused
  /// and says how it is done — delete the reimbursement and record it again.
  func testTheMoneyOfAReimbursementThatClosedPartsIsNotEditedInPlace() throws {
    let dinner = try saveDinner()
    let recording = try recordAlexsReturn(of: dinner)
    let reimbursement = try XCTUnwrap(try repository.entry(id: recording.reimbursement.id))
    let shortfall = try XCTUnwrap(
      try repository.entry(id: try XCTUnwrap(recording.extra.first).id))

    let editor = TransactionEditorModel(entry: reimbursement, environment: environment)
    editor.draft.draft.amount = AmountE4(whole: 1_400)
    editor.draft.draft.parts[0].amount = AmountE4(whole: 1_400)
    XCTAssertFalse(editor.save(store: store, environment: environment))
    XCTAssertEqual(editor.errorKey, "entry.error.reimbursementEdit")

    let kind = TransactionEditorModel(entry: reimbursement, environment: environment)
    kind.draft.draft.kind = .income
    XCTAssertFalse(kind.save(store: store, environment: environment))
    XCTAssertEqual(kind.errorKey, "entry.error.reimbursementEdit")

    let companion = TransactionEditorModel(entry: shortfall, environment: environment)
    companion.draft.draft.amount = AmountE4(whole: 100)
    companion.draft.draft.parts[0].amount = AmountE4(whole: 100)
    XCTAssertFalse(companion.save(store: store, environment: environment))
    XCTAssertEqual(companion.errorKey, "entry.error.reimbursementEdit")

    XCTAssertEqual(
      try repository.entry(id: reimbursement.id)?.transaction.amountE4, AmountE4(whole: 1_500))
    XCTAssertEqual(
      try repository.entry(id: shortfall.id)?.transaction.amountE4, AmountE4(whole: 200))
    XCTAssertFalse(store.canUndo)

    // What the resolver did not work out stays the owner's to change.
    let note = TransactionEditorModel(entry: reimbursement, environment: environment)
    note.draft.draft.note = "Alex, cash"
    XCTAssertTrue(note.save(store: store, environment: environment))
    XCTAssertEqual(try repository.entry(id: reimbursement.id)?.transaction.note, "Alex, cash")
  }

  /// Deleting the dinner would leave Alex's reimbursement closing a part that is gone, and its
  /// shortfall counted as my spending on a dinner that is not there. The dinner stays, from
  /// the list and from the editor alike, and the confirmation says why; once the reimbursement
  /// is deleted — which opens Alex's half again — the dinner goes like any other.
  func testAPurchaseIsNotDeletedFromUnderTheReimbursementThatClosedItsPart() throws {
    let dinner = try saveDinner()
    let recording = try recordAlexsReturn(of: dinner)
    let stored = try XCTUnwrap(try repository.entry(id: dinner.id))

    let plan = BulkEditRule.deletion(of: [stored])
    XCTAssertEqual(plan.changed, [])
    XCTAssertEqual(plan.skipped.map(\.transactionId), [dinner.id])
    XCTAssertEqual(plan.skipped.map(\.reason), [.closedByReimbursement])
    XCTAssertFalse(store.delete(ids: [dinner.id]))
    XCTAssertEqual(try repository.entry(id: dinner.id)?.transaction.isDeleted, false)
    XCTAssertEqual(
      try repository.entry(id: try XCTUnwrap(recording.extra.first).id)?.transaction.isDeleted,
      false)
    XCTAssertFalse(store.canUndo)

    // The reimbursement goes first, and the dinner after it.
    XCTAssertTrue(store.delete(ids: [recording.reimbursement.id]))
    XCTAssertTrue(store.delete(ids: [dinner.id]))
    XCTAssertEqual(try repository.entry(id: dinner.id)?.transaction.isDeleted, true)
  }

  /// The editor was opened on the dinner and Alex's half taken out of it; before «Save», Alex
  /// gave the money back for that half. Written, the edit would delete the part the
  /// reimbursement closes — the reimbursement would close nothing and its shortfall would be
  /// my spending on a part that is not there. The save is refused and says why.
  func testAPartClosedWhileTheEditorHeldItIsNotTakenAway() throws {
    let dinner = try saveDinner()
    let editor = TransactionEditorModel(entry: dinner, environment: environment)
    editor.draft.removePart(id: dinner.parts[1].id)
    XCTAssertEqual(editor.draft.draft.parts.map(\.id), [dinner.parts[0].id])

    _ = try recordAlexsReturn(of: dinner)
    XCTAssertFalse(editor.save(store: store, environment: environment))
    XCTAssertEqual(editor.errorKey, "entry.error.closedPartRemoved")
    XCTAssertEqual(try repository.entry(id: dinner.id)?.parts.map(\.id), dinner.parts.map(\.id))
    XCTAssertFalse(store.canUndo)
  }

  /// A part someone gave the money back for is not offered for removal in the panel at all.
  func testThePanelDoesNotTakeAwayAPartSomeoneGaveMoneyBackFor() throws {
    let dinner = try saveDinner()
    _ = try recordAlexsReturn(of: dinner)
    let stored = try XCTUnwrap(try repository.entry(id: dinner.id))
    let editor = TransactionEditorModel(entry: stored, environment: environment)
    XCTAssertFalse(editor.draft.canRemovePart(id: stored.parts[1].id))
    XCTAssertTrue(editor.draft.canRemovePart(id: stored.parts[0].id))
    editor.draft.removePart(id: stored.parts[1].id)
    XCTAssertEqual(editor.draft.draft.parts.map(\.id), stored.parts.map(\.id))
  }

  /// Alex gave back the money for his half. Un-ticked «paid for someone» on it, the half
  /// would become my spending while his money still counted as returned — 1 700 in neither
  /// income nor a reduction of spending; a new amount on it would leave the link holding the
  /// old one. The edit is refused and says why, and my spending stays where it was.
  func testThePartSomeoneGaveMoneyBackForKeepsItsMoney() throws {
    let dinner = try saveDinner()
    _ = try recordAlexsReturn(of: dinner)
    let stored = try XCTUnwrap(try repository.entry(id: dinner.id))
    let mine = MyExpensesRule.total(
      entries: try repository.entries(from: .distantPast, to: .distantFuture))

    let unticked = TransactionEditorModel(entry: stored, environment: environment)
    // The panel keeps the toggle, the amount, the currency and the type of it still.
    XCTAssertTrue(unticked.draft.isClosedPart(id: stored.parts[1].id))
    XCTAssertFalse(unticked.draft.isClosedPart(id: stored.parts[0].id))
    XCTAssertTrue(unticked.draft.hasClosedPart)
    unticked.draft.draft.parts[1].reimbursable = false
    XCTAssertFalse(unticked.save(store: store, environment: environment))
    XCTAssertEqual(unticked.errorKey, "entry.error.closedPartChanged")

    let resized = TransactionEditorModel(entry: stored, environment: environment)
    resized.draft.draft.parts[0].amount = AmountE4(whole: 1_900)
    resized.draft.draft.parts[1].amount = AmountE4(whole: 1_500)
    XCTAssertFalse(resized.save(store: store, environment: environment))
    XCTAssertEqual(resized.errorKey, "entry.error.closedPartChanged")

    let recurrency = TransactionEditorModel(entry: stored, environment: environment)
    recurrency.draft.draft.currency = .usd
    recurrency.draft.draft.rate = 90
    recurrency.draft.draft.rateSource = .manual
    XCTAssertFalse(recurrency.save(store: store, environment: environment))
    XCTAssertEqual(recurrency.errorKey, "entry.error.closedPartChanged")

    let half = try XCTUnwrap(try repository.entry(id: dinner.id)?.parts[1])
    XCTAssertTrue(half.reimbursable)
    XCTAssertEqual(half.reimbursementStatus, .returned)
    XCTAssertEqual(half.amountE4, AmountE4(whole: 1_700))
    XCTAssertEqual(
      MyExpensesRule.total(
        entries: try repository.entries(from: .distantPast, to: .distantFuture)), mine)
    XCTAssertFalse(store.canUndo)

    // The rest of the half — whom it was for, its category — and my own half stay editable.
    let note = TransactionEditorModel(entry: stored, environment: environment)
    note.draft.draft.note = "Dinner at Alex's"
    note.draft.draft.parts[1].forWhom = .family
    XCTAssertTrue(note.save(store: store, environment: environment))
    XCTAssertEqual(try repository.entry(id: dinner.id)?.parts[1].forWhom, .family)
  }

  private func links() async throws -> [ReimbursementLink] {
    try await DatasetRepository(writer: try XCTUnwrap(stack).writer).load(version: 0).links
  }

  /// Alex's reimbursement was deleted — his half is owed again, its link kept for undo — and
  /// then the half was taken out of the dinner, which took the link with it. ⌘Z of the edit
  /// gives the link back with the part, so ⌘Z of the deletion closes the
  /// half again with the link that says so, and deleting the reimbursement once more opens
  /// it again.
  func testUndoingAnEditThatTookAPartAwayGivesItsLinksBack() async throws {
    let dinner = try saveDinner()
    let recording = try recordAlexsReturn(of: dinner)
    let half = dinner.parts[1].id
    XCTAssertTrue(store.delete(ids: [recording.reimbursement.id]))
    let owed = try XCTUnwrap(try repository.entry(id: dinner.id))
    XCTAssertEqual(owed.parts[1].reimbursementStatus, .expected)

    let editor = TransactionEditorModel(entry: owed, environment: environment)
    editor.draft.removePart(id: half)
    XCTAssertTrue(editor.save(store: store, environment: environment))
    let afterEdit = try await links()
    XCTAssertEqual(afterEdit, [])

    store.undo()
    let afterUndo = try await links()
    XCTAssertEqual(afterUndo.map(\.partId), [half])
    store.undo()
    XCTAssertEqual(
      try repository.entry(id: dinner.id)?.parts.map(\.reimbursementStatus), [nil, .returned])
    let effects = try repository.softDelete(ids: [recording.reimbursement.id])
    XCTAssertEqual(effects.reopenedPartIds, [half])
  }

  /// Re-pointed at a debt kept in dollars, a payment in rubles would move it by rubles taken
  /// for dollars: the save is refused the way the entry line refuses it, and nothing moves.
  func testADebtPaymentCannotBeMovedOntoADebtInAnotherCurrency() throws {
    try makeStore()
    let loan = try makeDebt("Loan")
    let dollars = try makeDebt("Dollars", currency: CurrencyCode("USD"), balance: 1_000)
    let payment = try pay(loan, 8_500)

    let editor = TransactionEditorModel(entry: payment, environment: environment)
    editor.draft.draft.debtId = dollars.id
    XCTAssertFalse(editor.save(store: store, environment: environment))
    XCTAssertEqual(editor.errorKey, "entry.error.debtCurrency")
    XCTAssertEqual(try repository.entry(id: payment.id)?.transaction.debtId, loan.id)
    XCTAssertEqual(try balance(loan), AmountE4(whole: 91_500))
    XCTAssertEqual(try balance(dollars), AmountE4(whole: 1_000))
  }

  // MARK: What the editor offers of planning

  /// A purchase on credit opened in the editor used to read «On credit» off — the plan was
  /// never taken from `credit_debt_id` — and ticking it on and off to check cleared the link:
  /// Save took the purchase off its debt, and it could then be deleted from the list, which it
  /// never may be while it moves a debt. The editor now reads the box truthfully and leaves it
  /// alone: a purchase on credit is changed in Debts, as the bulk menu says.
  func testEditingAPurchaseOnCreditKeepsItsDebtLink() throws {
    try makeStore()
    let phone = Debt(
      direction: .iOwe, type: .installment, name: "Phone", paymentsAreExpenses: false,
      origin: .purchase)
    let purchase = try TransactionDraft(
      occurredAt: noon, amount: AmountE4(whole: 60_000), note: "Phone", creditDebtId: phone.id,
      parts: [PartDraft(amount: AmountE4(whole: 60_000))]
    ).materialize()
    XCTAssertTrue(
      store.apply(
        try XCTUnwrap(
          EntryCommit.change(
            entry: purchase, openedCredit: phone, paidDebt: nil, expectedIncomeId: nil,
            day: environment.calendar.day(of: noon)))))

    let saved = try XCTUnwrap(try repository.entry(id: purchase.id))
    let editor = TransactionEditorModel(entry: saved, environment: environment)
    XCTAssertTrue(editor.draft.isOnCredit, "the box says what the purchase is")
    XCTAssertFalse(editor.draft.canChangeCredit)

    editor.draft.startCreditPlan()
    editor.draft.stopCreditPlan()
    editor.draft.draft.note = "Phone 15"
    XCTAssertTrue(editor.save(store: store, environment: environment))

    XCTAssertEqual(try repository.entry(id: purchase.id)?.transaction.creditDebtId, phone.id)
    XCTAssertEqual(try balance(phone), AmountE4(whole: 60_000), "the debt keeps its purchase")
  }

  /// A plain purchase is not put on credit by the editor either: the plan it would have shown
  /// was never written. The line puts a purchase on credit when it is recorded.
  func testTheEditorDoesNotOfferToPutASavedPurchaseOnCredit() throws {
    let dinner = try saveDinner()
    let editor = TransactionEditorModel(entry: dinner, environment: environment)
    XCTAssertFalse(editor.draft.isOnCredit)
    XCTAssertFalse(editor.draft.canChangeCredit)
    editor.draft.startCreditPlan()
    XCTAssertNil(editor.draft.creditPlan)

    let line = EntryDraftModel(references: references, transactions: repository, calendar: .utc)
    XCTAssertTrue(line.canChangeCredit)
    line.startCreditPlan()
    XCTAssertTrue(line.isOnCredit)
  }

  /// The expected-income picker of the editor wrote no link: an income is tied to what was
  /// expected in Planning. The line keeps its picker — it writes the link with the income.
  func testTheEditorLeavesTheLinkToAnExpectedIncomeToPlanning() throws {
    let dinner = try saveDinner()
    let editor = TransactionEditorModel(entry: dinner, environment: environment)
    XCTAssertFalse(editor.draft.linksExpectedIncome)
    let line = EntryDraftModel(references: references, transactions: repository, calendar: .utc)
    XCTAssertTrue(line.linksExpectedIncome)
  }

  /// A debt chosen in the editor for a plain expense moves that debt, the way the line would
  /// have moved it: the «Debt» picker of the editor writes what it shows.
  func testChoosingADebtInTheEditorMovesIt() throws {
    try makeStore()
    let loan = try makeDebt("Loan")
    let expense = try TransactionDraft(
      occurredAt: noon, amount: AmountE4(whole: 7_000), note: "Loan",
      parts: [PartDraft(amount: AmountE4(whole: 7_000))]
    ).materialize()
    try repository.save(expense)

    let editor = TransactionEditorModel(entry: expense, environment: environment)
    editor.draft.draft.debtId = loan.id
    XCTAssertTrue(editor.save(store: store, environment: environment))
    XCTAssertEqual(try paymentLines(loan).map(\.amountE4), [AmountE4(whole: -7_000)])
    XCTAssertEqual(try balance(loan), AmountE4(whole: 93_000))

    let again = TransactionEditorModel(
      entry: try XCTUnwrap(try repository.entry(id: expense.id)), environment: environment)
    again.draft.draft.debtId = nil
    XCTAssertTrue(again.save(store: store, environment: environment))
    XCTAssertEqual(try paymentLines(loan), [])
    XCTAssertEqual(try balance(loan), AmountE4(whole: 100_000))
  }
}

/// The editor on accounts, refunds and counts: what an account is charged follows the edit,
/// a refund taken back from a purchase keeps the purchase's rubles, the refusals about refunds
/// and money back are said in words, and an edit that lands an operation on the day of a count
/// asks whether it was before the count.
@MainActor
final class TransactionEditorAccountsTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var repository: TransactionRepository!
  private var store: TransactionsStore!
  private var environment: AppEnvironment!

  /// The main account, rubles only.
  private let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
  /// Tenge only.
  private let kaspi = PaymentMethod(name: "Kaspi", currency: CurrencyCode("KZT"))
  /// Dollars only.
  private let freedom = PaymentMethod(name: "Freedom", currency: .usd)
  private let kzt = CurrencyCode("KZT")

  private let today = DateOnly(year: 2026, month: 9, day: 18)
  private var yesterday: DateOnly { DateOnly(year: 2026, month: 9, day: 17) }

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    repository = TransactionRepository(writer: stack.writer)
    for account in [card, kaspi, freedom] { try references.save(account) }
    store = TransactionsStore()
    store.attach(
      repository, references: references, planning: PlanningRepository(writer: stack.writer))
    environment = AppEnvironment()
  }

  private func moment(_ day: DateOnly, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    CalendarContext.utc.startOfDay(day)
      .addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + second))
  }

  /// The bank's rates of `today`: 90 ₽ for a dollar, 20 ₽ for 100 tenge.
  private func rates() -> RateTable {
    RateTable(rates: [
      Rate(date: today, currency: .usd, rubPerUnit: 90),
      Rate(date: today, currency: kzt, rubPerUnit: 20, nominal: 100),
    ])
  }

  /// The editor of `entry`, with the panel on this database and these rates.
  private func editor(of entry: TransactionEntry) -> TransactionEditorModel {
    let draft = EntryDraftModel(
      references: references, transactions: repository, calendar: .utc,
      editsSavedOperation: true)
    let table = rates()
    draft.rateTable = { table }
    return TransactionEditorModel(entry: entry, draft: draft)
  }

  /// What the pipeline would hand the store: the lists read the purchases and refunds from it.
  private func showDatabase() throws {
    let dataset = Dataset(
      entries: try repository.entries(from: .distantPast, to: .distantFuture),
      paymentMethods: [card, kaspi, freedom])
    store.show(Ledger(dataset: dataset, calendar: .utc))
  }

  /// 12 $ on Freedom, which holds dollars: nothing charged apart.
  private func dollarsOnFreedom() throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: moment(today, 15), currency: .usd, amount: AmountE4(whole: 12), rate: 90,
      rateDate: today, rateSource: .cbr, note: "books", paymentMethodId: freedom.id)
    draft.normalizeSinglePart()
    return try repository.save(try draft.materialize(now: moment(today, 15)))
  }

  // MARK: What the account is charged

  func testMovedToAnAccountWithoutTheCurrencyTheChargeIsPrefilledAndSaved() throws {
    let books = try dollarsOnFreedom()
    let editor = editor(of: books)
    editor.draft.setPaymentMethod(kaspi.id)
    XCTAssertTrue(editor.save(store: store, environment: environment))

    // 12 $ at 90 ₽ = 1 080 ₽ = 5 400 ₸ at 20 ₽ for 100 ₸.
    let stored = try XCTUnwrap(try repository.entry(id: books.id))
    XCTAssertEqual(stored.transaction.paymentMethodId, kaspi.id)
    XCTAssertEqual(stored.transaction.accountCurrency, kzt)
    XCTAssertEqual(stored.transaction.accountAmountE4, AmountE4(whole: 5_400))
  }

  func testATypedChargeIsKeptWithAWarningWhenTheAmountChanges() throws {
    let books = try dollarsOnFreedom()
    let moving = editor(of: books)
    moving.draft.setPaymentMethod(kaspi.id)
    moving.draft.setCharge(AmountE4(whole: 5_300))
    XCTAssertTrue(moving.save(store: store, environment: environment))
    let typed = try XCTUnwrap(try repository.entry(id: books.id))
    XCTAssertEqual(typed.transaction.accountAmountE4, AmountE4(whole: 5_300))

    // 12 $ → 13 $: the figure from the statement stays, and the panel says to check it.
    let editor = editor(of: typed)
    editor.draft.setTotal(AmountE4(whole: 13))
    XCTAssertTrue(editor.draft.chargeNeedsCheck)
    XCTAssertTrue(editor.save(store: store, environment: environment))
    let stored = try XCTUnwrap(try repository.entry(id: books.id))
    XCTAssertEqual(stored.transaction.amountE4, AmountE4(whole: 13))
    XCTAssertEqual(stored.transaction.accountCurrency, kzt)
    XCTAssertEqual(stored.transaction.accountAmountE4, AmountE4(whole: 5_300))
  }

  func testAnUntouchedChargeIsWorkedOutAgainWhenTheAmountChanges() throws {
    let books = try dollarsOnFreedom()
    let moving = editor(of: books)
    moving.draft.setPaymentMethod(kaspi.id)
    XCTAssertTrue(moving.save(store: store, environment: environment))
    let prefilled = try XCTUnwrap(try repository.entry(id: books.id))

    let editor = editor(of: prefilled)
    editor.draft.setTotal(AmountE4(whole: 13))
    XCTAssertFalse(editor.draft.chargeNeedsCheck)
    XCTAssertTrue(editor.save(store: store, environment: environment))
    // 13 $ at 90 ₽ = 1 170 ₽ = 5 850 ₸.
    let stored = try XCTUnwrap(try repository.entry(id: books.id))
    XCTAssertEqual(stored.transaction.accountAmountE4, AmountE4(whole: 5_850))
  }

  // MARK: Refunds

  /// 7 000 $ bought on the card, the bank charging 1 000 000 ₽ — a rate of 142.857143 set by
  /// the figure — and 3 000 $ of it refunded.
  private func purchaseAndRefund() throws -> (purchase: TransactionEntry, refund: TransactionEntry)
  {
    var draft = TransactionDraft(
      occurredAt: moment(yesterday, 12), currency: .usd, amount: AmountE4(whole: 7_000),
      rate: 90, rateDate: yesterday, rateSource: .cbr, note: "Laptop", paymentMethodId: card.id)
    draft.accountCurrency = .rub
    draft.accountAmount = AmountE4(whole: 1_000_000)
    draft.normalizeSinglePart()
    let purchase = try repository.save(try draft.materialize(now: moment(yesterday, 12)))
    XCTAssertEqual(purchase.transaction.amountRubE4, AmountE4(whole: 1_000_000))

    let part = purchase.parts[0]
    var refundDraft = try RefundRules.draft(
      refunding: part, of: purchase, amount: AmountE4(whole: 3_000),
      occurredAt: moment(today, 10), accountId: card.id,
      index: RefundIndex(entries: [purchase], debts: [:]), tree: CategoryTree())
    refundDraft.accountCurrency = .rub
    refundDraft.accountAmount = AmountE4(whole: 270_000)
    let rubles = RefundRules.rubles(
      refundAmount: AmountE4(whole: 3_000), part: part, refundedBefore: (.zero, .zero))
    let refund = try repository.save(
      try refundDraft.materialize(now: moment(today, 10), rublesConverter: { _ in rubles }))
    try showDatabase()
    return (purchase, refund)
  }

  func testARefundEditedToTheWholePartStoresThePurchasesRublesExactly() throws {
    let (purchase, refund) = try purchaseAndRefund()
    let editor = editor(of: refund)
    editor.draft.draft.amount = AmountE4(whole: 7_000)
    editor.draft.draft.parts[0].amount = AmountE4(whole: 7_000)
    XCTAssertTrue(editor.save(store: store, environment: environment), "\(editor.errorKey ?? "")")

    let stored = try XCTUnwrap(try repository.entry(id: refund.id))
    // The rest of the part's rubles, not 7 000 × 142.857143 = 1 000 000.001.
    XCTAssertEqual(stored.transaction.amountRubE4, purchase.transaction.amountRubE4)
    // The purchase's rate stays with the refund.
    XCTAssertEqual(stored.transaction.rate, purchase.transaction.rate)
  }

  func testAPurchaseCheaperThanWhatWasRefundedIsRefusedInWords() throws {
    let (purchase, _) = try purchaseAndRefund()
    let editor = editor(of: purchase)
    editor.draft.draft.amount = AmountE4(whole: 2_000)
    editor.draft.draft.parts[0].amount = AmountE4(whole: 2_000)
    editor.draft.draft.accountAmount = AmountE4(whole: 280_000)
    XCTAssertFalse(editor.save(store: store, environment: environment))
    XCTAssertEqual(editor.errorKey, "transactions.error.refundedPartReduced")
    XCTAssertEqual(
      try repository.entry(id: purchase.id)?.transaction.amountE4, AmountE4(whole: 7_000))
  }

  func testARefundAboveWhatIsLeftIsRefusedInWords() throws {
    let (_, refund) = try purchaseAndRefund()
    let editor = editor(of: refund)
    editor.draft.draft.amount = AmountE4(whole: 8_000)
    editor.draft.draft.parts[0].amount = AmountE4(whole: 8_000)
    XCTAssertFalse(editor.save(store: store, environment: environment))
    XCTAssertEqual(editor.errorKey, "transactions.error.linkedRefundChanged")
    XCTAssertEqual(
      try repository.entry(id: refund.id)?.transaction.amountE4, AmountE4(whole: 3_000))
  }

  func testEveryRefusalAboutRefundsAndMoneyBackHasWordsInBothLanguages() {
    let language = AppLanguage()
    // The choice is stored for the whole test host: it goes back to what it was.
    let before = language.choice
    defer { language.choice = before }
    let keys =
      LinkedEditRefusal.allCases.map(TransactionEditorModel.errorKey(of:))
      + [
        RefundError.notRefundable, .exceedsRemaining, .notPositive, .purchaseHasRefunds,
        .otherCurrency,
      ].map(TransactionEditorModel.errorKey(of:))
      + ["entry.error.chargeMissing"]
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys {
        let table = TransactionEditorModel.table(ofErrorKey: key)
        XCTAssertNotEqual(language(key, table: table), key, "\(choice) \(key)")
      }
    }
  }

  // MARK: Before the count

  /// The card counted today at 14:05.
  private func countedAt1405(now: Date) -> AccountBalances {
    let count = moment(today, 14, 5)
    let reconciliation = Reconciliation(
      date: today, reconciledAt: count, actualTotalRubE4: .zero, kind: .accounts)
    let balance = ReconciledBalance(
      reconciliationId: reconciliation.id, accountId: card.id, currency: .rub,
      actualE4: AmountE4(whole: 10_000))
    return AccountBalances.build(
      entries: [], transfers: [], debtEntries: [], debts: [:], reconciliations: [reconciliation],
      balances: [balance], accounts: [card, kaspi, freedom], tree: CategoryTree(), now: now,
      calendar: .utc)
  }

  /// A taxi of 500 ₽ on the card at `at`.
  private func taxi(at: Date) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: at, amount: AmountE4(whole: 500), note: "taxi", paymentMethodId: card.id)
    draft.normalizeSinglePart()
    return try repository.save(try draft.materialize(now: at))
  }

  func testAnEditThatMovesAnOperationOntoTheDayOfACountAsksFirst() throws {
    let taxi = try taxi(at: moment(yesterday, 20))
    let saved = moment(today, 15)
    let balances = countedAt1405(now: saved)
    let editor = editor(of: taxi)
    editor.draft.setDate(moment(today, 9), today: today)

    // Nothing is written until the owner says whether it was before the count.
    XCTAssertFalse(
      editor.save(store: store, environment: environment, balances: balances, now: saved))
    XCTAssertEqual(editor.countQuestion?.count, moment(today, 14, 5))
    XCTAssertEqual(try repository.entry(id: taxi.id)?.transaction.occurredAt, moment(yesterday, 20))

    // «Нет»: after the count; the save goes on and does not ask again.
    editor.answerCount(moment(today, 14, 5), wasBefore: false)
    XCTAssertNil(editor.countQuestion)
    XCTAssertTrue(
      editor.save(store: store, environment: environment, balances: balances, now: saved))
    XCTAssertEqual(
      try repository.entry(id: taxi.id)?.transaction.occurredAt, moment(today, 14, 5, 1))
  }

  func testAnEditMovedToAnotherAccountCountedTodayAsksToo() throws {
    var draft = TransactionDraft(
      occurredAt: moment(today, 16), amount: AmountE4(whole: 500), note: "taxi",
      paymentMethodId: freedom.id, accountCurrency: .usd, accountAmount: AmountE4(whole: 6))
    draft.normalizeSinglePart()
    let taxi = try repository.save(try draft.materialize(now: moment(today, 16)))
    let saved = moment(today, 17)
    let editor = editor(of: taxi)
    editor.draft.setPaymentMethod(card.id)
    XCTAssertFalse(
      editor.save(
        store: store, environment: environment, balances: countedAt1405(now: saved), now: saved))
    XCTAssertEqual(editor.countQuestion?.count, moment(today, 14, 5))
  }

  /// «Save» in the questions of the Transactions window — asked when another operation is
  /// opened, or when the inspector is folded away — hands the editor no balances: it asks by
  /// the balances of the window that showed it, the same question the button asks.
  func testASaveFromTheQuestionsOfTheWindowAsksByTheBalancesTheEditorWasShownWith() throws {
    let taxi = try taxi(at: moment(yesterday, 20))
    let saved = moment(today, 15)
    let balances = countedAt1405(now: saved)
    let editor = editor(of: taxi)
    editor.balancesNow = { balances }
    editor.draft.setDate(moment(today, 9), today: today)

    XCTAssertFalse(editor.save(store: store, environment: environment, now: saved))
    XCTAssertEqual(editor.countQuestion?.count, moment(today, 14, 5))
    XCTAssertEqual(try repository.entry(id: taxi.id)?.transaction.occurredAt, moment(yesterday, 20))

    // Balances handed in win over the window's.
    let elsewhere = self.editor(of: taxi)
    elsewhere.balancesNow = { balances }
    elsewhere.draft.setDate(moment(today, 9), today: today)
    XCTAssertTrue(
      elsewhere.save(store: store, environment: environment, balances: .empty, now: saved))
  }

  /// Money back moves money on a day like any other operation: moved onto the day of a count,
  /// after it, the edit asks too — only its amount, type and currency stay as they were.
  func testMoneyBackMovedOntoTheDayOfACountAsksFirst() throws {
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: moment(yesterday, 20), amount: AmountE4(whole: 1_700),
      paymentMethodId: card.id)
    draft.normalizeSinglePart()
    let back = try repository.save(try draft.materialize(now: moment(yesterday, 20)))
    let saved = moment(today, 15)
    let balances = countedAt1405(now: saved)
    let editor = editor(of: back)
    editor.draft.setDate(moment(today, 10), today: today)

    XCTAssertFalse(
      editor.save(store: store, environment: environment, balances: balances, now: saved))
    XCTAssertEqual(editor.countQuestion?.count, moment(today, 14, 5))
    XCTAssertEqual(try repository.entry(id: back.id)?.transaction.occurredAt, moment(yesterday, 20))

    // «Нет»: the money came after the count.
    editor.answerCount(moment(today, 14, 5), wasBefore: false)
    XCTAssertTrue(
      editor.save(store: store, environment: environment, balances: balances, now: saved),
      "\(editor.errorKey ?? "")")
    XCTAssertEqual(
      try repository.entry(id: back.id)?.transaction.occurredAt, moment(today, 14, 5, 1))
  }

  func testAnEditThatMovesNoMoneyDoesNotAsk() throws {
    // Dated on the day of the count, after it; only the description changes.
    let taxi = try taxi(at: moment(today, 15))
    let saved = moment(today, 16)
    let editor = editor(of: taxi)
    editor.draft.draft.note = "taxi home"
    XCTAssertTrue(
      editor.save(
        store: store, environment: environment, balances: countedAt1405(now: saved), now: saved))
    XCTAssertNil(editor.countQuestion)
    XCTAssertEqual(try repository.entry(id: taxi.id)?.transaction.note, "taxi home")
  }
}
