import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// A payment due soon, as the Overview card «Payments in 7 days» lists it: an unpaid due
/// date of a scheduled payment, or the next monthly payment of a debt I owe.
public struct UpcomingPayment: Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable, CaseIterable {
    case scheduled
    case debt
  }

  public var kind: Kind
  /// The scheduled payment or the debt.
  public var id: UUID
  /// The name of the payment or of the debt, as the owner typed it.
  public var name: String
  public var due: DateOnly
  public var currency: CurrencyCode
  /// What is charged, in `currency`: the price on the due date, or the monthly payment.
  public var amount: AmountE4
  /// The due date is before today and nothing paid it.
  public var isOverdue: Bool

  public init(
    kind: Kind, id: UUID, name: String, due: DateOnly, currency: CurrencyCode, amount: AmountE4,
    isOverdue: Bool
  ) {
    self.kind = kind
    self.id = id
    self.name = name
    self.due = due
    self.currency = currency
    self.amount = amount
    self.isOverdue = isOverdue
  }
}

/// Everything the Planning and Debts sections, the planning cards of Overview and the
/// reminders show, counted once from one ledger. The data step rebuilds it after every write,
/// off the main thread, so every figure comes from a rule of its own type — this one only
/// wires them together and adds the few sums that belong to no single rule.
///
/// All amounts are rubles unless a field says otherwise; a foreign amount is converted at
/// `rubPerUnit`, the last rate the caller knows, or left out and listed by the rule that met
/// it — never guessed.
public struct PlanningSnapshot: Hashable, Sendable {
  /// Days after today the upcoming payments reach, today + 7 included.
  public static let upcomingDays = 7
  /// Due dates of one scheduled payment the upcoming list takes at most: a weekly payment
  /// left unpaid for months must not push everything else off the card.
  public static let upcomingPerPayment = 12

  public var today: DateOnly
  /// The moment the snapshot was built for.
  public var now: Date
  public var rubPerUnit: [CurrencyCode: Decimal]
  /// The planning records of the dataset (`ledger.dataset.planning`).
  public var book: PlanningBook

  /// Every active payment with a due date, the soonest first, then by name
  /// (`ScheduledRules.statuses`).
  public var scheduled: [ScheduledStatus]
  /// What each payment method needs this month, by currency (`Funding.month`).
  public var funding: [FundingLine]
  public var candidates: [SubscriptionCandidate]
  /// The expectations that are not closed (`ExpectedIncomeRules.statuses`).
  public var expected: [ExpectedIncomeStatus]
  /// The income of this month, received and still expected through its end
  /// (`IncomeEstimate.month`).
  public var income: MonthIncomeEstimate
  /// What is still to be paid through the end of the month (`PlannedMonth.build`).
  public var planned: PlannedMonth
  /// Every limit of the book for this month, in the book's order.
  public var limits: [LimitLine]
  /// The goals that are not archived; `coveredByCanSave` is unknown here, since «can save»
  /// needs the forecast of the month.
  public var goals: [GoalStatus]
  public var events: EventsPlanning
  /// What the goals' monthly plans still ask this month (`FreeToSpend.goalReserve`).
  public var goalReserve: AmountE4
  public var debts: DebtsOverview
  /// Every reminder that is not put off, the most pressing first (`ReminderRules.build`).
  public var reminders: [Reminder]
  public var lastReconciliation: Reconciliation?
  /// Time to reconcile: never reconciled, or the last one is older than the setting.
  public var reconciliationDue: Bool
  /// Unpaid due dates of scheduled payments and next payments of debts I owe, from any
  /// overdue one through today + `upcomingDays`: the overdue ones first, then by date.
  public var upcoming: [UpcomingPayment]

