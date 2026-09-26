import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A book of accounts, payments, debts, goals and events built in code for the free-sum
/// suites: fixed ids, UTC moments, round amounts, nothing real.
///
/// Main (rubles, main account) and Card (rubles, dollars) have no group; Freedom (tenge) is in
/// «Казахстан», left out of the summary. Today is 19 September 2026, 15:00; a dollar is 90 ₽,
/// a tenge 0.2 ₽, there is no rate for euros.
struct CashFx {
  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "CA5E0000-0000-0000-0000-%012d", number)) ?? UUID()
  }
  static func day(_ iso: String) -> DateOnly {
    DateOnly(iso: iso) ?? DateOnly(year: 1970, month: 1, day: 1)
  }
  /// `hour:minute` UTC of a day.
  static func at(_ iso: String, _ hour: Int, _ minute: Int = 0) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(
      TimeInterval(hour * 3600 + minute * 60))
  }
  static func money(_ text: String) -> AmountE4 { amountLiteral(text) }

  static let today = day("2026-09-19")
  static let now = at("2026-09-19", 15)
  static let tenge = CurrencyCode("KZT")

  static let main = id(1)
  static let card = id(2)
  static let freedom = id(3)
  static let kazakhstan = id(11)

  static let groceries = id(20)
  static let housing = id(21)
  static let rent = id(22)
  static let goalsRoot = id(23)
  static let tripGoal = id(24)
  static let salary = id(25)
  static let fun = id(26)

  static let categories: [CoreKit.Category] = [
    CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral),
    CoreKit.Category(id: housing, kind: .expense, name: "Housing", quality: .neutral),
    CoreKit.Category(id: rent, parentId: housing, kind: .expense, name: "Rent"),
    CoreKit.Category(id: fun, kind: .expense, name: "Fun", quality: .neutral),
    CoreKit.Category(
      id: goalsRoot, kind: .expense, name: "Goals", quality: .good, systemRole: .goals),
    CoreKit.Category(id: tripGoal, parentId: goalsRoot, kind: .expense, name: "Trip"),
    CoreKit.Category(id: salary, kind: .income, name: "Salary"),
  ]

  var accounts: [PaymentMethod] = [
    PaymentMethod(id: CashFx.main, name: "Main", currency: .rub, isDefault: true),
    PaymentMethod(id: CashFx.card, name: "Card", currency: .rub, otherCurrencies: [.usd]),
    PaymentMethod(
      id: CashFx.freedom, name: "Freedom", currency: CashFx.tenge, groupId: CashFx.kazakhstan),
  ]
  var groups = [AccountGroup(id: CashFx.kazakhstan, name: "Казахстан", inSummary: false)]
  var entries: [TransactionEntry] = []
  var transfers: [Transfer] = []
  var reconciliations: [Reconciliation] = []
  var counts: [ReconciledBalance] = []
  var scheduled: [ScheduledPayment] = []
  var prices: [SubscriptionPrice] = []
  var debts: [Debt] = []
  var debtEntries: [DebtEntry] = []
  var goals: [Goal] = []
  var events: [Event] = []
  var expected: [ExpectedIncome] = []
  var expectedLinks: [ExpectedIncomeLink] = []
  var settings = PlanningSettings()
  var rubPerUnit: [CurrencyCode: Decimal] = [.usd: 90, CashFx.tenge: Decimal(string: "0.2") ?? 0]
  private var next = 1000

  /// One reconciliation counting the given balances at `moment`.
  mutating func count(
    _ balances: [(UUID, CurrencyCode, String)], at moment: Date,
    kind: ReconciliationKind = .accounts
  ) {
    next += 1
    let reconciliation = Reconciliation(
      id: Self.id(next), date: CalendarContext.utc.day(of: moment), reconciledAt: moment,
      actualTotalRubE4: .zero, kind: kind)
    reconciliations.append(reconciliation)
    for (account, currency, amount) in balances {
      next += 1
      counts.append(
        ReconciledBalance(
          id: Self.id(next), reconciliationId: reconciliation.id, accountId: account,
          currency: currency, actualE4: Self.money(amount)))
    }
  }

  /// One operation of one part; foreign amounts at today's rate.
  @discardableResult
  mutating func add(
    _ kind: TransactionKind, _ amount: String, at moment: Date,
    currency: CurrencyCode = .rub, account: UUID? = CashFx.main,
    category: UUID? = CashFx.groceries, goal: UUID? = nil, debt: UUID? = nil,
    note: String? = nil, link: OperationLink? = nil
  ) -> UUID {
    next += 1
    let transactionId = Self.id(next)
    let value = Self.money(amount)
    let rubles =
      currency == .rub
      ? value : SubscriptionMath.rounded(value.decimal * (rubPerUnit[currency] ?? 1))
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: transactionId, kind: kind, occurredAt: moment, currency: currency, amountE4: value,
          amountRubE4: rubles, note: note, paymentMethodId: account, debtId: debt,
          externalId: link?.externalId, createdAt: moment, updatedAt: moment),
        parts: [
          TransactionPart(
            id: Self.id(next + 500_000), transactionId: transactionId, categoryId: category,
            quality: kind.hasQuality ? .neutral : nil,
            qualitySource: kind.hasQuality ? .category : nil, amountE4: value,
            amountRubE4: rubles, goalId: goal)
        ]))
    return transactionId
  }

  var book: PlanningBook {
    PlanningBook(
      scheduled: scheduled, prices: prices, expected: expected, expectedLinks: expectedLinks,
      reconciliations: reconciliations, debtEntries: debtEntries, settings: settings,
      reconciledBalances: counts)
  }

  var ledger: Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, categories: Self.categories, events: events, paymentMethods: accounts,
        debts: debts, goals: goals, planning: book, transfers: transfers, accountGroups: groups),
      calendar: .utc)
  }

  func snapshot(
    today: DateOnly = CashFx.today, now: Date = CashFx.now
  ) -> PlanningSnapshot {
    PlanningSnapshot.build(ledger: ledger, today: today, now: now, rubPerUnit: rubPerUnit)
  }

  /// The plan through `until`, built the way the snapshot builds it.
  func plan(until: String, today: DateOnly = CashFx.today) -> CashPlan {
    let ledger = ledger
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: today, now: CashFx.now, rubPerUnit: rubPerUnit)
    return CashPlan.build(
      ledger: ledger, book: ledger.dataset.planning, accounts: planning.accounts, today: today,
      until: Self.day(until), rubPerUnit: rubPerUnit, matches: planning.matches,
      goals: planning.goals, debts: planning.debts, events: planning.budgetedEvents,
      reserveGoalPlan: settings.reserveGoalPlan,
      subtractGoalSavings: settings.reconcileIncludesGoalSavings)
  }

  static func payment(
    _ number: Int, _ name: String, _ amount: String, day: Int, next: String,
    currency: CurrencyCode = .rub, account: UUID? = nil, category: UUID? = CashFx.housing,
    end: String? = nil
  ) -> ScheduledPayment {
    ScheduledPayment(
      id: id(number), name: name, amountE4: money(amount), currency: currency,
      categoryId: category, paymentMethodId: account, day: day, nextDate: self.day(next),
      endDate: end.map(self.day))
  }
}

