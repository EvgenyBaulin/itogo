import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The money that has to leave the accounts in the summary from today through a day D, in
/// rubles at today's rates: what the grey line of the free sum takes from the money now
/// (`FreeMoney`). Money, not spending: a payment for somebody else counts in full — it leaves
/// the account whoever gives it back later —, and money put into a goal stays on the account,
/// so it is held back here rather than counted as gone.
///
/// * **Scheduled** — every unpaid due date `d` of every active scheduled payment with
///   `next_date ≤ d ≤ D`, one-off ones included and overdue ones of any month too, at the price
///   on `d`, in full. A due date on or before the day of the latest count of the payment's
///   balance is settled: that count already holds its money, paid or not. The balance is the
///   payment's account — the main one when it names none — in the payment's currency when the
///   account holds it, otherwise in the account's main currency; a balance never counted counts
///   from the 1st of this month. A due date paid by a link or by a matching ordinary operation
///   (`ScheduledMatches`) is not due. Payments on an account of a group left out of the summary
///   are left out with its money.
/// * **Debts** — every open debt I owe with a monthly payment and a payment day, instalments
///   included: this month's payment while this month has none (an overdue one included) and
///   one for every later month through D, never more in all than the debt's balance, in the
///   debt's currency. A payment day before the earliest day of the debt's journal is not due:
///   the debt did not exist yet. Debts have no account: they come off the money in the
///   summary.
/// * **Goal savings** — with `subtractGoalSavings` (the setting «Деньги целей лежат на счетах в
///   сводке», on by default): what is saved in every live goal. That money is on the accounts
///   but is not free, so a contribution changes neither the money nor the grey line.
/// * **Goal plans** — with `reserveGoalPlan`: for every live goal with a monthly plan, the
///   rest of this month's plan, max(0, plan − contributions this month), plus a full plan for
///   every later month whose 1st is by D, never more than the goal still needs.
/// * **Events** — every live event with a budget that is under way today or starts after today
///   and by D: what is left of its budget, max(0, budget − spent).
///
/// A foreign amount without a rate today is left out and its currency listed in
/// `withoutRate`, never guessed.
public struct CashPlan: Hashable, Sendable {
  public var scheduled: AmountE4
  public var debts: AmountE4
  /// Zero when the goal savings are not subtracted (`subtractsGoalSavings`).
  public var goalSavings: AmountE4
  /// Zero when the goal plans are not held back (`reservesGoalPlans`).
  public var goalPlans: AmountE4
  public var events: AmountE4
  public var subtractsGoalSavings: Bool
  public var reservesGoalPlans: Bool
  /// Currencies of amounts left out for want of a rate today, by code.
  public var withoutRate: [CurrencyCode]

  public init(
    scheduled: AmountE4 = .zero, debts: AmountE4 = .zero, goalSavings: AmountE4 = .zero,
    goalPlans: AmountE4 = .zero, events: AmountE4 = .zero, subtractsGoalSavings: Bool = true,
    reservesGoalPlans: Bool = true, withoutRate: [CurrencyCode] = []
  ) {
    self.scheduled = scheduled
    self.debts = debts
    self.goalSavings = goalSavings
    self.goalPlans = goalPlans
    self.events = events
    self.subtractsGoalSavings = subtractsGoalSavings
    self.reservesGoalPlans = reservesGoalPlans
    self.withoutRate = withoutRate
  }

  /// Everything the grey line takes away.
  public var total: AmountE4 { scheduled + debts + goalSavings + goalPlans + events }

