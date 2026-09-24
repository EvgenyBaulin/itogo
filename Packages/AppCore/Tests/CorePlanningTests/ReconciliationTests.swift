import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

/// A dataset for the reconciliation and reminder suites, built in code: fixed ids, UTC
/// moments, round amounts, nothing real. Helpers are static members so they never clash
/// with the builders of the other planning suites.
struct ReconcileSketch {
  static let groceries = id(10)
  static let goals = id(11)
  static let goalTrip = id(12)
  static let unknownExpense = id(13)
  static let loans = id(14)
  static let salary = id(20)
  static let surcharges = id(21)
  static let unknownIncome = id(22)

  static let categories: [CoreKit.Category] = [
    CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral),
    CoreKit.Category(
      id: goals, kind: .expense, name: "Goals", quality: .good, systemRole: .goals),
    CoreKit.Category(id: goalTrip, parentId: goals, kind: .expense, name: "Trip"),
    CoreKit.Category(
      id: unknownExpense, kind: .expense, name: "Unknown", systemRole: .unknown),
    CoreKit.Category(
      id: loans, kind: .expense, name: "Loans", quality: .neutral, systemRole: .loans),
    CoreKit.Category(id: salary, kind: .income, name: "Salary"),
    CoreKit.Category(
      id: surcharges, kind: .income, name: "Surcharges", systemRole: .surcharges),
    CoreKit.Category(id: unknownIncome, kind: .income, name: "Unknown", systemRole: .unknown),
  ]

  /// The previous reconciliation of most cases: 1 September, made at 18:00, 100 000 ₽.
  static let previous = Reconciliation(
    id: id(1), date: day("2026-09-01"), reconciledAt: at("2026-09-01", 18),
    actualTotalRubE4: money("100000"))
  /// The moment the next one is made.
  static let now = at("2026-09-15", 12)

  var entries: [TransactionEntry] = []
  var debts: [Debt] = []
  var book = PlanningBook(reconciliations: [ReconcileSketch.previous])
  private var next = 1000

  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  static func day(_ iso: String) -> DateOnly {
    DateOnly(iso: iso) ?? DateOnly(year: 2026, month: 1, day: 1)
  }

  static func money(_ text: String) -> AmountE4 {
    amountLiteral(text)
  }

  /// `hour:minute` UTC on a day.
  static func at(_ iso: String, _ hour: Int, _ minute: Int = 0) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(
      TimeInterval(hour * 3600 + minute * 60))
  }

  /// One operation of one part, in rubles. Spending goes to Groceries and income to Salary
  /// unless a category is given; a reimbursement has none, as the app writes it.
  @discardableResult
  mutating func add(
    _ kind: TransactionKind, _ amount: String, at moment: Date = at("2026-09-10", 12),
    category: UUID? = nil, reimbursable: Bool = false, status: ReimbursementStatus? = nil,
    debt: UUID? = nil, creditDebt: UUID? = nil, link: OperationLink? = nil,
    deleted: Bool = false
  ) -> UUID {
    next += 1
    let transactionId = Self.id(next)
    let defaultCategory: UUID? =
      switch kind {
      case .expense, .refund: Self.groceries
      case .income: Self.salary
      case .reimbursement: nil
      }
    let part = TransactionPart(
      id: Self.id(next + 500_000), transactionId: transactionId,
      categoryId: category ?? defaultCategory,
      quality: kind.hasQuality ? .neutral : nil, qualitySource: kind.hasQuality ? .category : nil,
      amountE4: Self.money(amount), reimbursable: reimbursable,
      reimbursementStatus: reimbursable ? (status ?? .expected) : status)
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: transactionId, kind: kind, occurredAt: moment, amountE4: Self.money(amount),
          debtId: debt, creditDebtId: creditDebt, externalId: link?.externalId,
          createdAt: moment, updatedAt: moment, deletedAt: deleted ? moment : nil),
        parts: [part]))
    return transactionId
  }

  /// A line of a debt journal that no operation wrote.
  mutating func journal(
    _ debt: UUID, _ amount: String, on iso: String?, kind: DebtEntryKind = .borrowed,
    transactionId: UUID? = nil
  ) {
    next += 1
    book.debtEntries.append(
      DebtRules.makeEntry(
        id: Self.id(next), debtId: debt, kind: kind, amountE4: Self.money(amount),
        date: iso.map(Self.day), transactionId: transactionId))
  }

  var ledger: Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, categories: Self.categories, debts: debts, planning: book),
      calendar: .utc)
  }

  func expectation(
    now: Date = ReconcileSketch.now, rubPerUnit: [CurrencyCode: Decimal] = [:]
  ) -> ReconciliationExpectation? {
    ReconciliationRules.expectation(
      ledger: ledger, book: book, now: now, calendar: .utc, rubPerUnit: rubPerUnit)
  }

  // Debts of the cases.

  static func loan(_ number: Int, currency: CurrencyCode = .rub) -> Debt {
    Debt(
      id: id(number), direction: .iOwe, type: .loan, name: "Loan", currency: currency,
      paymentsAreExpenses: true, origin: .existing, loansSubcategoryId: loans)
  }

  static func instalments(_ number: Int) -> Debt {
    Debt(
      id: id(number), direction: .iOwe, type: .installment, name: "Instalments",
      paymentsAreExpenses: false, origin: .purchase)
  }

  static func lentTo(_ number: Int) -> Debt {
    Debt(id: id(number), direction: .owedToMe, type: .personal, name: "Personal")
  }
}

