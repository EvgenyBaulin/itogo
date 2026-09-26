import CoreAccounting
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

/// The free sum: the money there is now, and what of it is free until a day D.
///
/// * **Main** — the money now: every balance of the accounts in the summary, its latest count
///   plus every real movement after it, converted to rubles at today's rate
///   (`AccountsSnapshot.inSummaryTotalRub`). Right after a count it equals the count. Income
///   still expected is never added. With no count at all there is nothing to show but «Мало
///   данных: сделайте первую сверку» (`State.noReconciliation`); a balance never counted is
///   listed (`unanchored`), not guessed.
/// * **Grey** — «Учитывая запланированные События и траты»: the main figure less what has to
///   leave by D (`CashPlan`), each part a line of its own so the lines add up to it.
/// * **Daily guide** — max(0, grey) ÷ the days of [today, D], today included.
/// * **Info** — what the expectations still wait for until D: shown, never added.
/// * The groups left out of the summary get no free sum; their totals are shown apart.
public struct FreeMoney: Hashable, Sendable {
  public enum State: String, Hashable, Sendable {
    case ready
    /// No balance of the summary was ever counted.
    case noReconciliation
  }

  /// The keys of the lines; the app supplies the words.
  public enum Key {
    public static let scheduled = "planning.free.scheduled"
    public static let debts = "planning.free.debts"
    public static let goalSavings = "planning.free.goalSavings"
    public static let goalPlans = "planning.free.goalReserve"
    public static let events = "planning.free.events"
    public static let stillExpected = "planning.free.expected"
  }

  /// A group left out of the summary, with its own total.
  public struct ExcludedGroup: Hashable, Sendable {
    public var group: AccountGroup
    /// `nil` while none of its balances was counted and converted.
    public var totalRub: AmountE4?
    public var withoutRate: [CurrencyCode]

    public init(group: AccountGroup, totalRub: AmountE4?, withoutRate: [CurrencyCode] = []) {
      self.group = group
      self.totalRub = totalRub
      self.withoutRate = withoutRate
    }
  }

  /// How far ahead D may be.
  public static let horizonMonths = 12

  public var today: DateOnly
  /// D, after clipping (`window`).
  public var until: DateOnly
  /// Days of [today, D], today included; at least 1.
  public var days: Int
  /// The money now; `nil` with no count (`state`).
  public var main: AmountE4?
  /// The main figure less `lines`; `nil` with no count.
  public var grey: AmountE4?
  /// max(0, grey) ÷ `days`; zero without a grey line.
  public var dailyGuide: AmountE4
  /// What the grey line takes away, each a minus line, in the order the block shows them.
  public var lines: [FreeToSpendLine]
  /// Shown and never subtracted: what the expectations still wait for until D.
  public var info: [FreeToSpendLine]
  public var excluded: [ExcludedGroup]
  /// Currencies of counted balances left out of the main figure for want of a rate today.
  public var mainWithoutRate: [CurrencyCode]
  /// Currencies of planned amounts left out of the lines for want of a rate today.
  public var planWithoutRate: [CurrencyCode]
  /// Expectations whose remainder has no rate today, left out of «ещё ждём».
  public var stillExpectedWithoutRate: [UUID]
  /// Balances of the accounts in the summary never counted: their money is in no figure yet.
  public var unanchored: [BalanceKey]
  public var plan: CashPlan
  public var state: State

  public init(
    accounts: AccountsSnapshot, plan: CashPlan, stillExpected: AmountE4,
    stillExpectedWithoutRate: [UUID] = [], today: DateOnly, until: DateOnly
  ) {
    let window = Self.window(today: today, until: until)
    var lines = [
      FreeToSpendLine(key: Key.scheduled, sign: .minus, amount: plan.scheduled),
      FreeToSpendLine(key: Key.debts, sign: .minus, amount: plan.debts),
    ]
    if plan.subtractsGoalSavings {
      lines.append(FreeToSpendLine(key: Key.goalSavings, sign: .minus, amount: plan.goalSavings))
    }
    if plan.reservesGoalPlans {
      lines.append(FreeToSpendLine(key: Key.goalPlans, sign: .minus, amount: plan.goalPlans))
    }
    lines.append(FreeToSpendLine(key: Key.events, sign: .minus, amount: plan.events))

    let main = accounts.inSummaryTotalRub
    let grey = main.map { $0 + AmountE4.sum(lines.map(\.signedAmount)) }
    let days = max(1, window.dayCount)
    self.today = today
    self.until = window.end
    self.days = days
    self.main = main
    self.grey = grey
    self.dailyGuide = grey.map { SavingsMath.divide(max(.zero, $0), by: days) } ?? .zero
    self.lines = lines
    self.info = [FreeToSpendLine(key: Key.stillExpected, sign: .plus, amount: stillExpected)]
    self.excluded = accounts.excluded.compactMap { section in
      section.group.map {
        ExcludedGroup(group: $0, totalRub: section.totalRub, withoutRate: section.withoutRate)
      }
    }
    self.mainWithoutRate = accounts.inSummaryWithoutRate
    self.planWithoutRate = plan.withoutRate
    self.stillExpectedWithoutRate = stillExpectedWithoutRate
    self.unanchored = accounts.unanchored.filter { accounts.isInSummary($0.accountId) }
    self.plan = plan
    self.state = main == nil ? .noReconciliation : .ready
  }

  /// [today, D]: D no earlier than today and no later than 12 months ahead; the end of this
  /// month when none is given.
  public static func window(today: DateOnly, until: DateOnly?) -> DayRange {
    let latest = today.adding(months: horizonMonths)
    return DayRange(today, min(max(until ?? today.monthKey.lastDay, today), latest))
  }
}
