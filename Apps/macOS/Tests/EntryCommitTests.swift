import AppCore
import AppDatabase
import XCTest

@testable import Itogo

/// The old bug «⌘Z of a purchase on credit leaves its debt behind», long a known limitation
/// and fixed since: what the entry line saves — the operation, a debt opened for a purchase on
/// credit with its first line, the line of a debt payment, the link to an expected income —
/// is one write, and one ⌘Z takes all of it back.
@MainActor
final class EntryCommitTests: XCTestCase {
  private var store: TransactionsStore!
  private var references: ReferenceRepository!
  private var planning: PlanningRepository!
  private var transactions: TransactionRepository!

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let repository = TransactionRepository(writer: stack.writer)
    transactions = repository
    references = ReferenceRepository(writer: stack.writer)
    planning = PlanningRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(repository, references: references, planning: planning)
  }

  private func purchase(
    _ amount: Int64, creditDebtId: UUID? = nil, debtId: UUID? = nil
  )
    throws -> TransactionEntry
  {
    try TransactionDraft(
      amount: AmountE4(whole: amount), note: "phone", debtId: debtId, creditDebtId: creditDebtId,
      parts: [PartDraft(amount: AmountE4(whole: amount))]
    ).materialize()
  }

  func testUndoOfAPurchaseOnCreditTakesItsDebtAndFirstLineAway() throws {
    let debt = Debt(
      direction: .iOwe, type: .installment, name: "phone", paymentsAreExpenses: false,
      origin: .purchase)
    let entry = try purchase(60_000, creditDebtId: debt.id)
    let change = try XCTUnwrap(
      EntryCommit.change(
        entry: entry, openedCredit: debt, paidDebt: nil, expectedIncomeId: nil,
        day: DateOnly(year: 2026, month: 9, day: 19)))
    XCTAssertTrue(store.apply(change))
    XCTAssertEqual(try references.debts(includeClosed: true).map(\.id), [debt.id])
    let lines = try references.debtEntries(debtId: debt.id)
    XCTAssertEqual(lines.map(\.transactionId), [entry.id], "the first line points at its purchase")

    store.undo()
    XCTAssertEqual(try references.debts(includeClosed: true), [], "the debt went with the purchase")
    XCTAssertEqual(try references.debtEntries(debtId: debt.id), [])
  }

  func testUndoOfADebtPaymentTakesItsLineAway() throws {
    let debt = Debt(direction: .iOwe, type: .loan, name: "loan")
    var rows = PlanningRows.empty
    rows.debts = [debt]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    let entry = try purchase(8_500, debtId: debt.id)
    let change = try XCTUnwrap(
      EntryCommit.change(
        entry: entry, openedCredit: nil, paidDebt: debt, expectedIncomeId: nil,
        day: DateOnly(year: 2026, month: 9, day: 19)))
    XCTAssertTrue(store.apply(change))
    XCTAssertEqual(
      try references.debtEntries(debtId: debt.id).map(\.amountE4), [AmountE4(whole: -8_500)])

    store.undo()
    XCTAssertEqual(try references.debtEntries(debtId: debt.id), [])
    XCTAssertEqual(try references.debts(includeClosed: true).map(\.id), [debt.id], "the debt stays")
  }

  /// A refund of a loan payment brings the money back, so the debt grows back by it:
  /// it was written as one more payment, and the debt shrank twice.
  func testARefundOnADebtIOweGrowsItBack() throws {
    let debt = Debt(direction: .iOwe, type: .loan, name: "loan")
    var refund = try purchase(8_500, debtId: debt.id)
    refund.transaction.kind = .refund
    let change = try XCTUnwrap(
      EntryCommit.change(
        entry: refund, openedCredit: nil, paidDebt: debt, expectedIncomeId: nil,
        day: DateOnly(year: 2026, month: 9, day: 19)))
    XCTAssertEqual(change.upsert.debtEntries.map(\.kind), [.borrowed])
    XCTAssertEqual(change.upsert.debtEntries.map(\.amountE4), [AmountE4(whole: 8_500)])
  }

  func testAPlainOperationNeedsNoChangeOfPlanning() throws {
    XCTAssertNil(
      try EntryCommit.change(
        entry: try purchase(250), openedCredit: nil, paidDebt: nil, expectedIncomeId: nil,
        day: DateOnly(year: 2026, month: 9, day: 19)))
  }

  /// Money lent through the entry line — an expense on a debt owed to me — makes that debt
  /// grow; it is not a payment of it (review of the app, 19.09).
  func testLendingThroughTheEntryLineMakesTheDebtOwedToMeGrow() throws {
    let lent = Debt(direction: .owedToMe, type: .personal, name: "Igor", paymentsAreExpenses: false)
    let change = try XCTUnwrap(
      EntryCommit.change(
        entry: try purchase(5_000, debtId: lent.id), openedCredit: nil, paidDebt: lent,
        expectedIncomeId: nil, day: DateOnly(year: 2026, month: 9, day: 19)))
    XCTAssertEqual(change.upsert.debtEntries.map(\.amountE4), [AmountE4(whole: 5_000)])
    XCTAssertEqual(change.upsert.debtEntries.map(\.kind), [.borrowed])
  }

  /// Money received on a debt I owe is more borrowed, not a payment (review of the review
  /// fixes, 19.09): «+50000 долг Кредит» makes the loan grow by 50 000.
  func testMoneyReceivedOnADebtIOweMakesItGrow() throws {
    let loan = Debt(direction: .iOwe, type: .loan, name: "Loan")
    var received = try purchase(50_000, debtId: loan.id)
    received.transaction.kind = .income
    let change = try XCTUnwrap(
      EntryCommit.change(
        entry: received, openedCredit: nil, paidDebt: loan, expectedIncomeId: nil,
        day: DateOnly(year: 2026, month: 9, day: 19)))
    XCTAssertEqual(change.upsert.debtEntries.map(\.kind), [.borrowed])
    XCTAssertEqual(change.upsert.debtEntries.map(\.amountE4), [AmountE4(whole: 50_000)])
  }

  /// A debt kept in another currency is never moved by rubles taken for its units.
  func testADebtInAnotherCurrencyIsRefused() throws {
    let loan = Debt(direction: .iOwe, type: .loan, name: "USD loan", currency: CurrencyCode("USD"))
    XCTAssertThrowsError(
      try EntryCommit.change(
        entry: try purchase(27_000, debtId: loan.id), openedCredit: nil, paidDebt: loan,
        expectedIncomeId: nil, day: DateOnly(year: 2026, month: 9, day: 19)))
  }

  /// «Возврат денег от человека» chosen as the type in the ↓ panel, or typed as «вернули долг»,
  /// used to be written as a bare reimbursement: «Returns 1 700» on the day, and Anya still
  /// owing 1 700 in «Owed to me». It closes the parts the person owed through links,
  /// and the person and the parts are chosen in the reimbursement sheet:
  /// Enter hands the draft to it, prefilled.
  func testMoneyBackTypedInTheLineClosesThePartsThePersonOwes() throws {
    let anya = Person(name: "Anya")
    let boris = Person(name: "Boris")
    try references.save(anya)
    try references.save(boris)
    var dinner = TransactionDraft(amount: AmountE4(whole: 3_000), note: "dinner")
    dinner.parts = [
      PartDraft(amount: AmountE4(whole: 800)),
      PartDraft(amount: AmountE4(whole: 1_700), reimbursable: true, debtorPersonId: anya.id),
      PartDraft(amount: AmountE4(whole: 500), reimbursable: true, debtorPersonId: boris.id),
    ]
    try transactions.save(try dinner.materialize())

    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    model.reload()
    let yesterday = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18))
      .addingTimeInterval(12 * 3600)
    model.draft.kind = .reimbursement
    model.draft.amount = AmountE4(whole: 1_700)
    model.draft.note = "Anya for the dinner"
    model.draft.occurredAt = yesterday
    model.draft.normalizeSinglePart()
    model.draft.parts[0].forPersonId = anya.id
    XCTAssertNil(model.saveRefusalKey)

    XCTAssertTrue(
      model.recordsThroughReimbursementSheet,
      "Enter must not write a reimbursement that closes nothing")
    let prefill = ReimbursementPrefill(draft: model.draft, received: model.draft.amount)
    let owed = try transactions.owedParts()
    let ticked = prefill.initialSelection(in: owed)
    let closing = owed.filter { ticked.contains($0.partId) }
    XCTAssertEqual(closing.map(\.debtorPersonId), [anya.id], "the parts Anya owes are ticked")

    let recorded = try ReimbursementRecording.make(
      id: UUID(), received: prefill.received, closing: closing,
      distribution: ReimbursementDistribution(), personId: prefill.personId,
      occurredAt: prefill.occurredAt, note: prefill.note,
      setting: ReimbursementRecording.Setting(
        surchargesCategoryId: nil, categories: CategoryTree([]), history: .empty,
        surplusNote: "surplus", shortfallNote: "shortfall"))
    try transactions.apply(
      recorded.outcome, reimbursement: recorded.reimbursement, extra: recorded.extra)

    XCTAssertEqual(try transactions.owedParts().map(\.debtorPersonId), [boris.id])
    let written = try XCTUnwrap(transactions.entry(id: recorded.reimbursement.id))
    XCTAssertEqual(written.transaction.occurredAt, yesterday, "the day the line named")
    XCTAssertEqual(written.transaction.note, "Anya for the dinner")
    XCTAssertEqual(written.parts.first?.forPersonId, anya.id)
  }

  /// Money given back on a debt owed to me is a payment of that debt, not money back for
  /// parts: the line keeps writing it with its journal line.
  func testMoneyBackOnADebtOwedToMeStaysAPaymentOfTheDebt() throws {
    let lent = Debt(direction: .owedToMe, type: .personal, name: "Igor", paymentsAreExpenses: false)
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    model.draft.kind = .reimbursement
    model.draft.amount = AmountE4(whole: 5_000)
    model.draft.debtId = lent.id
    model.draft.normalizeSinglePart()
    XCTAssertFalse(model.recordsThroughReimbursementSheet)
  }
}