/// The lines of an expectation that moved, without the starting point: which lines a case
/// touches is half of what it checks.
private func moved(_ expectation: ReconciliationExpectation?) -> [ReconciliationTerm: AmountE4] {
  var result: [ReconciliationTerm: AmountE4] = [:]
  for line in expectation?.lines ?? [] where line.term != .previous && !line.amount.isZero {
    result[line.term] = line.amount
  }
  return result
}

@Suite("Reconciliation: the expected total, line by line")
struct ReconciliationTests {
  typealias S = ReconcileSketch

  // MARK: - The starting point

  @Test func theFirstReconciliationIsTheStartingPoint() {
    var sketch = S()
    sketch.book.reconciliations = []
    sketch.add(.income, "5000")
    #expect(sketch.expectation() == nil)
  }

  /// The latest by day, then by moment — whatever order the records come in.
  @Test func theNextCountsFromTheLatest() {
    let early = Reconciliation(
      id: S.id(2), date: S.day("2026-09-01"), reconciledAt: S.at("2026-09-01", 9),
      actualTotalRubE4: S.money("1"))
    let late = Reconciliation(
      id: S.id(3), date: S.day("2026-09-01"), reconciledAt: S.at("2026-09-01", 20),
      actualTotalRubE4: S.money("2"))
    let older = Reconciliation(
      id: S.id(4), date: S.day("2026-08-01"), actualTotalRubE4: S.money("3"))
    #expect(ReconciliationRules.latest([late, older, early])?.id == late.id)
    #expect(ReconciliationRules.latest([]) == nil)

    var sketch = S()
    sketch.book.reconciliations = [late, older, early]
    let expectation = sketch.expectation()
    #expect(expectation?.previous.id == late.id)
    #expect(expectation?.from == S.at("2026-09-01", 20))
    #expect(expectation?.to == S.now)
    #expect(expectation?.expected == S.money("2"))
    #expect(expectation?.lines.first == ReconciliationLine(term: .previous, amount: S.money("2")))
  }

  // MARK: - One line each

  @Test func incomeAddsEveryIncome() {
    var sketch = S()
    sketch.add(.income, "5000")
    let expectation = sketch.expectation()
    #expect(moved(expectation) == [.income: S.money("5000")])
    #expect(expectation?.expected == S.money("105000"))
  }

