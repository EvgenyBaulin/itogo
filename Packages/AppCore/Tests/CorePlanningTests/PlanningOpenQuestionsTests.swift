import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// Rules where a second reading is just as reasonable as the one the code follows. Each test
/// pins what the code does today with the numbers of a worked example, so a change of the rule
/// changes one test on purpose, not a figure by accident.
@Suite("Planning rules with an open question: what they do today")
struct PlanningOpenQuestionsTests {
  typealias Fx = CashFx

  /// Rent of 30 000 due on the 5th, the account counted on the 10th, the rent neither marked
  /// paid nor matched by any operation. The count holds the rent's money, paid or not, so the
  /// grey line does not take it again — while the reminders and the 7-day card still call it
  /// overdue.
  @Test func aDueBeforeTheCountIsSettledWhileTheRemindersCallItOverdue() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 9))
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 5, next: "2026-09-05")]
    let snapshot = fx.snapshot()
    #expect(snapshot.freeMoney.plan.scheduled == .zero)
    #expect(snapshot.freeMoney.grey == Fx.money("100000"))
    #expect(snapshot.reminders.filter { $0.kind == .payment }.map(\.urgency) == [.overdue])
    #expect(snapshot.upcoming.filter { $0.kind == .scheduled }.map(\.isOverdue) == [true])
    #expect(snapshot.scheduled.first?.isOverdue == true)
  }

  /// A loan of 8 000 due on the 5th, the account counted on the 10th, the payment not written
  /// anywhere: unlike a scheduled payment, a debt has no account and no count to be inside of,
  /// so the grey line takes the 8 000.
  @Test func aDebtDueBeforeTheCountIsStillSubtracted() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 9))
    let loan = Debt(
      id: Fx.id(301), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: Fx.money("8000"), paymentDay: 5)
    fx.debts = [loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-01-05"), amountE4: Fx.money("80000"),
        kind: .borrowed)
    ]
    let free = fx.snapshot().freeMoney
    #expect(free.plan.debts == Fx.money("8000"))
    #expect(free.grey == Fx.money("92000"))
  }

  /// 100 000 on the account, a plan of 10 000 a month, D the end of October: 80 000 free.
  /// Putting 20 000 into the goal now — this month's plan and next month's — leaves 70 000:
  /// the next month's plan is held back in full all the same, only the goal's target caps it.
  @Test func aContributionAheadOfThePlanLowersTheGreyLine() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.goals = [
      Goal(
        id: Fx.id(401), name: "Trip", targetE4: Fx.money("1000000"),
        monthlyPlanE4: Fx.money("10000"), subcategoryId: Fx.tripGoal)
    ]
    let october = Fx.day("2026-10-31")
    #expect(fx.snapshot().freeMoney(until: october, ledger: fx.ledger).grey == Fx.money("80000"))
    fx.add(.expense, "20000", at: Fx.at("2026-09-19", 10), category: Fx.tripGoal, goal: Fx.id(401))
    #expect(fx.snapshot().freeMoney(until: october, ledger: fx.ledger).grey == Fx.money("70000"))
  }

  /// A dinner of 6 000 on a trip with a budget of 20 000, 4 000 of it paid for a friend who
  /// gives it back: the budget's rest held back is 18 000 — the event counts my spending, 2 000
  /// — though 6 000 left the account. Until the friend pays, the grey line is 4 000 lower than
  /// «budget − money spent» would make it.
  @Test func anEventBudgetCountsMySpendingNotTheMoney() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.events = [
      Event(
        id: Fx.id(501), name: "Trip", startDate: Fx.day("2026-09-15"),
        endDate: Fx.day("2026-09-25"), budgetE4: Fx.money("20000"))
    ]
    let dinner = fx.add(.expense, "6000", at: Fx.at("2026-09-16", 20), category: Fx.fun)
    let index = fx.entries.firstIndex { $0.id == dinner } ?? 0
    let transaction = fx.entries[index].transaction
    fx.entries[index].parts = [
      TransactionPart(
        id: Fx.id(9_001), transactionId: dinner, categoryId: Fx.fun, quality: .neutral,
        qualitySource: .category, amountE4: Fx.money("2000"), amountRubE4: Fx.money("2000"),
        eventId: Fx.id(501)),
      TransactionPart(
        id: Fx.id(9_002), transactionId: dinner, categoryId: Fx.fun, quality: .neutral,
        qualitySource: .category, amountE4: Fx.money("4000"), amountRubE4: Fx.money("4000"),
        forWhom: .friends, reimbursable: true, debtorPersonId: Fx.id(40),
        reimbursementStatus: .expected, eventId: Fx.id(501)),
    ]
    #expect(transaction.amountE4 == Fx.money("6000"))
    let free = fx.snapshot().freeMoney
    #expect(free.main == Fx.money("94000"))
    #expect(free.plan.events == Fx.money("18000"))
    #expect(free.grey == Fx.money("76000"))
  }

  /// A cleaning of 2 000 every Monday; 2 000 spent on Thursday the 17th pays Monday the 14th.
  /// «Это другое» on that pair: the same operation then pays Monday the 21st, four days
  /// ahead — a dismissal is about one due date, not about the payment.
  @Test func aDismissedOperationMayPayTheNextWeek() {
    var fx = Fx()
    let cleaning = ScheduledPayment(
      id: Fx.id(1), name: "Cleaning", amountE4: Fx.money("2000"), categoryId: Fx.housing,
      freq: .weekly, day: 1, nextDate: Fx.day("2026-09-14"))
    fx.scheduled = [cleaning]
    let spent = fx.add(.expense, "2000", at: Fx.at("2026-09-17", 10), category: Fx.housing)
    let first = ScheduledMatching.matches(
      book: fx.book, ledger: fx.ledger, today: Fx.today, rejections: [])
    #expect(first.operation(for: cleaning.id, Fx.day("2026-09-14")) == spent)
    let dismissed = ScheduledMatching.matches(
      book: fx.book, ledger: fx.ledger, today: Fx.today,
      rejections: [
        ScheduledMatching.rejectionKey(
          operation: spent, payment: cleaning.id, due: Fx.day("2026-09-14"))
      ])
    #expect(dismissed.operation(for: cleaning.id, Fx.day("2026-09-14")) == nil)
    #expect(dismissed.operation(for: cleaning.id, Fx.day("2026-09-21")) == spent)
  }

  /// A «subscription» saved as «Разово» for 12 000 — a licence bought once: one charge, so it
  /// is left out of what the subscriptions cost a month and a year, and its own line has no
  /// figure per month or per year. Whether a one-off belongs among the subscriptions at all is
  /// the open part.
  @Test func aOneOffSubscriptionIsLeftOutOfTheSubscriptionTotals() {
    var fx = Fx()
    var license = Fx.payment(1, "License", "12000", day: 25, next: "2026-09-25", end: "2026-09-25")
    license.kind = .subscription
    fx.scheduled = [license]
    let snapshot = fx.snapshot()
    #expect(snapshot.subscriptionsMonthly == .zero)
    #expect(snapshot.subscriptionsYearly == .zero)
    #expect(snapshot.scheduled.first?.monthly == .zero)
    #expect(snapshot.scheduled.first?.yearly == .zero)
    #expect(snapshot.scheduled.first?.amountNext == Fx.money("12000"))
  }

  /// A dollar goal fed from a ruble account: 9 000 ₽ at 90 is 100 $. At 100 ₽ a dollar today
  /// the grey line holds back 10 000 ₽ of savings, while the account keeps the 9 000 ₽ that
  /// were put aside: the rate alone took 1 000 ₽ off «можно тратить».
  @Test func dollarSavingsAreHeldBackAtTodaysRate() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.goals = [
      Goal(
        id: Fx.id(402), name: "Camera", targetE4: Fx.money("1000"),
        subcategoryId: Fx.tripGoal, currency: .usd)
    ]
    fx.add(.expense, "9000", at: Fx.at("2026-09-05", 12), category: Fx.tripGoal, goal: Fx.id(402))
    let rates = DayRates(series: [.usd: [DayRate(day: Fx.day("2026-09-05"), perUnit: 90)]])
    let snapshot = PlanningSnapshot.build(
      ledger: fx.ledger, today: Fx.today, now: Fx.now, rubPerUnit: [.usd: 100], dayRates: rates)
    #expect(snapshot.goals.first?.saved == Fx.money("100"))
    #expect(snapshot.freeMoney.main == Fx.money("100000"))
    #expect(snapshot.freeMoney.plan.goalSavings == Fx.money("10000"))
    #expect(snapshot.freeMoney.grey == Fx.money("90000"))
  }

  /// A trip with a budget of 50 000 and the hotel of 20 000 planned as a one-off payment
  /// inside it: until the hotel is paid, both come off the grey line — 70 000 — though the
  /// owner may have counted the hotel into the budget.
  @Test func aPlannedPaymentInsideAnEventBudgetComesOffTwice() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.events = [
      Event(
        id: Fx.id(501), name: "Trip", startDate: Fx.day("2026-09-25"),
        endDate: Fx.day("2026-09-29"), budgetE4: Fx.money("50000"))
    ]
    fx.scheduled = [
      Fx.payment(1, "Hotel", "20000", day: 25, next: "2026-09-25", end: "2026-09-25")
    ]
    let free = fx.snapshot().freeMoney
    #expect(free.plan.scheduled == Fx.money("20000"))
    #expect(free.plan.events == Fx.money("50000"))
    #expect(free.grey == Fx.money("30000"))
  }

  /// A goal fed from the Kazakhstan account, which is out of the summary: 100 000 ₸ (20 000 ₽)
  /// put into it come off the grey line of the summary's money, which never held them. The
  /// switch «Деньги целей лежат на счетах в сводке» is one for every goal.
  @Test func savingsOfAGoalFedFromAGroupLeftOutComeOffTheSummary() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.count([(Fx.freedom, Fx.tenge, "500000")], at: Fx.at("2026-09-01", 9))
    fx.goals = [
      Goal(
        id: Fx.id(403), name: "Almaty flat", targetE4: Fx.money("10000000"),
        subcategoryId: Fx.tripGoal, currency: Fx.tenge)
    ]
    fx.add(
      .expense, "100000", at: Fx.at("2026-09-10", 12), currency: Fx.tenge, account: Fx.freedom,
      category: Fx.tripGoal, goal: Fx.id(403))
    let free = fx.snapshot().freeMoney
    #expect(free.main == Fx.money("100000"))
    #expect(free.plan.goalSavings == Fx.money("20000"))
    #expect(free.grey == Fx.money("80000"))
    #expect(free.excluded.first?.totalRub == Fx.money("100000"))
  }
}