  /// My expenses from the 1st through today, goal contributions included: money that left.
  public var spentThisMonth: AmountE4
  /// The same without goal contributions: they are the saving, not spending.
  public var spentWithoutGoals: AmountE4
  /// Net goal contributions from the 1st through today (`GoalRules.netContributions`).
  public var goalsNetThisMonth: AmountE4
  /// Σ over the running subscriptions of what the next charge comes to per month and per
  /// year, in rubles; a subscription in a currency without a rate is left out.
  public var subscriptionsMonthly: AmountE4
  public var subscriptionsYearly: AmountE4
  /// What people give back for the scheduled payments still due this month — the line of
  /// «free to spend» that is shown and never subtracted.
  public var forOthersThisMonth: AmountE4

  public init(
    today: DateOnly, now: Date, rubPerUnit: [CurrencyCode: Decimal], book: PlanningBook,
    scheduled: [ScheduledStatus], funding: [FundingLine], candidates: [SubscriptionCandidate],
    expected: [ExpectedIncomeStatus], income: MonthIncomeEstimate, planned: PlannedMonth,
    limits: [LimitLine], goals: [GoalStatus], events: EventsPlanning, goalReserve: AmountE4,
    debts: DebtsOverview, reminders: [Reminder], lastReconciliation: Reconciliation?,
    reconciliationDue: Bool, upcoming: [UpcomingPayment], spentThisMonth: AmountE4,
    spentWithoutGoals: AmountE4, goalsNetThisMonth: AmountE4, subscriptionsMonthly: AmountE4,
    subscriptionsYearly: AmountE4, forOthersThisMonth: AmountE4
  ) {
    self.today = today
    self.now = now
    self.rubPerUnit = rubPerUnit
    self.book = book
    self.scheduled = scheduled
    self.funding = funding
    self.candidates = candidates
    self.expected = expected
    self.income = income
    self.planned = planned
    self.limits = limits
    self.goals = goals
    self.events = events
    self.goalReserve = goalReserve
    self.debts = debts
    self.reminders = reminders
    self.lastReconciliation = lastReconciliation
    self.reconciliationDue = reconciliationDue
    self.upcoming = upcoming
    self.spentThisMonth = spentThisMonth
    self.spentWithoutGoals = spentWithoutGoals
    self.goalsNetThisMonth = goalsNetThisMonth
    self.subscriptionsMonthly = subscriptionsMonthly
    self.subscriptionsYearly = subscriptionsYearly
    self.forOthersThisMonth = forOthersThisMonth
  }

  /// Nothing known yet: empty lists, zeros and no reminder — what a screen holds before the
  /// first read, not the plan of an empty book (`build` gives that one).
  public static let empty: PlanningSnapshot = {
    let day = DateOnly(year: 1970, month: 1, day: 1)
    return PlanningSnapshot(
      today: day, now: Date(timeIntervalSince1970: 0), rubPerUnit: [:], book: .empty,
      scheduled: [], funding: [], candidates: [], expected: [],
      income: MonthIncomeEstimate(
        month: day.monthKey, received: .zero, expectedRemaining: .zero, median3: nil,
        monthsInMedian: 0, value: nil, source: .receivedOnly, lowData: true),
      planned: PlannedMonth(
        items: [], scheduled: .zero, debts: .zero, goals: .zero, withoutRate: [],
        byCategory: [:], byForWhom: [:]),
      limits: [], goals: [], events: .empty, goalReserve: .zero,
      debts: DebtsOverview(
        iOwe: [], owedToMe: [], closed: [], totalIOweRub: .zero, totalOwedToMeRub: .zero,
        monthlyPaymentsRub: .zero, withoutRate: []),
      reminders: [], lastReconciliation: nil, reconciliationDue: false, upcoming: [],
      spentThisMonth: .zero, spentWithoutGoals: .zero, goalsNetThisMonth: .zero,
      subscriptionsMonthly: .zero, subscriptionsYearly: .zero, forOthersThisMonth: .zero)
  }()

  // MARK: - Building