/// What the entry line says when saving throws once the line has been read: the expression
/// was calculated already, so no failure there is «the expression cannot be calculated».
final class EntryCommitErrorTests: XCTestCase {
  func testAnAmountTooLargeForRublesIsSaidToBeTooLarge() {
    // $100 billion at 100 000 rubles to the dollar: more rubles than an operation can hold.
    let tooLarge: any Error
    do {
      _ = try AmountE4(decimal: Decimal(100_000_000_000) * Decimal(100_000))
      return XCTFail("the amount fits after all")
    } catch {
      tooLarge = error
    }
    XCTAssertEqual(EntryCommit.errorKey(of: tooLarge), "entry.error.amountTooLarge")
  }

  func testAFailureNobodyForesawIsSaidToHaveKeptTheOperationUnsaved() {
    XCTAssertEqual(EntryCommit.errorKey(of: DebtError.negativeAmount), "entry.error.notSaved")
    XCTAssertEqual(EntryCommit.errorKey(of: CocoaError(.fileWriteUnknown)), "entry.error.notSaved")
  }

  func testTheFailuresTheLineKnowsKeepTheirWords() {
    XCTAssertEqual(
      EntryCommit.errorKey(of: EntryCommit.CurrencyMismatch()), "entry.error.debtCurrency")
    XCTAssertEqual(
      EntryCommit.errorKey(of: MoneyConversionError.rateMissing), "entry.error.rateMissing")
    XCTAssertEqual(EntryCommit.errorKey(of: CoreError.divisionByZero), "entry.error.divisionByZero")
  }
}