  /// The plan from `today` through `until` (D, as `FreeMoney.window` clips it).
  ///
  /// `goals` are the statuses of the live goals (`GoalRules.statuses`), `debts` the Debts
  /// section (`DebtsOverview.build`), `events` the events with a budget still under way or
  /// ahead (`EventsPlanning.budgetedAhead`), `accounts` the balances and what is in the summary
  /// (`AccountsSnapshot`), `matches` the due dates paid by ordinary operations.
  public static func build(
    ledger: Ledger, book: PlanningBook, accounts: AccountsSnapshot, today: DateOnly,
    until d: DateOnly, rubPerUnit: [CurrencyCode: Decimal], matches: ScheduledMatches,
    goals: [GoalStatus], debts: DebtsOverview, events: [EventPlan], reserveGoalPlan: Bool,
    subtractGoalSavings: Bool
  ) -> CashPlan {
    var missing: Set<CurrencyCode> = []
    func rubles(_ amount: AmountE4, in currency: CurrencyCode) -> AmountE4 {
      guard let converted = SubscriptionMath.rubles(amount, in: currency, rubPerUnit: rubPerUnit)
      else {
        missing.insert(currency)
        return .zero
      }
      return converted
    }
    let month = today.monthKey

    // Scheduled payments.
    var scheduled = AmountE4.zero
    let list = ledger.dataset.paymentMethods
    let mainId = list.first { $0.isDefault && !$0.archived }?.id
    let accountsById = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let beforeThisMonth = month.firstDay.adding(days: -1)
    for payment in book.scheduled where payment.active {
      guard let next = payment.nextDate, next <= d,
        accounts.isInSummary(payment.paymentMethodId)
      else { continue }
      let accountId = payment.paymentMethodId ?? mainId
      let settledThrough =
        accountId.flatMap { id -> DateOnly? in
          let account = accountsById[id]
          let currency =
            account.map { $0.holds(payment.currency) ? payment.currency : $0.mainCurrency }
            ?? payment.currency
          return accounts.balances.latestAnchor(BalanceKey(accountId: id, currency: currency))
            .map { ledger.calendar.day(of: $0.at) }
        } ?? beforeThisMonth
      let dates = Recurrence.occurrences(
        from: next, through: d, rule: RecurrenceRule(payment: payment), end: payment.endDate,
        limit: 10_000)
      for date in dates where date > settledThrough && !matches.isPaid(payment.id, date) {
        let price = SubscriptionMath.price(of: payment, on: date, prices: book.prices)
        scheduled += rubles(price, in: payment.currency)
      }
    }

    // Debts I owe.
    var debtTotal = AmountE4.zero
    var paidIn: [MonthKey: Set<UUID>] = [:]
    for line in debts.iOwe {
      let debt = line.debt
      guard let payment = debt.monthlyPaymentE4, payment.raw > 0, let day = debt.paymentDay,
        line.balance.raw > 0
      else { continue }
      // The debt starts on the earliest day of its journal: a payment day before it owed
      // nothing — a phone bought in parts on the 15th is not paid on the 5th of that month.
      let start = DebtSchedule.start(of: line.entries, calendar: ledger.calendar)
      var owed = AmountE4.zero
      for current in MonthKey.range(month, through: d.monthKey) {
        let payday = Recurrence.clipped(day: day, in: current)
        guard payday <= d, DebtStart.owes(due: payday, startsOn: start) else { continue }
        let paid: Bool
        if current == month {
          paid = line.paidThisMonth
        } else {
          paid = DebtSchedule.isPaid(
            debt, for: current, startsOn: start, calendar: ledger.calendar
          ) { month in
            if paidIn[month] == nil {
              paidIn[month] = DebtSchedule.debtsPaid(
                in: month, ledger: ledger, journal: book.debtEntries)
            }
            return DebtSchedule.isPaid(
              debt.id, in: month, paidByOperation: paidIn[month] ?? [],
              journal: book.debtEntries)
          }
        }
        if !paid { owed += payment }
      }
      guard owed.raw > 0 else { continue }
      debtTotal += rubles(min(owed, line.balance), in: debt.currency)
    }

    // Goals.
    var savings = AmountE4.zero
    var plans = AmountE4.zero
    let laterMonths = max(0, month.months(to: d.monthKey))
    for status in goals where !status.goal.archived {
      if subtractGoalSavings, status.saved.raw > 0 {
        if let saved = status.rubles(status.saved) {
          savings += saved
        } else {
          missing.insert(status.currency)
        }
      }
      guard reserveGoalPlan, let plan = status.goal.monthlyPlanE4, plan.raw > 0 else { continue }
      let rest = min(max(.zero, plan - status.contributedThisMonth), plan)
      let later = SubscriptionMath.rounded(plan.decimal * Decimal(laterMonths))
      let asked = min(rest + later, status.remaining)
      guard asked.raw > 0 else { continue }
      if let converted = status.rubles(asked) {
        plans += converted
      } else {
        missing.insert(status.currency)
      }
    }

    // Events with a budget.
    var eventTotal = AmountE4.zero
    for plan in events where !plan.event.archived {
      guard let budget = plan.budget else { continue }
      let counts =
        plan.event.covers(today) || (plan.event.startDate > today && plan.event.startDate <= d)
      guard counts else { continue }
      eventTotal += max(.zero, budget - plan.spent)
    }

    return CashPlan(
      scheduled: scheduled, debts: debtTotal, goalSavings: savings, goalPlans: plans,
      events: eventTotal, subtractsGoalSavings: subtractGoalSavings,
      reservesGoalPlans: reserveGoalPlan,
      withoutRate: missing.sorted { $0.code < $1.code })
  }
}