  /// The snapshot for `today`. Each rule reads the ledger in one pass or over the days of
  /// the month (`Ledger.rows(in:)`); nothing here walks the ledger once per payment, debt or
  /// goal, so the cost grows with the operations, not with their product.
  ///
  /// The limits take as planned the scheduled payments alone: a limit never counts a debt
  /// payment (filed under the system Loans) or a goal contribution as spent, so it must not
  /// count them as still to be spent either — a «for me» limit would otherwise be pushed
  /// towards «over» by the loan and the goal plans.
  public static func build(
    ledger: Ledger, today: DateOnly, now: Date, rubPerUnit: [CurrencyCode: Decimal]
  ) -> PlanningSnapshot {
    let book = ledger.dataset.planning
    let month = today.monthKey
    let toDate = DayRange(month.firstDay, today)

    let scheduled = ScheduledRules.statuses(
      book: book, ledger: ledger, today: today, rubPerUnit: rubPerUnit)
    let expected = ExpectedIncomeRules.statuses(
      book: book, ledger: ledger, today: today, rubPerUnit: rubPerUnit)
    let planned = PlannedMonth.build(
      ledger: ledger, book: book, today: today, rubPerUnit: rubPerUnit)
    let limitPlan = scheduledShares(of: planned)
    let debts = DebtsOverview.build(
      ledger: ledger, book: book, today: today, rubPerUnit: rubPerUnit)
    let last = ReconciliationRules.latest(book.reconciliations)
    let subscriptions = subscriptionTotals(scheduled, rubPerUnit: rubPerUnit)

    // My expenses of the month to date in one pass; goal contributions set apart the way
    // `CanSaveInputs(ledger:)` sets them apart.
    var spent = AmountE4.zero
    var spentOnGoals = AmountE4.zero
    for row in ledger.rows(in: toDate) {
      spent += row.contribution
      if row.isGoalContribution { spentOnGoals += row.contribution }
    }

    return PlanningSnapshot(
      today: today, now: now, rubPerUnit: rubPerUnit, book: book, scheduled: scheduled,
      funding: Funding.month(month, book: book, ledger: ledger, today: today),
      candidates: SubscriptionCandidates.find(ledger: ledger, book: book, today: today),
      expected: expected,
      income: IncomeEstimate.month(ledger: ledger, statuses: expected, today: today),
      planned: planned,
      limits: LimitRules.lines(
        book: book, ledger: ledger, today: today, plannedByCategory: limitPlan.byCategory,
        plannedByForWhom: limitPlan.byForWhom),
      goals: GoalRules.statuses(goals: ledger.dataset.goals, ledger: ledger, today: today),
      events: EventPlanning.build(ledger: ledger, today: today),
      goalReserve: FreeToSpend.goalReserve(
        goals: ledger.dataset.goals, ledger: ledger, today: today),
      debts: debts,
      reminders: ReminderRules.build(
        book: book, debts: ledger.dataset.debts, ledger: ledger, today: today),
      lastReconciliation: last,
      reconciliationDue: ReconciliationRules.isDue(
        last: last, today: today, everyDays: book.settings.reconcileEveryDays),
      upcoming: upcoming(scheduled: scheduled, debts: debts, ledger: ledger, today: today),
      spentThisMonth: spent,
      spentWithoutGoals: spent - spentOnGoals,
      goalsNetThisMonth: GoalRules.netContributions(ledger: ledger, in: toDate),
      subscriptionsMonthly: subscriptions.monthly,
      subscriptionsYearly: subscriptions.yearly,
      forOthersThisMonth: expectedReturns(of: planned, book: book, rubPerUnit: rubPerUnit))
  }

  // MARK: - Free to spend

  /// «Free to spend» through the end of the month, the goal reserve as the setting has it.
  public var freeToSpend: FreeToSpend {
    monthFreeToSpend(reserve: book.settings.reserveGoalPlan)
  }

