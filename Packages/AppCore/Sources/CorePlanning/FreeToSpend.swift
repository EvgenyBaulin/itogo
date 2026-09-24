import CoreAnalytics
import CoreKit
import Foundation

/// One line of a formula the screen spells out: a key the app turns into words, whether the
/// line adds or takes away, and its rubles as they are (a line may be negative — refunds
/// that outweighed the spending, say).
public struct FreeToSpendLine: Hashable, Sendable {
  public enum Sign: String, Hashable, Sendable, CaseIterable {
    case plus
    case minus
  }

  public var key: String
  public var sign: Sign
  public var amount: AmountE4

  public init(key: String, sign: Sign, amount: AmountE4) {
    self.key = key
    self.sign = sign
    self.amount = amount
  }

  /// What the line does to the result.
  public var signedAmount: AmountE4 { sign == .plus ? amount : -amount }
}

/// What «Free to spend» is made of, in rubles, for the window from today through `until`.
/// The app gathers the figures — the scheduled payments and the debts come from the planned
/// month — and this type only does the arithmetic, so the formula lives in one place.
public struct FreeToSpendInputs: Hashable, Sendable {
  public var today: DateOnly
  /// The last day of the window; `nil` — the end of the month. Clipped to [today, end of
  /// the month].
  public var until: DateOnly?
  /// Income of this month that arrived by today (the Overview figure).
  public var incomeReceived: AmountE4
  /// What the expectations still wait for until `until` (`IncomeEstimate.month(until:)`).
  public var expectedIncome: AmountE4
  /// My expenses since the 1st, goal contributions included: money that left already.
  public var spentThisMonth: AmountE4
  /// My share of the scheduled payments still due through `until`.
  public var plannedScheduled: AmountE4
  /// Payments on debts whose payments are expenses, still due through `until`.
  public var plannedDebts: AmountE4
  /// What the goals' monthly plans still ask this month (`FreeToSpend.goalReserve`).
  public var goalReserve: AmountE4
  /// The switch of the setting `planning.reserveGoalPlan` (on by default).
  public var reserveEnabled: Bool
  /// Paid for others through `until` and expected back: shown, never subtracted.
  public var forOthersUntil: AmountE4

  public init(
    today: DateOnly, until: DateOnly? = nil, incomeReceived: AmountE4,
    expectedIncome: AmountE4 = .zero, spentThisMonth: AmountE4,
    plannedScheduled: AmountE4 = .zero, plannedDebts: AmountE4 = .zero,
    goalReserve: AmountE4 = .zero, reserveEnabled: Bool = true,
    forOthersUntil: AmountE4 = .zero
  ) {
    self.today = today
    self.until = until
    self.incomeReceived = incomeReceived
    self.expectedIncome = expectedIncome
    self.spentThisMonth = spentThisMonth
    self.plannedScheduled = plannedScheduled
    self.plannedDebts = plannedDebts
    self.goalReserve = goalReserve
    self.reserveEnabled = reserveEnabled
    self.forOthersUntil = forOthersUntil
  }
}

/// «Free to spend»: the money free until a day D of this month, with the whole formula and a
/// daily guide.
///
///     free = received + expected until D − spent since the 1st − scheduled until D
///            − debt payments until D − goal reserve (when the switch is on)
///
/// The goal reserve is what the monthly plans of the goals still ask this month; with the
/// switch off its line is left out rather than shown as a zero, so the lines always add up
/// to `free`. `free` may be negative — the month is overspent — and the daily guide is then
/// zero: max(0, free) ÷ the days of [today, D], today included. What I pay for others
/// until D and expect back is listed under `info` and never subtracted: it is not my
/// spending, and it comes back.
public struct FreeToSpend: Hashable, Sendable {
  /// The keys of the lines; the app supplies the words.
  public enum Key {
    public static let income = "planning.free.income"
    public static let expected = "planning.free.expected"
    public static let spent = "planning.free.spent"
    public static let scheduled = "planning.free.scheduled"
    public static let debts = "planning.free.debts"
    public static let goalReserve = "planning.free.goalReserve"
    public static let forOthers = "planning.free.forOthers"
  }

  public var today: DateOnly
  /// The last day of the window, after clipping.
  public var until: DateOnly
  public var lines: [FreeToSpendLine]
  public var free: AmountE4
  public var dailyGuide: AmountE4
  /// Days of [today, until], today included; at least 1.
  public var days: Int
  public var info: [FreeToSpendLine]

  public init(_ inputs: FreeToSpendInputs) {
    let window = Self.window(today: inputs.today, until: inputs.until)
    var lines = [
      FreeToSpendLine(key: Key.income, sign: .plus, amount: inputs.incomeReceived),
      FreeToSpendLine(key: Key.expected, sign: .plus, amount: inputs.expectedIncome),
      FreeToSpendLine(key: Key.spent, sign: .minus, amount: inputs.spentThisMonth),
      FreeToSpendLine(key: Key.scheduled, sign: .minus, amount: inputs.plannedScheduled),
      FreeToSpendLine(key: Key.debts, sign: .minus, amount: inputs.plannedDebts),
    ]
    if inputs.reserveEnabled {
      lines.append(FreeToSpendLine(key: Key.goalReserve, sign: .minus, amount: inputs.goalReserve))
    }
    let free = AmountE4.sum(lines.map(\.signedAmount))
    let days = max(1, window.dayCount)
    self.today = inputs.today
    self.until = window.end
    self.lines = lines
    self.free = free
    self.days = days
    self.dailyGuide = SavingsMath.divide(max(.zero, free), by: days)
    self.info =
      inputs.forOthersUntil.isZero
      ? [] : [FreeToSpendLine(key: Key.forOthers, sign: .minus, amount: inputs.forOthersUntil)]
  }

  /// [today, D] with D clipped to [today, end of the month]; the end of the month without D.
  public static func window(today: DateOnly, until: DateOnly?) -> DayRange {
    let last = today.monthKey.lastDay
    return DayRange(today, min(max(until ?? last, today), last))
  }

  /// Σ over the live goals with a monthly plan of max(0, plan − net contributions this
  /// month), each capped by what the goal still needs (`GoalRules.planStillDue`): the
  /// reserve for the contributions not made yet. The same figure as the planned goals of
  /// the forecast (`PlannedPayments.goals`).
  public static func goalReserve(goals: [Goal], ledger: Ledger, today: DateOnly) -> AmountE4 {
    AmountE4.sum(GoalRules.planStillDue(goals: goals, ledger: ledger, today: today).values)
  }
}