extension PlanningOpenQuestionsTests {
  /// A card archived with a payment still on it: its money is in no total — the money now is
  /// Main's 100 000 — yet its payment of 2 000 on the 25th comes off the grey line, as the
  /// money has to leave from somewhere in the summary.
  @Test func aPaymentOnAnArchivedAccountComesOffTheSummary() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    let oldCard = Fx.id(9)
    fx.accounts.append(PaymentMethod(id: oldCard, name: "Old card", currency: .rub, archived: true))
    fx.count([(Fx.main, .rub, "100000"), (oldCard, .rub, "5000")], at: Fx.at("2026-09-01", 9))
    fx.scheduled = [Fx.payment(1, "Gym", "2000", day: 25, next: "2026-09-25", account: oldCard)]
    let free = fx.snapshot().freeMoney
    #expect(free.main == Fx.money("100000"))
    #expect(free.plan.scheduled == Fx.money("2000"))
    #expect(free.grey == Fx.money("98000"))
  }

  /// A loan of 8 000 on the 5th, paid for September on 5 September and again on 28 September
  /// «for October». A payment is its month's: on 2 October the 5th is still due and reminded,
  /// the free sum through October holds 8 000 back, and on the 6th it is overdue.
  @Test func aPaymentAheadInTheMonthBeforeIsThatMonths() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    let loan = Debt(
      id: Fx.id(306), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: Fx.money("8000"), paymentDay: 5)
    fx.debts = [loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-01-05"), amountE4: Fx.money("80000"),
        kind: .borrowed)
    ]
    for day in ["2026-09-05", "2026-09-28"] {
      fx.add(.expense, "8000", at: Fx.at(day, 12), category: Fx.fun, debt: loan.id)
    }
    let october = fx.snapshot(today: Fx.day("2026-10-02"), now: Fx.at("2026-10-02", 12))
    #expect(october.debts.iOwe.first?.nextPayment == Fx.day("2026-10-05"))
    #expect(
      october.reminders.filter { $0.kind == .debtPayment }.map(\.due) == [Fx.day("2026-10-05")])
    #expect(fx.plan(until: "2026-10-31", today: Fx.day("2026-10-02")).debts == Fx.money("8000"))
    let late = fx.snapshot(today: Fx.day("2026-10-06"), now: Fx.at("2026-10-06", 12))
    #expect(late.upcoming.filter { $0.kind == .debt }.map(\.isOverdue) == [true])
  }
}
