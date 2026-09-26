import CoreAccounting
import CoreKit
import Foundation

/// The money of a goal, counted in the goal's own currency — the one rule the goals of
/// Planning (`GoalRules` in CorePlanning) and the planned payments of the forecast
/// (`PlannedPayments`) share, so the two can never disagree about a goal.
///
/// A row belongs to a goal when it carries the goal's id, or when it carries no goal at all
/// and is filed under the goal's subcategory. A contribution is an `expense` and adds; a
/// withdrawal is a `refund` and takes off; nothing else touches a goal.
///
/// A row in the goal's currency counts with its own amount. A ruble goal counts rubles, as it
/// always did. Any other row counts its rubles at the rate of its own day
/// (`DayRates` — rubles for one unit, the nominal applied: 100 tenge are quoted, one is kept),
/// so a contribution made months ago does not change value when the rate moves.
public enum GoalMath {
  /// Whether the row is money put into the goal or taken out of it.
  public static func belongs(_ row: LedgerRow, to goal: Goal) -> Bool {
    row.goalId == goal.id
      || (row.goalId == nil && row.categoryId != nil && row.categoryId == goal.subcategoryId)
  }

  /// What a row adds to a goal, in the goal's currency: plus for a contribution, minus for a
  /// withdrawal, zero for a row of another goal or of another kind. `nil` when the row counts
  /// but no rate of the goal's currency is known at all: the caller skips it and says so,
  /// rather than guessing.
  public static func contribution(
    of row: LedgerRow, to goal: Goal, rates: DayRates
  ) -> AmountE4? {
    guard belongs(row, to: goal) else { return .zero }
    return amount(of: row, in: goal.currency, rates: rates)
  }

  /// The row's signed amount in `currency`, the goal's belonging aside.
  private static func amount(
    of row: LedgerRow, in currency: CurrencyCode, rates: DayRates
  ) -> AmountE4? {
    let sign: Int64
    switch row.kind {
    case .expense: sign = 1
    case .refund: sign = -1
    case .income, .reimbursement: return .zero
    }
    let value: AmountE4
    if currency == .rub {
      value = row.amountRubE4
    } else if row.currency == currency {
      value = row.amountE4
    } else {
      guard let perUnit = rates.perUnit(currency, on: row.day), perUnit > 0 else { return nil }
      value = AmountE4.rounded(row.amountRubE4.decimal / perUnit)
    }
    return sign < 0 ? -value : value
  }

  /// An amount of `currency` in rubles at the rate the caller has for today (`rubPerUnit`,
  /// rubles for one unit); `nil` without one. Rubles stay as they are.
  public static func rubles(
    _ amount: AmountE4, in currency: CurrencyCode, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    if currency == .rub { return amount }
    guard let rate = rubPerUnit[currency], rate > 0 else { return nil }
    return AmountE4.rounded(amount.decimal * rate)
  }

  /// What the monthly plan of each live goal still asks in `month`, in the goal's currency:
  /// max(0, plan − net contributions of the month), never more than the plan itself and never
  /// more than the goal still needs, max(0, target − saved). A reached goal asks nothing, and a
  /// withdrawal of earlier months' savings is no plan of this month. Goals without a plan, or
  /// with nothing left to ask, are not in the map. A row without a rate adds nothing.
  public static func planLeft(
    goals: [Goal], rows: [LedgerRow], month: MonthKey, rates: DayRates
  ) -> [UUID: AmountE4] {
    let planned = goals.filter { goal in
      guard !goal.archived, let plan = goal.monthlyPlanE4 else { return false }
      return plan.raw > 0
    }
    guard !planned.isEmpty else { return [:] }
    var saved = Array(repeating: AmountE4.zero, count: planned.count)
    var thisMonth = Array(repeating: AmountE4.zero, count: planned.count)
    for row in rows where row.kind == .expense || row.kind == .refund {
      for (index, goal) in planned.enumerated() {
        guard let amount = contribution(of: row, to: goal, rates: rates), !amount.isZero else {
          continue
        }
        saved[index] += amount
        if row.day.monthKey == month { thisMonth[index] += amount }
      }
    }
    var result: [UUID: AmountE4] = [:]
    for (index, goal) in planned.enumerated() {
      let plan = goal.monthlyPlanE4 ?? .zero
      let left = min(
        max(.zero, plan - thisMonth[index]), plan, max(.zero, goal.targetE4 - saved[index]))
      if left.raw > 0 { result[goal.id] = left }
    }
    return result
  }
}