  /// «Free to spend» through `until`, clipped to [today, end of the month]:
  ///
  /// * income received this month, and what the expectations due from the 1st through
  ///   `until` still wait for — an expectation of this month that is late still counts, as
  ///   a late payment still counts on the other side (`IncomeEstimate.month(until:)`);
  /// * my expenses since the 1st, goal contributions included;
  /// * my share of the scheduled payments and the payments on debts that are expenses still
  ///   due through `until` (`PlannedMonth.build(until:)`);
  /// * the goal reserve when `reserve` is on;
  /// * what people give back for the scheduled payments due through `until`, listed apart.
  ///
  /// Through the end of the month the figures of the snapshot are used as they are; an
  /// earlier day counts the payments and the expectations of its shorter window again.
  public func freeToSpend(until: DateOnly, reserve: Bool, ledger: Ledger) -> FreeToSpend {
    let end = FreeToSpend.window(today: today, until: until).end
    guard end < today.monthKey.lastDay else { return monthFreeToSpend(reserve: reserve) }
    let window = PlannedMonth.build(
      ledger: ledger, book: book, today: today, until: end, rubPerUnit: rubPerUnit)
    let expectedUntil = IncomeEstimate.month(
      ledger: ledger, statuses: expected, today: today, until: end)
    return FreeToSpend(
      FreeToSpendInputs(
        today: today, until: end, incomeReceived: income.received,
        expectedIncome: expectedUntil.expectedRemaining, spentThisMonth: spentThisMonth,
        plannedScheduled: window.scheduled,
        plannedDebts: window.debts + window.debtsDueByToday,
        goalReserve: goalReserve, reserveEnabled: reserve,
        forOthersUntil: Self.expectedReturns(of: window, book: book, rubPerUnit: rubPerUnit)))
  }

  private func monthFreeToSpend(reserve: Bool) -> FreeToSpend {
    FreeToSpend(
      FreeToSpendInputs(
        today: today, until: nil, incomeReceived: income.received,
        expectedIncome: income.expectedRemaining, spentThisMonth: spentThisMonth,
        plannedScheduled: planned.scheduled,
        plannedDebts: planned.debts + planned.debtsDueByToday,
        goalReserve: goalReserve, reserveEnabled: reserve, forOthersUntil: forOthersThisMonth))
  }

  // MARK: - Can save

  /// «Can save this month» with the remainder the forecast step gives: the income of the
  /// month, my expenses without goal contributions, the scheduled and debt payments still
  /// due (my share), and the net contributions of the month as what is saved already.
  public func canSave(remainder: MonthForecast.Remainder) -> CanSave {
    CanSave(
      CanSaveInputs(
        income: income, spentWithoutGoals: spentWithoutGoals,
        plannedStillDue: planned.scheduled + planned.debts + planned.debtsDueByToday,
        remainder: remainder,
        alreadySaved: goalsNetThisMonth))
  }

  // MARK: - Pieces

  /// My share still due of the scheduled payments alone, by the category each is filed
  /// under and by «for whom» — what the limits take as planned.
  private static func scheduledShares(
    of planned: PlannedMonth
  ) -> (byCategory: [UUID: AmountE4], byForWhom: [ForWhom: AmountE4]) {
    var byCategory: [UUID: AmountE4] = [:]
    var byForWhom: [ForWhom: AmountE4] = [:]
    for item in planned.items where item.kind == .scheduled {
      guard let share = item.myShareRub, !share.isZero else { continue }
      byForWhom[item.forWhom, default: .zero] += share
      if let category = item.categoryId { byCategory[category, default: .zero] += share }
    }
    return (byCategory, byForWhom)
  }

