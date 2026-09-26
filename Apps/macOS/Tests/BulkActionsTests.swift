import AppCore
import AppDatabase
import XCTest

@testable import Itogo

/// Changing and deleting many operations from the list: one action is one step of ⌘Z, and
/// every write — undo included — tells the app so it can make a copy.
@MainActor
final class BulkActionsTests: XCTestCase {
  private var repository: TransactionRepository!
  private var references: ReferenceRepository!
  private var store: TransactionsStore!
  private var written: [[UUID]] = []

  /// Built inside each test, on the main actor: the store and its callback belong there.
  private func makeStore() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    repository = TransactionRepository(writer: stack.writer)
    references = ReferenceRepository(writer: stack.writer)
    store = TransactionsStore(repository: repository, references: references)
    written = []
    store.didWrite = { [weak self] write in self?.written.append(write.touchedIds) }
  }

  /// What the pipeline would hand the store after reading the database: the lists, the
  /// menus and the confirmations read the operations from it.
  private func showDatabase() throws {
    let dataset = Dataset(
      entries: try repository.entries(from: .distantPast, to: .distantFuture),
      categories: try references.categories(includeArchived: true),
      debts: try references.debts(includeClosed: true))
    store.show(Ledger(dataset: dataset, calendar: .utc))
  }

  private func saveEntries(_ notes: [String]) throws -> [TransactionEntry] {
    if store == nil { try makeStore() }
    let entries = try notes.enumerated().map { index, note in
      var draft = TransactionDraft(
        occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18))
          .addingTimeInterval(Double(index) * 60),
        amount: AmountE4(whole: 100), note: note)
      draft.normalizeSinglePart()
      return try draft.materialize()
    }
    for entry in entries { try repository.save(entry) }
    try showDatabase()
    return entries
  }

  /// Operations enough to make a bulk write leave the main thread, saved in one write.
  private func saveMany(_ count: Int) throws -> [UUID] {
    if store == nil { try makeStore() }
    let start = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 1))
    let entries = try (0..<count).map { index in
      var draft = TransactionDraft(
        occurredAt: start.addingTimeInterval(TimeInterval(index) * 60),
        amount: AmountE4(whole: 100), note: "row \(index)")
      draft.normalizeSinglePart()
      return try draft.materialize()
    }
    try repository.insert(entries)
    try showDatabase()
    return entries.map(\.id)
  }

  /// Waits for the write the store runs off the main thread and says whether it landed.
  private func backgroundWriteLands() async throws -> Bool {
    let write = try XCTUnwrap(store.backgroundWrite, "the write did not leave the main thread")
    return await write.value
  }

  /// ⌘A over two months of the large sample selects about 1 700 operations. A
  /// change that large is written off the main thread: the call returns at once, the store
  /// is busy — nothing to undo yet, nothing reported — and once it lands it is one step of
  /// ⌘Z and one report, like any bulk change. Its undo goes the same way.
  func testAChangeOfMoreThanAThousandLandsInTheBackgroundAsOneStep() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 1)

    XCTAssertTrue(store.apply(.quality(.bad), to: ids))
    XCTAssertTrue(store.isWritingInBackground)
    XCTAssertFalse(store.canUndo, "nothing to undo before the write has landed")
    XCTAssertTrue(written.isEmpty)

    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)
    XCTAssertFalse(store.isWritingInBackground)
    XCTAssertNil(store.lastError)
    XCTAssertEqual(written.count, 1)
    XCTAssertEqual(Set(written.last ?? []), Set(ids))
    let changed = try repository.entries(ids: ids)
    XCTAssertTrue(changed.allSatisfy { $0.parts[0].quality == .bad })
    XCTAssertTrue(store.canUndo)

    store.undo()
    XCTAssertTrue(store.isWritingInBackground, "a step that large is undone off the main thread")
    let undone = try await backgroundWriteLands()
    XCTAssertTrue(undone)
    XCTAssertTrue(try repository.entries(ids: ids).allSatisfy { $0.parts[0].quality == nil })
    XCTAssertEqual(written.count, 2)
    XCTAssertFalse(store.canUndo, "the whole change was one step")
  }

  func testADeletionOfMoreThanAThousandLandsInTheBackgroundAndComesBack() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 1)

    XCTAssertTrue(store.delete(ids: ids))
    XCTAssertTrue(store.isWritingInBackground)
    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)
    XCTAssertEqual(try repository.count(), 0)
    XCTAssertEqual(Set(written.last ?? []), Set(ids))

    store.undo()
    let undone = try await backgroundWriteLands()
    XCTAssertTrue(undone)
    XCTAssertEqual(try repository.count(), ids.count)
    XCTAssertEqual(written.count, 2)
    XCTAssertFalse(store.canUndo)
  }

  /// While a large write is landing, the store takes no other bulk write and no undo: the
  /// steps of ⌘Z stay in the order of the writes they take back.
  func testNothingElseIsWrittenOrUndoneWhileABackgroundWriteLands() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 1)
    XCTAssertTrue(store.apply(.quality(.good), to: [ids[0]]))

    XCTAssertTrue(store.apply(.quality(.bad), to: ids))
    XCTAssertFalse(store.apply(.quality(.neutral), to: [ids[1]]))
    XCTAssertFalse(store.delete(ids: [ids[2]]))
    store.undo()

    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)
    XCTAssertEqual(written.count, 2, "only the two changes that were taken")
    XCTAssertEqual(try repository.count(), ids.count)
    XCTAssertEqual(try repository.entry(id: ids[0])?.parts[0].quality, .bad)
    XCTAssertEqual(try repository.entry(id: ids[1])?.parts[0].quality, .bad)
  }

  /// A store handed another database while a large write on the first one is still on its
  /// way: that write belongs to the database it was asked of. It used to keep the store busy
  /// — no bulk write and no ⌘Z on the new database until it landed — and then to report
  /// itself to the new database's `didWrite`: its overlay got rows that are not there, its
  /// backup a change it never had.
  func testAWriteOnADatabaseLetGoIsNeitherWaitedForNorReportedToTheNextOne() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 1)
    XCTAssertTrue(store.apply(.quality(.bad), to: ids))
    let old = try XCTUnwrap(store.backgroundWrite)

    let next = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let nextRepository = TransactionRepository(writer: next.writer)
    store.attach(nextRepository, references: ReferenceRepository(writer: next.writer))
    let tea = try typedEntry("tea")
    try nextRepository.save(tea)

    XCTAssertFalse(store.isWritingInBackground, "the new database has no write on its way")
    XCTAssertTrue(store.apply(.quality(.good), to: [tea.id]), "a bulk write was turned away")
    XCTAssertEqual(written, [[tea.id]])
    let landed = await old.value
    XCTAssertTrue(landed)
    XCTAssertEqual(written, [[tea.id]], "the old database's write was reported to the new one")
    XCTAssertFalse(store.isWritingInBackground)
    store.undo()
    XCTAssertNil(try nextRepository.entry(id: tea.id)?.parts[0].quality)
    XCTAssertFalse(store.canUndo, "the old write left a step on the new database")
  }

  /// An operation that is not saved yet, as the entry line would hand it to the store.
  private func typedEntry(_ note: String) throws -> TransactionEntry {
    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: note)
    draft.normalizeSinglePart()
    return try draft.materialize()
  }

  /// The entry line is never locked: a line typed while a large change is landing
  /// is the last thing the owner did, so it is the first thing ⌘Z takes back — although the
  /// change reaches the stack of undo only when it lands. The change takes the place it was
  /// asked for in, above the steps taken before it.
  func testALineSavedWhileABackgroundChangeLandsIsUndoneFirst() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 1)
    XCTAssertTrue(store.apply(.quality(.good), to: [ids[0]]))
    XCTAssertTrue(store.apply(.quality(.bad), to: ids))
    let coffee = try typedEntry("coffee")
    XCTAssertTrue(store.save(coffee))
    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)

    store.undo()
    XCTAssertFalse(store.isWritingInBackground, "one operation is undone at once")
    XCTAssertNil(try repository.entry(id: coffee.id), "the line went first")
    XCTAssertEqual(try repository.entry(id: ids[1])?.parts[0].quality, .bad)

    store.undo()
    let undone = try await backgroundWriteLands()
    XCTAssertTrue(undone)
    XCTAssertNil(try repository.entry(id: ids[1])?.parts[0].quality, "then the large change")
    XCTAssertEqual(try repository.entry(id: ids[0])?.parts[0].quality, .good)

    store.undo()
    XCTAssertNil(try repository.entry(id: ids[0])?.parts[0].quality, "then the one before it")
    XCTAssertFalse(store.canUndo)
  }

  /// The same for a large deletion: what goes is chosen and deleted in one write, and its
  /// step still lands under the line typed meanwhile.
  func testALineSavedWhileABackgroundDeletionLandsIsUndoneFirst() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 1)
    XCTAssertTrue(store.delete(ids: ids))
    let coffee = try typedEntry("coffee")
    XCTAssertTrue(store.save(coffee))
    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)
    XCTAssertEqual(try repository.count(), 1)

    store.undo()
    XCTAssertNil(try repository.entry(id: coffee.id), "the line went first")
    XCTAssertEqual(try repository.count(), 0)

    store.undo()
    let undone = try await backgroundWriteLands()
    XCTAssertTrue(undone)
    XCTAssertEqual(try repository.count(), ids.count)
    XCTAssertFalse(store.canUndo)
  }

  /// Recording a reimbursement forgets the steps before it, and a large change still landing
  /// was asked for before it too: its step is not kept, so ⌘Z never reaches across the
  /// write the history was forgotten for. A line saved after that is kept as usual.
  func testALargeChangeLandingAfterTheHistoryWasForgottenLeavesNoStep() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 1)
    XCTAssertTrue(store.apply(.quality(.bad), to: ids))
    store.forgetUndoHistory()
    let coffee = try typedEntry("coffee")
    XCTAssertTrue(store.save(coffee))
    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)
    XCTAssertEqual(written.count, 2, "the change landed and was reported all the same")

    store.undo()
    XCTAssertNil(try repository.entry(id: coffee.id))
    XCTAssertFalse(store.canUndo, "nothing reaches across the forgotten history")
    XCTAssertEqual(try repository.entry(id: ids[0])?.parts[0].quality, .bad)
  }

  /// The undo of a large deletion runs with nothing selected — the deleted rows left the
  /// selection — and so may a change whose selection was cleared with Esc. The bar stays
  /// for the time of the write, without a count, to say why ⌘Z and the menu wait.
  func testTheBarSaysAWriteIsLandingWhenNothingIsSelected() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 1)
    let actions = OperationActions()
    actions.selection = Set(ids)
    var form: SelectionBar.Form {
      SelectionBar.form(selection: actions.selection, writing: store.isWritingInBackground)
    }
    XCTAssertEqual(form, .selection)

    XCTAssertTrue(store.delete(ids: ids))
    XCTAssertEqual(form, .selection, "the count and the inactive buttons, as before")
    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)
    actions.keep(only: [])
    XCTAssertEqual(form, .hidden)

    store.undo()
    XCTAssertEqual(form, .writing)
    let undone = try await backgroundWriteLands()
    XCTAssertTrue(undone)
    XCTAssertEqual(form, .hidden)
  }

  // MARK: How far ⌘Z reaches back

  /// The stack of ⌘Z used to keep every step of the session until quit — each bulk change
  /// with a copy of every operation it touched. It reaches back a hundred steps now: the
  /// hundred and first write lets the oldest step go, and that write stays in place.
  func testUndoReachesBackAHundredStepsAndNoFurther() throws {
    let entries = try saveEntries(["coffee"])
    let id = entries[0].id
    let levels = TransactionsStore.UndoDepth().levels
    XCTAssertEqual(levels, 100)
    for step in 0...levels {
      XCTAssertTrue(store.apply(.quality(step.isMultiple(of: 2) ? .bad : .good), to: [id]))
    }
    XCTAssertEqual(try repository.entry(id: id)?.parts[0].quality, .bad)

    for _ in 0..<levels { store.undo() }

    XCTAssertFalse(store.canUndo, "a hundred steps back, and no further")
    XCTAssertEqual(
      try repository.entry(id: id)?.parts[0].quality, .bad, "the first change stays in place")
  }

  /// Steps of many operations count by what they hold: beyond the budget the oldest go,
  /// however few the steps. The newest stays whatever its size — the last thing done can
  /// always be taken back.
  func testLargeStepsLetTheOldestGoBeyondTheBudget() throws {
    let entries = try saveEntries((0..<20).map { "row \($0)" })
    let ids = entries.map(\.id)
    store.undoDepth = TransactionsStore.UndoDepth(levels: 100, operations: 10)

    XCTAssertTrue(store.apply(.quality(.good), to: Array(ids[0..<4])))
    XCTAssertTrue(store.apply(.quality(.bad), to: Array(ids[4..<8])))
    XCTAssertTrue(store.apply(.quality(.neutral), to: Array(ids[8..<12])))
    store.undo()
    store.undo()
    XCTAssertFalse(store.canUndo, "twelve operations kept where ten are allowed")
    XCTAssertEqual(try repository.entry(id: ids[0])?.parts[0].quality, .good)
    XCTAssertNil(try repository.entry(id: ids[4])?.parts[0].quality)

    XCTAssertTrue(store.apply(.quality(.bad), to: ids))
    XCTAssertTrue(store.canUndo, "a step larger than the budget is still kept, alone")
    store.undo()
    XCTAssertFalse(store.canUndo)
    XCTAssertEqual(try repository.entry(id: ids[0])?.parts[0].quality, .good)
    XCTAssertNil(try repository.entry(id: ids[19])?.parts[0].quality)
  }

  /// A large change takes its place in the stack when it is asked for and lands later; the
  /// history is not trimmed meanwhile, or a line saved in between would end up under the
  /// change and ⌘Z would take the change back first.
  func testTheHistoryIsTrimmedOnlyOnceALargeWriteHasLanded() async throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold + 2)
    store.undoDepth = TransactionsStore.UndoDepth(levels: 3, operations: 100_000)
    for quality in [Quality.good, .neutral, .bad] {
      XCTAssertTrue(store.apply(.quality(quality), to: [ids[0]]))
    }
    XCTAssertTrue(store.apply(.quality(.good), to: Array(ids.dropFirst())))
    let coffee = try typedEntry("coffee")
    XCTAssertTrue(store.save(coffee))
    let landed = try await backgroundWriteLands()
    XCTAssertTrue(landed)

    store.undo()
    XCTAssertNil(try repository.entry(id: coffee.id), "the line went first")
    store.undo()
    let undone = try await backgroundWriteLands()
    XCTAssertTrue(undone)
    XCTAssertNil(try repository.entry(id: ids[1])?.parts[0].quality, "then the large change")
    store.undo()
    XCTAssertEqual(try repository.entry(id: ids[0])?.parts[0].quality, .neutral)
    XCTAssertFalse(store.canUndo, "three steps kept: the line, the change and the last edit")
  }

  /// A thousand is still written where it is asked for: the call has landed when it returns.
  func testAThousandOperationsAreStillWrittenAtOnce() throws {
    let ids = try saveMany(TransactionsStore.backgroundThreshold)

    XCTAssertTrue(store.apply(.quality(.bad), to: ids))

    XCTAssertFalse(store.isWritingInBackground)
    XCTAssertNil(store.backgroundWrite)
    XCTAssertEqual(written.count, 1)
    XCTAssertTrue(try repository.entries(ids: ids).allSatisfy { $0.parts[0].quality == .bad })
  }

  /// The confirmation of a bulk change drops what `apply` returns: a change the database
  /// refuses — here a place that is not in the dictionary — is told by the store itself,
  /// through `failure`, which the alert of the screen shows (`operationPresentations`), and
  /// the journal gets it. Nothing is written and nothing is left to undo.
  func testARefusedBulkChangeIsToldByTheStoreNotByItsCaller() throws {
    let entries = try saveEntries(["coffee", "tea"])
    let ids = entries.map(\.id)

    XCTAssertFalse(store.apply(.place(UUID()), to: ids))

    XCTAssertEqual(store.failure?.action, .change)
    XCTAssertFalse(store.canUndo)
    XCTAssertTrue(written.isEmpty)
    XCTAssertTrue(try repository.entries(ids: ids).allSatisfy { $0.transaction.placeId == nil })
  }

  func testOneBulkChangeIsUndoneByOneUndo() throws {
    let entries = try saveEntries(["coffee", "tea", "juice"])
    let ids = entries.map(\.id)

    XCTAssertTrue(store.apply(.quality(.bad), to: ids))
    let changed = try repository.entries(ids: ids)
    XCTAssertEqual(changed.map { $0.parts[0].quality }, [.bad, .bad, .bad])
    XCTAssertEqual(changed.map { $0.parts[0].qualitySource }, [.manual, .manual, .manual])

    store.undo()

    let restored = try repository.entries(ids: ids)
    XCTAssertEqual(restored.map { $0.parts[0].quality }, [nil, nil, nil])
    XCTAssertFalse(store.canUndo, "the whole change was one step")
  }

  func testOneBulkDeletionIsUndoneByOneUndo() throws {
    let entries = try saveEntries(["coffee", "tea", "juice"])

    XCTAssertTrue(store.delete(ids: entries.map(\.id)))
    XCTAssertEqual(try repository.count(), 0)
    XCTAssertEqual(Set(written.last ?? []), Set(entries.map(\.id)))

    store.undo()

    XCTAssertEqual(try repository.count(), 3)
    XCTAssertEqual(Set(written.last ?? []), Set(entries.map(\.id)))
    XCTAssertFalse(store.canUndo)
  }

  /// A copy after every change — ⌘Z is a change too.
  func testEveryWriteAndEveryUndoIsReported() throws {
    let entries = try saveEntries(["coffee", "tea"])
    let ids = entries.map(\.id)

    store.apply(.quality(.good), to: ids)
    store.delete(ids: [ids[0]])
    XCTAssertEqual(written.count, 2)

    store.undo()
    XCTAssertEqual(written.count, 3)
    XCTAssertEqual(written.last, [ids[0]])
    store.undo()
    XCTAssertEqual(written.count, 4)
    XCTAssertEqual(Set(written.last ?? []), Set(ids))
  }

  /// The plan the confirmation is written from counts the splits and what is left alone.
  func testThePlanSaysWhatTheChangeReachesAndWhatItLeavesAlone() throws {
    try makeStore()
    var receipt = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18)),
      amount: AmountE4(whole: 1_000), note: "receipt")
    receipt.parts = [
      PartDraft(amount: AmountE4(whole: 600)),
      PartDraft(amount: AmountE4(whole: 400)),
    ]
    var salary = TransactionDraft(
      kind: .income,
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18)),
      amount: AmountE4(whole: 5_000), note: "salary")
    salary.normalizeSinglePart()
    let split = try receipt.materialize()
    let income = try salary.materialize()
    try repository.save(split)
    try repository.save(income)
    try showDatabase()

    let plan = store.plan(.quality(.bad), ids: [split.id, income.id])

    XCTAssertEqual(plan.changedIds, [split.id])
    XCTAssertEqual(plan.splitCount, 1)
    XCTAssertEqual(plan.skipped.map(\.reason), [.noQuality])
  }

  /// Settings adds, re-rates and archives categories without going through the store, so a
  /// bulk change judges by the dictionary as it is at that moment, not as the list last
  /// read it.
  func testABulkCategoryChangeJudgesByTheCategoriesAsTheyAreNow() throws {
    try makeStore()
    var cafe = CoreKit.Category(kind: .expense, name: "Cafe", quality: .neutral)
    try references.save(cafe)
    let lunch = try saveEntries(["lunch"])[0]

    // Re-rated after the list was read: the operation takes the quality Cafe has now.
    cafe.quality = .bad
    try references.save(cafe)
    XCTAssertTrue(store.apply(.category(cafe.id), to: [lunch.id]))
    let moved = try XCTUnwrap(try repository.entry(id: lunch.id))
    XCTAssertEqual(moved.parts[0].categoryId, cafe.id)
    XCTAssertEqual(moved.parts[0].quality, .bad)
    XCTAssertEqual(moved.parts[0].qualitySource, .category)

    // Created after the list was read: a category the popover offers is one the rule knows.
    let pets = CoreKit.Category(kind: .expense, name: "Pets", quality: .neutral)
    try references.save(pets)
    XCTAssertEqual(store.plan(.category(pets.id), ids: [lunch.id]).changedIds, [lunch.id])

    // Archived after the list was read: nothing is filed into it any more.
    var pub = CoreKit.Category(kind: .expense, name: "Pub", quality: .bad)
    try references.save(pub)
    try showDatabase()
    pub.archived = true
    try references.save(pub)
    let refused = store.plan(.category(pub.id), ids: [lunch.id])
    XCTAssertTrue(refused.changed.isEmpty)
    XCTAssertEqual(refused.skipped.map(\.reason), [.retiredCategory])
    XCTAssertTrue(store.apply(.category(pub.id), to: [lunch.id]))
    XCTAssertEqual(try repository.entry(id: lunch.id)?.parts[0].categoryId, cafe.id)
  }

  /// A payment typed in the line moves its debt right after it is saved. Undoing the entry
  /// takes that movement off the debt as well: the payment never happened, so the debt is
  /// what it was before.
  func testUndoingATypedDebtPaymentTakesItsMovementOffTheDebt() throws {
    try makeStore()
    let loan = Debt(direction: .iOwe, type: .loan, name: "Bank loan", paymentsAreExpenses: true)
    try references.save(loan)
    let opening = DebtEntry(
      debtId: loan.id, date: DateOnly(year: 2026, month: 1, day: 10),
      amountE4: AmountE4(whole: 100_000), kind: .borrowed)
    try references.save(opening)
    var draft = TransactionDraft(amount: AmountE4(whole: 7_000), note: "loan", debtId: loan.id)
    draft.normalizeSinglePart()
    let payment = try draft.materialize()
    XCTAssertTrue(store.save(payment))
    try references.save(
      DebtEntry(
        debtId: loan.id, date: DateOnly(year: 2026, month: 9, day: 18),
        amountE4: AmountE4(whole: -7_000), kind: .payment, transactionId: payment.id))

    store.undo()

    XCTAssertEqual(try repository.count(), 0)
    XCTAssertEqual(try references.debtEntries(debtId: loan.id), [opening])
  }

  /// Deleting asks with the count and the sums of what goes; a purchase on credit is left
  /// for the Debts section and the dialog says why.
  func testTheDeleteConfirmationCountsWhatGoesAndSaysWhatStays() throws {
    let entries = try saveEntries(["coffee", "tea"])
    var laptop = entries[1]
    laptop.transaction.creditDebtId = UUID()

    let confirmation = try XCTUnwrap(
      BulkConfirmation.deletion(of: [entries[0], laptop], debts: [:]))
    guard case .delete(let ids, let plan, let totals, _) = confirmation else {
      return XCTFail("a deletion was expected")
    }
    XCTAssertEqual(ids, [entries[0].id])
    XCTAssertEqual(totals.myExpenses, AmountE4(whole: 100))
    XCTAssertEqual(plan.skipped.map(\.reason), [.creditPurchase])
  }

  /// Money a person gives back on a debt they owe me is a reimbursement too (DebtRules), but
  /// it closes no part and has no surplus or shortfall: its deletion moves the debt, and that
  /// is the only line the confirmation says about it. Money given back for a purchase says
  /// what goes with it.
  func testTheDeleteConfirmationSaysWhatAPaymentOnADebtOwedToMeTakesAlong() throws {
    let environment = AppEnvironment()
    environment.language.choice = .english
    var payment = TransactionDraft(
      kind: .reimbursement, amount: AmountE4(whole: 1_000), debtId: UUID())
    payment.normalizeSinglePart()
    var reimbursement = TransactionDraft(kind: .reimbursement, amount: AmountE4(whole: 600))
    reimbursement.normalizeSinglePart()
    func message(_ entries: [TransactionEntry]) throws -> String {
      let confirmation = try XCTUnwrap(BulkConfirmation.deletion(of: entries, debts: [:]))
      return BulkConfirmationText.message(confirmation, environment: environment)
    }
    let reimbursementLine = environment.language("bulk.deleteReimbursement", table: "Transactions")
    let debtLine = environment.language("bulk.deleteDebtPayment", table: "Transactions")

    let onDebt = try message([try payment.materialize()])
    XCTAssertTrue(onDebt.contains(debtLine), onDebt)
    XCTAssertFalse(onDebt.contains(reimbursementLine), onDebt)

    let forPurchase = try message([try reimbursement.materialize()])
    XCTAssertTrue(forPurchase.contains(reimbursementLine), forPurchase)
    XCTAssertFalse(forPurchase.contains(debtLine), forPurchase)
  }

  /// Every sentence the dialogs are built from is in both languages, plural forms included:
  /// a key that resolves to itself would show up in the interface as it is.
  func testTheWordsOfTheConfirmationsAreTranslated() throws {
    let environment = AppEnvironment()
    let plan = BulkEditPlan(
      changed: [try saveEntries(["coffee"])[0]],
      skipped: [
        BulkSkip(transactionId: UUID(), reason: .goalContribution),
        BulkSkip(transactionId: UUID(), reason: .paidForSomebodyElse, isPartial: true),
      ],
      splitCount: 2)
    let confirmation = BulkConfirmation.edit(.quality(.bad), ids: [], plan: plan)
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let words =
        BulkConfirmationText.title(confirmation, environment: environment) + "\n"
        + BulkConfirmationText.message(confirmation, environment: environment)
      XCTAssertFalse(words.contains("bulk."), words)
      XCTAssertTrue(words.contains("2"), words)
      for key in ["selection.count", "selection.change", "totals.moneyReturned"] {
        XCTAssertNotEqual(environment.language(key, table: "Transactions"), key)
      }
      for reason in BulkSkipReason.allCases {
        let key = "bulk.reason.\(reason.rawValue)"
        XCTAssertNotEqual(environment.language(key, table: "Transactions"), key)
      }
    }
    environment.language.choice = .russian
    XCTAssertEqual(
      environment.language.format("selection.count", table: "Transactions", 5), "5 операций")
    XCTAssertEqual(
      environment.language.format("selection.count", table: "Transactions", 2), "2 операции")
    XCTAssertEqual(
      environment.language.format("selection.count", table: "Transactions", 21), "21 операция")
  }

  // MARK: Accounts

  /// Coffee for 1 000 ₽ on the card, and the lists knowing both accounts.
  private func coffeeOnTheCard() throws -> (
    entry: TransactionEntry, card: PaymentMethod, kaspi: PaymentMethod
  ) {
    try makeStore()
    let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
    let kaspi = PaymentMethod(name: "Kaspi", currency: CurrencyCode("KZT"))
    for account in [card, kaspi] { try references.save(account) }
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18)),
      amount: AmountE4(whole: 1_000), note: "coffee", paymentMethodId: card.id)
    draft.normalizeSinglePart()
    let entry = try repository.save(try draft.materialize())
    let dataset = Dataset(
      entries: try repository.entries(from: .distantPast, to: .distantFuture),
      categories: try references.categories(includeArchived: true),
      paymentMethods: [card, kaspi])
    store.show(Ledger(dataset: dataset, calendar: .utc))
    return (entry, card, kaspi)
  }

  /// 20 ₽ for 100 ₸ on the day of the coffee.
  private var tengeRates: DayRates {
    DayRates(series: [
      CurrencyCode("KZT"): [DayRate(day: DateOnly(year: 2026, month: 9, day: 18), perUnit: 0.2)]
    ])
  }

  /// Moved in bulk onto an account that does not hold rubles, the coffee says what that
  /// account was charged — worked out at the rates of its day — and ⌘Z puts it back on the
  /// card with nothing charged apart.
  func testMovingOperationsToAnAccountWithoutTheirCurrencyChargesIt() throws {
    let (entry, card, kaspi) = try coffeeOnTheCard()
    let kzt = CurrencyCode("KZT")

    let plan = store.plan(
      .paymentMethod(kaspi.id), ids: [entry.id], rates: tengeRates, calendar: .utc)
    XCTAssertEqual(plan.skipped, [])
    XCTAssertEqual(plan.changed.first?.transaction.accountCurrency, kzt)
    XCTAssertEqual(plan.changed.first?.transaction.accountAmountE4, AmountE4(whole: 5_000))

    XCTAssertTrue(
      store.apply(.paymentMethod(kaspi.id), to: [entry.id], rates: tengeRates, calendar: .utc))
    let moved = try XCTUnwrap(try repository.entry(id: entry.id))
    XCTAssertEqual(moved.transaction.paymentMethodId, kaspi.id)
    XCTAssertEqual(moved.transaction.accountCurrency, kzt)
    XCTAssertEqual(moved.transaction.accountAmountE4, AmountE4(whole: 5_000))

    store.undo()
    let back = try XCTUnwrap(try repository.entry(id: entry.id))
    XCTAssertEqual(back.transaction.paymentMethodId, card.id)
    XCTAssertNil(back.transaction.accountCurrency)
    XCTAssertNil(back.transaction.accountAmountE4)
  }

  /// Without the rate of the day nothing can be charged: the operation stays where it is, and
  /// the confirmation says why.
  func testAnOperationWithoutTheRateToChargeItStaysWhereItIs() throws {
    let (entry, _, kaspi) = try coffeeOnTheCard()
    let plan = store.plan(.paymentMethod(kaspi.id), ids: [entry.id], calendar: .utc)
    XCTAssertEqual(plan.changed, [])
    XCTAssertEqual(plan.skipped.map(\.reason), [.noRateForCharge])
  }

  /// A purchase a refund takes money back from is not deleted from under it: planned from the
  /// store, the deletion leaves it and says why.
  func testThePlannedDeletionKeepsAPurchaseWhoseRefundStays() throws {
    let entries = try saveEntries(["Sneakers"])
    let purchase = entries[0]
    let draft = try RefundRules.draft(
      refunding: purchase.parts[0], of: purchase, amount: AmountE4(whole: 40),
      occurredAt: purchase.transaction.occurredAt.addingTimeInterval(3600), accountId: nil,
      index: RefundIndex(entries: [purchase], debts: [:]), tree: CategoryTree())
    let refund = try repository.save(try draft.materialize())
    try showDatabase()

    let plan = store.planDeletion(ids: [purchase.id])
    XCTAssertEqual(plan.changed, [])
    XCTAssertEqual(plan.skipped.map(\.reason), [.hasRefunds])
    XCTAssertEqual(store.planDeletion(ids: [purchase.id, refund.id]).changed.count, 2)
  }

  /// The account menu of a selection moves operations to another account and never to none:
  /// every operation keeps one. The main account comes first, as in every menu of accounts,
  /// and an archived one is not offered.
  func testTheAccountMenuOffersEveryLiveAccountMainFirstAndNeverNone() {
    let cash = PaymentMethod(name: "Cash", currency: .rub)
    let main = PaymentMethod(name: "Zeta card", currency: .rub, isDefault: true)
    var old = PaymentMethod(name: "Old", currency: .rub)
    old.archived = true
    let edits = BulkMenuItems.accountEdits(
      [cash, old, main], locale: Locale(identifier: "en_US"))
    XCTAssertEqual(edits, [.paymentMethod(main.id), .paymentMethod(cash.id)])
    XCTAssertFalse(edits.contains(.paymentMethod(nil)))
  }

  /// Only a change of the account works out what an account is charged: the rest of the menu
  /// — a category, a place, an event, a quality, «на кого» — never reads the rate cache.
  func testOnlyAChangeOfTheAccountReadsTheRates() {
    XCTAssertTrue(BulkRates.needed(for: .paymentMethod(UUID())))
    for edit: BulkEdit in [
      .category(UUID()), .refile(from: [UUID()], to: UUID()), .quality(.bad),
      .forWhom(.family), .forPerson(UUID()), .event(nil), .place(UUID()),
    ] {
      XCTAssertFalse(BulkRates.needed(for: edit), "\(edit)")
    }
  }
}