  /// The surplus record is income, and the same money is inside the reimbursement: taken
  /// back out once.
  @Test func theSurplusIsTakenBackOutOfIncome() {
    var sketch = S()
    sketch.add(.income, "200", category: S.surcharges, link: .surplus(reimbursement: "7"))
    let expectation = sketch.expectation()
    #expect(moved(expectation) == [.income: S.money("200"), .surplus: S.money("200")])
    #expect(expectation?.expected == S.money("100000"))
  }

  @Test func moneyReturnedCountsAsReceived() {
    var sketch = S()
    sketch.add(.reimbursement, "1200")
    let expectation = sketch.expectation()
    #expect(moved(expectation) == [.returned: S.money("1200")])
    #expect(expectation?.expected == S.money("101200"))
  }

  @Test func myExpensesAreTheContributions() {
    var spending = S()
    spending.add(.expense, "3000")
    #expect(moved(spending.expectation()) == [.myExpenses: S.money("3000")])
    #expect(spending.expectation()?.expected == S.money("97000"))

    var refund = S()
    refund.add(.refund, "500")
    #expect(moved(refund.expectation()) == [.myExpenses: S.money("-500")])
    #expect(refund.expectation()?.expected == S.money("100500"))
  }

  /// A shortfall is my expense today, but its money left at the purchase.
  @Test func aShortfallIsAddedBack() {
    var sketch = S()
    sketch.add(.expense, "300", link: .shortfall(reimbursement: "7", part: "8"))
    let expectation = sketch.expectation()
    #expect(moved(expectation) == [.myExpenses: S.money("300"), .shortfalls: S.money("300")])
    #expect(expectation?.expected == S.money("100000"))
  }

  @Test func aPurchaseOnCreditLeavesNoMoney() {
    var sketch = S()
    sketch.debts = [S.instalments(300)]
    sketch.add(.expense, "50000", creditDebt: S.id(300))
    let expectation = sketch.expectation()
    #expect(moved(expectation) == [.myExpenses: S.money("50000"), .onCredit: S.money("50000")])
    #expect(expectation?.expected == S.money("100000"))
  }

  @Test func goalSavingsStayInTheTotalWhenTheSettingSaysSo() {
    var sketch = S()
    sketch.add(.expense, "2000", category: S.goalTrip)
    let kept = sketch.expectation()
    #expect(moved(kept) == [.myExpenses: S.money("2000"), .goalSavings: S.money("2000")])
    #expect(kept?.expected == S.money("100000"))

    sketch.book.settings.reconcileIncludesGoalSavings = false
    let spent = sketch.expectation()
    #expect(spent?.amount(of: .goalSavings) == nil)
    #expect(spent?.lines.count == ReconciliationTerm.allCases.count - 1)
    #expect(moved(spent) == [.myExpenses: S.money("2000")])
    #expect(spent?.expected == S.money("98000"))
  }

  /// Paid for somebody: the money left either way. Whether it came back is line 4's
  /// business, so a part bought and returned in one window is still subtracted.
  @Test func partsForOthersBothWaysAndWrittenOff() {
    var waiting = S()
    waiting.add(.expense, "1000", reimbursable: true, status: .expected)
    #expect(moved(waiting.expectation()) == [.paidForOthersExpected: S.money("1000")])
    #expect(waiting.expectation()?.expected == S.money("99000"))

    var returned = S()
    returned.add(.expense, "1000", reimbursable: true, status: .returned)
    #expect(moved(returned.expectation()) == [.paidForOthersReturned: S.money("1000")])
    #expect(returned.expectation()?.expected == S.money("99000"))

    var writtenOff = S()
    writtenOff.add(.expense, "1000", reimbursable: true, status: .writtenOff)
    #expect(moved(writtenOff.expectation()) == [.myExpenses: S.money("1000")])
    #expect(writtenOff.expectation()?.expected == S.money("99000"))
  }