  /// What the people the scheduled payments of `planned` are for give back, in rubles
  /// (`ScheduledRules.share`). A payment without a rate adds nothing: it is listed as
  /// without a rate by the planned month already.
  private static func expectedReturns(
    of planned: PlannedMonth, book: PlanningBook, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4 {
    let reimbursable = Dictionary(
      book.scheduled.lazy.filter(\.reimbursable).map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
    guard !reimbursable.isEmpty else { return .zero }
    var total = AmountE4.zero
    for item in planned.items where item.kind == .scheduled {
      guard let payment = reimbursable[item.id],
        let share = ScheduledRules.share(of: payment, amount: item.amount, rubPerUnit: rubPerUnit)
      else { continue }
      total += share.expectedReturnRub
    }
    return total
  }

  /// Σ of the monthly and yearly equivalents of the next charge of every running
  /// subscription, the charge converted to rubles first (`SubscriptionMath`).
  private static func subscriptionTotals(
    _ scheduled: [ScheduledStatus], rubPerUnit: [CurrencyCode: Decimal]
  ) -> (monthly: AmountE4, yearly: AmountE4) {
    var monthly = AmountE4.zero
    var yearly = AmountE4.zero
    for status in scheduled where status.payment.kind == .subscription {
      guard
        let charge = SubscriptionMath.rubles(
          status.amountNext, in: status.payment.currency, rubPerUnit: rubPerUnit)
      else { continue }
      let rule = RecurrenceRule(payment: status.payment)
      monthly += SubscriptionMath.monthlyEquivalent(charge, rule: rule)
      yearly += SubscriptionMath.yearlyEquivalent(charge, rule: rule)
    }
    return (monthly, yearly)
  }

  /// The payments of the Overview card.
  ///
  /// * Scheduled — every due date from `next_date` through today + `upcomingDays` that no
  ///   operation paid (`sched:<payment>:<due>`), at most `upcomingPerPayment` of one
  ///   payment, at the price on the date, in the currency of the payment. The dates before
  ///   today are overdue.
  /// * Debts — the next payment of every open debt I owe that has a monthly payment
  ///   (`DebtLine.nextPayment`): this month's day while this month is unpaid, overdue once
  ///   it has passed; next month's once this month is paid, unless next month is paid ahead
  ///   too — the rule of the reminders. A debt without a monthly payment has no amount to
  ///   show and stays on the Debts screen.
  private static func upcoming(
    scheduled: [ScheduledStatus], debts: DebtsOverview, ledger: Ledger, today: DateOnly
  ) -> [UpcomingPayment] {
    let horizon = today.adding(days: upcomingDays)
    let prices = ledger.dataset.planning.prices
    var result: [UpcomingPayment] = []

    let soon = scheduled.filter { $0.nextDue <= horizon }
    if !soon.isEmpty {
      // «Mark as paid» moves `next_date` on; a due date paid while it did not stays paid.
      var paid: [UUID: Set<DateOnly>] = [:]
      for row in ledger.rows where row.isFirstPart {
        if case .scheduled(let paymentId, let due) = row.link {
          paid[paymentId, default: []].insert(due)
        }
      }
      for status in soon {
        let payment = status.payment
        let dates = Recurrence.occurrences(
          from: status.nextDue, through: horizon, rule: RecurrenceRule(payment: payment),
          end: payment.endDate, limit: upcomingPerPayment)
        for date in dates where paid[payment.id]?.contains(date) != true {
          result.append(
            UpcomingPayment(
              kind: .scheduled, id: payment.id, name: payment.name, due: date,
              currency: payment.currency,
              amount: SubscriptionMath.price(of: payment, on: date, prices: prices),
              isOverdue: date < today))
        }
      }
    }

    let nextMonth = today.monthKey.next
    var paidNextMonth: Set<UUID>?
    for line in debts.iOwe {
      guard let due = line.nextPayment, due <= horizon,
        let amount = line.debt.monthlyPaymentE4, amount.raw > 0
      else { continue }
      if line.paidThisMonth {
        let byOperation =
          paidNextMonth
          ?? DebtSchedule.debtsPaid(
            in: nextMonth, ledger: ledger, journal: ledger.dataset.planning.debtEntries)
        paidNextMonth = byOperation
        if DebtSchedule.isPaid(
          line.debt.id, in: nextMonth, paidByOperation: byOperation, journal: line.entries)
        {
          continue
        }
      }
      result.append(
        UpcomingPayment(
          kind: .debt, id: line.debt.id, name: line.debt.name, due: due,
          currency: line.debt.currency, amount: amount, isOverdue: due < today))
    }

    return result.sorted { left, right in
      if left.isOverdue != right.isOverdue { return left.isOverdue }
      if left.due != right.due { return left.due < right.due }
      if left.kind != right.kind { return left.kind == .scheduled }
      if left.name != right.name { return left.name < right.name }
      return left.id.uuidString < right.id.uuidString
    }
  }
}
