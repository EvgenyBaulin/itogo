import CoreAccounting
import CoreKit
import Foundation

/// The figures of the Overview cards, for one «today».
///
/// «Month to date» is the 1st through today: expenses by date, income that belongs to this
/// month and arrived by today. It is compared with the same span of the previous month —
/// the 1st through the same day number, clipped to that month's length — with income that
/// belongs to the previous month and arrived by the end of that span.
public struct OverviewSummary: Hashable, Sendable {
  public var today: DateOnly
  public var span: DayRange
  public var previousSpan: DayRange

  public var expenses: Change
  public var income: Change
  public var net: AmountE4 { income.current - expenses.current }

  /// Top five top-level categories of my expenses this month; shares are of all top-level
  /// categories, so the five need not add up to 100 %. «Uncategorized» is one of them when
  /// it is that large: unlike a table, the card ranks by amount alone.
  public var topCategories: [BreakdownNode]
  /// Good, neutral and bad spending this month, always in that order, with shares.
  public var qualities: [BreakdownNode]
  /// Bad spending this month against the same span of the previous month.
  public var bad: Change

  /// Parts paid for other people that are still expected back: what is left of each, since
  /// money back may cover only some of a part.
  public var owedToMe: AmountE4
  public var owedCount: Int

  public static let topCount = 5

  public init(ledger: Ledger, today: DateOnly) {
    self.today = today
    let span = Period.monthToDate(today: today).range
    let previousSpan = Period.sameSpanOfPreviousMonth(today: today).range
    self.span = span
    self.previousSpan = previousSpan

    expenses = Change(
      current: ledger.expenses(in: span), previous: ledger.expenses(in: previousSpan))
    income = Change(
      current: ledger.income(attributedTo: [today.monthKey], notAfter: today),
      previous: ledger.income(
        attributedTo: [previousSpan.start.monthKey], notAfter: previousSpan.end))

    let rows = ledger.rows(in: span).filter { !$0.contribution.isZero }
    // The tables put «Uncategorized» last; here it would then drop out of the five however
    // large it were, and the card would hide the largest bucket behind smaller ones.
    topCategories = Array(
      Tabulation.oneLevel(rows.map { (ReportGrouping.category.outerKey(of: $0), $0.contribution) })
        .filter { $0.amount.raw > 0 }
        .sorted(by: Tabulation.largestFirst)
        .prefix(Self.topCount))
    qualities = Self.qualities(of: rows)

    let previousBad = ledger.rows(in: previousSpan).filter { $0.quality == .bad }
    bad = Change(
      current: AmountE4.sum(rows.filter { $0.quality == .bad }.map(\.contribution)),
      previous: AmountE4.sum(previousBad.map(\.contribution)))

    let owed = ledger.rows.filter {
      $0.kind == .expense && $0.reimbursable && $0.reimbursementStatus == .expected
    }
    .map { ledger.remaining(ofPart: $0) }
    .filter { $0.raw > 0 }
    owedToMe = AmountE4.sum(owed)
    owedCount = owed.count
  }

  /// Good → neutral → bad, zero lines included so the bar keeps its order.
  static func qualities(of rows: some Sequence<LedgerRow>) -> [BreakdownNode] {
    var sums: [Quality: AmountE4] = [:]
    for row in rows {
      guard let quality = row.quality, !row.contribution.isZero else { continue }
      sums[quality, default: .zero] += row.contribution
    }
    let amounts = Quality.allCases.map { sums[$0] ?? .zero }
    let shares = Shares.basisPoints(amounts)
    return Quality.allCases.enumerated().map { index, quality in
      BreakdownNode(key: .quality(quality), amount: amounts[index], share: shares[index])
    }
  }
}