  @Test func debtPaymentsThatAreNotExpenses() {
    var instalment = S()
    instalment.debts = [S.instalments(300)]
    instalment.add(.expense, "5000", category: S.loans, debt: S.id(300))
    #expect(moved(instalment.expectation()) == [.debtPayments: S.money("5000")])
    #expect(instalment.expectation()?.expected == S.money("95000"))

    // A payment that is an expense is in my expenses and nowhere else.
    var loan = S()
    loan.debts = [S.loan(301)]
    loan.add(.expense, "5000", category: S.loans, debt: S.id(301))
    #expect(moved(loan.expectation()) == [.myExpenses: S.money("5000")])

    // A refund of such a payment brings the money back.
    var refund = S()
    refund.debts = [S.instalments(300)]
    refund.add(.refund, "1000", category: S.loans, debt: S.id(300))
    #expect(moved(refund.expectation()) == [.debtPayments: S.money("-1000")])
    #expect(refund.expectation()?.expected == S.money("101000"))
  }

  @Test func repaymentsOfDebtsOwedToMe() {
    var sketch = S()
    sketch.debts = [S.lentTo(302)]
    sketch.add(.reimbursement, "2000", debt: S.id(302))
    let expectation = sketch.expectation()
    #expect(moved(expectation) == [.repaidToMe: S.money("2000")])
    #expect(expectation?.expected == S.money("102000"))
  }

  /// Money borrowed that only the journal knows about, by the date of the line in
  /// (previous day, today].
  @Test func borrowedMoneyFromTheJournal() {
    var sketch = S()
    sketch.debts = [S.loan(301), S.instalments(300)]
    sketch.journal(S.id(301), "100000", on: "2026-09-10")
    // On the day of the previous reconciliation, after today, written with an operation:
    // not in this window or not this line's.
    sketch.journal(S.id(301), "1", on: "2026-09-01")
    sketch.journal(S.id(301), "2", on: "2026-09-16")
    sketch.journal(S.id(301), "3", on: "2026-09-10", transactionId: S.id(9))
    // Other kinds move the balance, not my money.
    sketch.journal(S.id(301), "4", on: "2026-09-10", kind: .transferIn)
    sketch.journal(S.id(301), "5", on: "2026-09-10", kind: .adjustment)
    // A debt of a purchase on credit never brought money.
    sketch.journal(S.id(300), "6", on: "2026-09-10")
    // No date: counted, not guessed.
    sketch.journal(S.id(301), "7", on: nil)
    // A debt the dataset does not know.
    sketch.journal(S.id(399), "8", on: "2026-09-10")

    let expectation = sketch.expectation()
    #expect(moved(expectation) == [.borrowed: S.money("100000")])
    #expect(expectation?.expected == S.money("200000"))
    #expect(expectation?.undatedJournalLines == 1)
    #expect(expectation?.journalLinesWithoutRate == 0)
  }

  /// A purchase put on a debt I already had writes an opening line without an operation:
  /// it has the debt, the day and the amount of the purchase, and is not money borrowed.
  @Test func theOpeningLineOfAPurchaseOnCreditIsNotBorrowing() {
    var sketch = S()
    // A credit card: its payments are the expenses, so the purchase itself is not.
    sketch.debts = [S.loan(301)]
    sketch.add(.expense, "3000", creditDebt: S.id(301))
    sketch.journal(S.id(301), "3000", on: "2026-09-10")
    // A second line of the same amount the same day has no purchase to explain it.
    sketch.journal(S.id(301), "3000", on: "2026-09-10")
    let expectation = sketch.expectation()
    #expect(moved(expectation) == [.borrowed: S.money("3000")])
    #expect(expectation?.expected == S.money("103000"))
  }