@Suite("The plan of the free sum: what has to leave the accounts by D")
struct CashPlanTests {
  typealias Fx = CashFx

  // MARK: - Scheduled payments

  /// Main was counted at 14:00 on 10 September. A due on or before that day is inside the
  /// count, paid or not: the rent of the 5th and the phone of the 10th are settled; the
  /// internet of the 25th is still ahead. The card was never counted: its due of 20 August is
  /// last month's and stays out, the one of 20 September is due.
  @Test func duesAfterTheLatestCountOfTheirAccount() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    fx.scheduled = [
      Fx.payment(1, "Rent", "30000", day: 5, next: "2026-09-05"),
      Fx.payment(2, "Phone", "700", day: 10, next: "2026-09-10"),
      Fx.payment(3, "Internet", "1000", day: 25, next: "2026-09-25"),
      Fx.payment(4, "Gym", "2000", day: 20, next: "2026-08-20", account: Fx.card),
    ]
    #expect(fx.plan(until: "2026-09-30").scheduled == Fx.money("3000"))
    // Through October: the rent, the phone, the internet and the gym come once more.
    #expect(fx.plan(until: "2026-10-31").scheduled == Fx.money("36700"))
  }

  /// Counted on 1 August: a due of 15 August nobody paid is still money to leave, whatever
  /// month it was.
  @Test func anOverdueDueAfterTheCountStaysWhateverItsMonth() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-08-01", 9))
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 15, next: "2026-08-15")]
    #expect(fx.plan(until: "2026-09-30").scheduled == Fx.money("60000"))
  }

  /// Paid for somebody who gives it back, it still leaves the account in full; a one-off
  /// planned expense is due once; a dollar payment counts at today's rate, one in euros has no
  /// rate and is listed.
  @Test func inFullOnceAndAtTodaysRate() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    var shared = Fx.payment(1, "Music", "1000", day: 21, next: "2026-09-21")
    shared.reimbursable = true
    fx.scheduled = [
      shared,
      Fx.payment(2, "Sofa", "25000", day: 28, next: "2026-09-28", end: "2026-09-28"),
      Fx.payment(3, "Hosting", "10", day: 22, next: "2026-09-22", currency: .usd),
      Fx.payment(4, "Domain", "20", day: 23, next: "2026-09-23", currency: .eur),
    ]
    let plan = fx.plan(until: "2026-12-31")
    // Music every month through December (4 × 1 000), the sofa once, hosting 4 × 900.
    #expect(plan.scheduled == Fx.money("32600"))
    #expect(plan.withoutRate == [.eur])
  }

  /// A payment on an account of a group left out of the summary goes with its money.
  @Test func aPaymentOnAnAccountOutOfTheSummaryStaysOut() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.scheduled = [
      Fx.payment(
        1, "Phone", "5000", day: 25, next: "2026-09-25", currency: Fx.tenge,
        account: Fx.freedom)
    ]
    #expect(fx.plan(until: "2026-09-30").scheduled == .zero)
  }

  // MARK: - Debts

  /// 10 000 a month on the 25th with 15 000 left: through November that is three payments,
  /// but never more than the debt — 15 000.
  @Test func aDebtIsNeverSubtractedAboveItsBalance() {
    var fx = Fx()
    let loan = Debt(
      id: Fx.id(301), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: Fx.money("10000"),
      paymentDay: 25)
    fx.debts = [loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-01-10"), amountE4: Fx.money("15000"),
        kind: .adjustment)
    ]
    #expect(fx.plan(until: "2026-11-30").debts == Fx.money("15000"))
    #expect(fx.plan(until: "2026-10-31").debts == Fx.money("15000"))
    #expect(fx.plan(until: "2026-09-30").debts == Fx.money("10000"))
    // D before the payment day: nothing is due yet.
    #expect(fx.plan(until: "2026-09-20").debts == .zero)
  }

  /// Instalments count too; a payment made this month moves the next one to October, and an
  /// overdue payment of this month still leaves.
  @Test func instalmentsAndPaymentsMadeThisMonth() {
    var fx = Fx()
    let instalments = Debt(
      id: Fx.id(302), direction: .iOwe, type: .installment, name: "Phone in parts",
      monthlyPaymentE4: Fx.money("3000"), paymentDay: 5, paymentsAreExpenses: false,
      origin: .purchase)
    let loan = Debt(
      id: Fx.id(303), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: Fx.money("8000"),
      paymentDay: 10)
    fx.debts = [instalments, loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: instalments.id, date: Fx.day("2026-06-05"), amountE4: Fx.money("30000"),
        kind: .borrowed),
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-01-10"), amountE4: Fx.money("80000"),
        kind: .adjustment),
    ]
    // The loan was paid on the 10th.
    fx.add(.expense, "8000", at: Fx.at("2026-09-10", 12), debt: loan.id)
    // Instalments: the overdue 5 September and 5 October; the loan: 10 October.
    #expect(fx.plan(until: "2026-10-31").debts == Fx.money("14000"))
  }

  /// A phone bought in parts on 15 September, paid on the 5th: nothing was owed on 5
  /// September, so the first payment is 5 October.
  @Test func aDebtOwesNothingBeforeItStarted() {
    var fx = Fx()
    let instalments = Debt(
      id: Fx.id(304), direction: .iOwe, type: .installment, name: "Phone in parts",
      monthlyPaymentE4: Fx.money("3000"), paymentDay: 5, paymentsAreExpenses: false,
      origin: .purchase)
    fx.debts = [instalments]
    fx.debtEntries = [
      DebtEntry(
        debtId: instalments.id, date: Fx.day("2026-09-15"), amountE4: Fx.money("30000"),
        kind: .borrowed)
    ]
    #expect(fx.plan(until: "2026-09-30").debts == .zero)
    #expect(fx.plan(until: "2026-10-31").debts == Fx.money("3000"))
  }

  // MARK: - Goals

  /// A plan of 10 000 a month: the rest of this month's plan and a full plan for every later
  /// month by D; what is already saved is held back as well, so money put into the goal
  /// earlier is never free.
  @Test func goalSavingsAndTheRestOfThePlans() {
    var fx = Fx()
    fx.goals = [
      Goal(
        id: Fx.id(401), name: "Trip", targetE4: Fx.money("1000000"),
        monthlyPlanE4: Fx.money("10000"), subcategoryId: Fx.tripGoal)
    ]
    fx.add(.expense, "50000", at: Fx.at("2026-08-10", 12), category: Fx.tripGoal, goal: Fx.id(401))
    fx.add(.expense, "4000", at: Fx.at("2026-09-10", 12), category: Fx.tripGoal, goal: Fx.id(401))
    let month = fx.plan(until: "2026-09-30")
    #expect(month.goalSavings == Fx.money("54000"))
    #expect(month.goalPlans == Fx.money("6000"))
    let later = fx.plan(until: "2026-11-15")
    #expect(later.goalPlans == Fx.money("26000"))

    fx.settings.reconcileIncludesGoalSavings = false
    fx.settings.reserveGoalPlan = false
    let neither = fx.plan(until: "2026-11-15")
    #expect(neither.goalSavings == .zero)
    #expect(neither.goalPlans == .zero)
    #expect(!neither.subtractsGoalSavings)
    #expect(!neither.reservesGoalPlans)
  }

  /// The plans never ask more than the goal still needs; a dollar goal counts at today's rate.
  @Test func thePlansStopAtWhatTheGoalNeeds() {
    var fx = Fx()
    fx.goals = [
      Goal(
        id: Fx.id(402), name: "Bike", targetE4: Fx.money("100000"),
        monthlyPlanE4: Fx.money("30000"), subcategoryId: Fx.tripGoal),
      Goal(
        id: Fx.id(403), name: "Camera", targetE4: Fx.money("1000"),
        monthlyPlanE4: Fx.money("100"), currency: .usd),
    ]
    fx.add(.expense, "60000", at: Fx.at("2026-08-10", 12), category: Fx.tripGoal, goal: Fx.id(402))
    let plan = fx.plan(until: "2026-12-31")
    // Bike: 40 000 left of 30 000 × 4; camera: 100 $ × 4 = 36 000 ₽.
    #expect(plan.goalPlans == Fx.money("76000"))
  }

  // MARK: - Events

  /// Under way with 20 000 and 5 000 spent: 15 000 is held back; one that starts by D, its
  /// whole budget; one after D, without a budget or archived — nothing.
  @Test func whatIsLeftOfTheEventBudgets() {
    var fx = Fx()
    fx.events = [
      Event(
        id: Fx.id(501), name: "Trip", startDate: Fx.day("2026-09-15"),
        endDate: Fx.day("2026-09-25"), budgetE4: Fx.money("20000")),
      Event(
        id: Fx.id(502), name: "Birthday", startDate: Fx.day("2026-10-10"),
        endDate: Fx.day("2026-10-10"), budgetE4: Fx.money("8000")),
      Event(
        id: Fx.id(503), name: "New Year", startDate: Fx.day("2026-12-31"),
        endDate: Fx.day("2027-01-01"), budgetE4: Fx.money("30000")),
      Event(
        id: Fx.id(504), name: "Concert", startDate: Fx.day("2026-10-01"),
        endDate: Fx.day("2026-10-01")),
      Event(
        id: Fx.id(505), name: "Old", startDate: Fx.day("2026-10-02"),
        endDate: Fx.day("2026-10-02"), budgetE4: Fx.money("9000"), archived: true),
    ]
    fx.add(.expense, "5000", at: Fx.at("2026-09-16", 12), category: Fx.fun)
    fx.entries[fx.entries.count - 1].parts[0].eventId = Fx.id(501)
    #expect(fx.plan(until: "2026-09-30").events == Fx.money("15000"))
    #expect(fx.plan(until: "2026-10-31").events == Fx.money("23000"))
  }
}