  @Test func lentMoneyFromTheJournalAndFromAnOperation() {
    var sketch = S()
    sketch.debts = [S.lentTo(302)]
    sketch.journal(S.id(302), "5000", on: "2026-09-10")
    let journal = sketch.expectation()
    #expect(moved(journal) == [.lent: S.money("5000")])
    #expect(journal?.expected == S.money("95000"))

    // Money given through an operation on a debt owed to me is lending too.
    var operation = S()
    operation.debts = [S.lentTo(302)]
    operation.add(.expense, "700", debt: S.id(302))
    #expect(moved(operation.expectation()) == [.lent: S.money("700")])
  }

  @Test func aForeignJournalLineNeedsARate() {
    var sketch = S()
    sketch.debts = [S.loan(303, currency: .usd)]
    sketch.journal(S.id(303), "100.5", on: "2026-09-10")
    let converted = sketch.expectation(rubPerUnit: [.usd: Decimal(string: "90.25")!])
    // 100.5 × 90.25 = 9 070.125
    #expect(moved(converted) == [.borrowed: S.money("9070.125")])
    #expect(converted?.journalLinesWithoutRate == 0)

    let unknown = sketch.expectation()
    #expect(moved(unknown).isEmpty)
    #expect(unknown?.journalLinesWithoutRate == 1)
  }

  // MARK: - The window

  /// The window opens at the moment of the previous reconciliation, not at its day.
  @Test func theWindowOpensAtThePreviousMoment() {
    var sketch = S()
    sketch.add(.expense, "1000", at: S.at("2026-09-01", 17))
    sketch.add(.expense, "2000", at: S.at("2026-09-01", 18))
    sketch.add(.expense, "100", at: S.at("2026-09-01", 19))
    sketch.add(.expense, "1", at: S.now)
    sketch.add(.expense, "10", at: S.at("2026-09-15", 13))
    let expectation = sketch.expectation()
    #expect(moved(expectation) == [.myExpenses: S.money("101")])
  }

  /// Without a moment the whole day of the previous reconciliation belongs to it.
  @Test func withoutAMomentTheWindowOpensAfterItsDay() {
    var sketch = S()
    sketch.book.reconciliations = [
      Reconciliation(id: S.id(2), date: S.day("2026-09-01"), actualTotalRubE4: S.money("100000"))
    ]
    sketch.add(.expense, "1000", at: S.at("2026-09-01", 23))
    sketch.add(.expense, "100", at: S.at("2026-09-02", 0, 30))
    let expectation = sketch.expectation()
    #expect(expectation?.from == CalendarContext.utc.endOfDay(S.day("2026-09-01")))
    #expect(moved(expectation) == [.myExpenses: S.money("100")])
  }

  /// The difference the previous reconciliation wrote is written a moment after it; it is
  /// the books catching up, not money that moved.
  @Test func theDifferenceRecordIsLeftOut() {
    var sketch = S()
    sketch.add(
      .income, "700", at: S.at("2026-09-01", 18, 1), category: S.unknownIncome,
      link: .reconciliation(S.previous.id))
    sketch.add(
      .expense, "300", at: S.at("2026-09-05", 10), category: S.unknownExpense,
      link: .reconciliation(S.id(77)))
    #expect(moved(sketch.expectation()).isEmpty)
    #expect(sketch.expectation()?.expected == S.money("100000"))
  }

  @Test func deletedOperationsNeverCount() {
    var sketch = S()
    sketch.add(.income, "5000", deleted: true)
    sketch.add(.expense, "300", deleted: true)
    #expect(moved(sketch.expectation()).isEmpty)
  }

  // MARK: - A whole window

  /// A fortnight of everything at once. The expected total must equal the money that
  /// really moved: +60 000 salary − 3 000 groceries + 500 refund − 2 000 gift + 2 500 back
  /// − 1 500 dinner + 1 000 back − 800 ticket − 2 500 instalment − 7 000 loan + 20 000
  /// borrowed − 3 000 lent + 1 000 repaid = +65 200 (the 5 000 for the goal stays in the
  /// total, the laptop on credit took no money).
  @Test func aWholeWindowAddsUpToTheMoneyThatMoved() {
    var sketch = S()
    sketch.debts = [S.instalments(300), S.loan(301), S.lentTo(302), S.loan(304)]
    sketch.add(.income, "60000")
    sketch.add(.expense, "3000")
    sketch.add(.refund, "500")
    // A gift for a friend, 2 000, returned with 2 500: 500 of surplus.
    sketch.add(.expense, "2000", reimbursable: true, status: .returned)
    sketch.add(.reimbursement, "2500")
    sketch.add(.income, "500", category: S.surcharges, link: .surplus(reimbursement: "a"))
    // A dinner for a friend, 1 500, returned with 1 000: 500 of shortfall.
    sketch.add(.expense, "1500", reimbursable: true, status: .returned)
    sketch.add(.reimbursement, "1000")
    sketch.add(.expense, "500", link: .shortfall(reimbursement: "b", part: "c"))
    // A ticket for a friend, not returned yet.
    sketch.add(.expense, "800", reimbursable: true, status: .expected)
    sketch.add(.expense, "5000", category: S.goalTrip)
    // A laptop on credit and its opening line, then one instalment.
    sketch.add(.expense, "30000", creditDebt: S.id(300))
    sketch.journal(S.id(300), "30000", on: "2026-09-10")
    let instalment = sketch.add(.expense, "2500", category: S.loans, debt: S.id(300))
    sketch.journal(S.id(300), "2500", on: "2026-09-10", kind: .payment, transactionId: instalment)
    sketch.add(.expense, "7000", category: S.loans, debt: S.id(301))
    sketch.journal(S.id(304), "20000", on: "2026-09-03")
    sketch.journal(S.id(302), "3000", on: "2026-09-04")
    sketch.add(.reimbursement, "1000", debt: S.id(302))

    let expectation = sketch.expectation()
    #expect(
      moved(expectation) == [
        .income: S.money("60500"),
        .surplus: S.money("500"),
        .returned: S.money("3500"),
        // 3 000 − 500 + 500 + 5 000 + 30 000 + 7 000
        .myExpenses: S.money("45000"),
        .shortfalls: S.money("500"),
        .onCredit: S.money("30000"),
        .goalSavings: S.money("5000"),
        .paidForOthersExpected: S.money("800"),
        .paidForOthersReturned: S.money("3500"),
        .debtPayments: S.money("2500"),
        .repaidToMe: S.money("1000"),
        .borrowed: S.money("20000"),
        .lent: S.money("3000"),
      ])
    #expect(expectation?.expected == S.money("165200"))
    #expect(expectation?.lines.map(\.term) == ReconciliationTerm.allCases)
    #expect(expectation?.lines.allSatisfy { $0.sign == $0.term.sign } == true)
    #expect(expectation?.difference(actual: S.money("165000")) == S.money("-200"))
  }

  @Test func termsHaveStableKeysAndSigns() {
    #expect(ReconciliationTerm.income.key == "reconcile.term.income")
    #expect(ReconciliationTerm.paidForOthersExpected.key == "reconcile.term.paidForOthersExpected")
    let minus = ReconciliationTerm.allCases.filter { $0.sign == .minus }
    #expect(
      minus == [
        .surplus, .myExpenses, .paidForOthersExpected, .paidForOthersReturned, .debtPayments, .lent,
      ])
    #expect(ReconciliationLine(term: .lent, amount: S.money("5")).signedAmount == S.money("-5"))
  }

  // MARK: - The actual total

  @Test func theBreakdownConvertsEveryCurrency() throws {
    let amounts = try ReconciliationRules.breakdown(
      [
        Money(amount: S.money("50000"), currency: .rub),
        Money(amount: S.money("100.5"), currency: .usd),
        // 1.0001 × 0.5 = 0.50005: half away from zero, both ways.
        Money(amount: S.money("1.0001"), currency: CurrencyCode("KZT")),
        Money(amount: S.money("-1.0001"), currency: CurrencyCode("KZT")),
      ],
      rubPerUnit: [
        .usd: Decimal(string: "90.25")!, CurrencyCode("KZT"): Decimal(string: "0.5")!,
        .rub: 2,
      ])
    #expect(
      amounts.map(\.rubE4) == [
        S.money("50000"), S.money("9070.125"), S.money("0.5001"), S.money("-0.5001"),
      ])
    #expect(amounts[0].rubPerUnit == nil)
    #expect(amounts[1].rubPerUnit == Decimal(string: "90.25"))
    #expect(amounts[1].amountE4 == S.money("100.5"))
    #expect(ReconciliationRules.actualTotal(amounts) == S.money("59070.125"))
    #expect(ReconciliationRules.actualTotal([]) == .zero)
  }

  @Test func aCurrencyWithoutARateIsNotGuessed() {
    #expect(throws: ReconciliationError.missingRate(.eur)) {
      try ReconciliationRules.breakdown(
        [
          Money(amount: S.money("10"), currency: .usd), Money(amount: S.money("5"), currency: .eur),
        ],
        rubPerUnit: [.usd: 90])
    }
    #expect(throws: ReconciliationError.missingRate(.usd)) {
      try ReconciliationRules.breakdown(
        [Money(amount: S.money("10"), currency: .usd)], rubPerUnit: [.usd: 0])
    }
  }

  // MARK: - The difference

  @Test func lessMoneyThanExpectedIsAnExpenseOnTheDayOfTheReconciliation() throws {
    let when = S.at("2026-09-15", 12)
    let draft = try #require(
      ReconciliationRules.differenceDraft(
        difference: S.money("-1500"), occurredAt: when,
        expenseCategoryId: S.unknownExpense, incomeCategoryId: S.unknownIncome,
        categories: CategoryTree(S.categories)))
    #expect(draft.kind == .expense)
    #expect(draft.amount == S.money("1500"))
    #expect(draft.currency == .rub)
    #expect(draft.occurredAt == when)
    #expect(draft.note == nil)
    #expect(draft.isBalanced)
    #expect(draft.parts.count == 1)
    #expect(draft.parts[0].categoryId == S.unknownExpense)
    #expect(draft.parts[0].categorySource == .system)
    #expect(draft.parts[0].quality == .neutral)
    #expect(draft.parts[0].qualitySource == .category)
  }

  @Test func moreMoneyThanExpectedIsIncomeOnTheDayOfTheReconciliation() throws {
    let draft = try #require(
      ReconciliationRules.differenceDraft(
        difference: S.money("700"), occurredAt: S.now,
        expenseCategoryId: S.unknownExpense, incomeCategoryId: S.unknownIncome))
    #expect(draft.kind == .income)
    #expect(draft.amount == S.money("700"))
    #expect(draft.parts.map(\.categoryId) == [S.unknownIncome])
    #expect(draft.parts[0].quality == nil)
    #expect(draft.isBalanced)
  }

  @Test func noDifferenceNothingToWrite() {
    #expect(
      ReconciliationRules.differenceDraft(
        difference: .zero, occurredAt: S.now, expenseCategoryId: S.unknownExpense,
        incomeCategoryId: S.unknownIncome) == nil)
  }

  // MARK: - Is it time

  @Test func isDueBeforeTheFirstAndAfterEveryNDays() {
    let last = Reconciliation(date: S.day("2026-09-01"), actualTotalRubE4: .zero)
    #expect(ReconciliationRules.isDue(last: nil, today: S.day("2026-09-01"), everyDays: 14))
    #expect(!ReconciliationRules.isDue(last: last, today: S.day("2026-09-01"), everyDays: 14))
    #expect(!ReconciliationRules.isDue(last: last, today: S.day("2026-09-15"), everyDays: 14))
    #expect(ReconciliationRules.isDue(last: last, today: S.day("2026-09-16"), everyDays: 14))
    #expect(ReconciliationRules.isDue(last: last, today: S.day("2026-09-02"), everyDays: 0))
  }
}
