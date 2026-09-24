import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// One monthly limit as the Planning section shows it: what is available this month, what is
/// spent, the pace and the forecast to the end of the month, and the status.
public struct LimitLine: Hashable, Sendable {
  public var budget: Budget
  /// The month the line is for — the month of «today».
  public var month: MonthKey
  /// The limit itself, `budget.amountE4`.
  public var amount: AmountE4
  /// What earlier months left unspent (rollover); zero without rollover.
  public var carry: AmountE4
  /// My spending under the limit in the month, refunds taken off (`LimitRules.spent`).
  public var spent: AmountE4
  /// Basis points of `available` spent; `nil` when nothing is available.
  public var spentShareBp: Int?
  /// Basis points of the month gone by, today included.
  public var elapsedShareBp: Int
  /// The spent share against the elapsed share, in basis points: 10 000 is exactly on pace,
  /// above it is faster than the month. `nil` with the spent share.
  public var paceBp: Int?
  /// What the caller said is still due under the limit this month (scheduled payments).
  public var planned: AmountE4
  /// Spent + planned + the average daily variable spending × days left.
  public var forecast: AmountE4
  /// The history window was shorter than 28 days, so the daily rate is this month's.
  public var lowData: Bool
  public var status: LimitStatus

  public init(
    budget: Budget, month: MonthKey, amount: AmountE4, carry: AmountE4, spent: AmountE4,
    spentShareBp: Int?, elapsedShareBp: Int, paceBp: Int?, planned: AmountE4, forecast: AmountE4,
    lowData: Bool, status: LimitStatus
  ) {
    self.budget = budget
    self.month = month
    self.amount = amount
    self.carry = carry
    self.spent = spent
    self.spentShareBp = spentShareBp
    self.elapsedShareBp = elapsedShareBp
    self.paceBp = paceBp
    self.planned = planned
    self.forecast = forecast
    self.lowData = lowData
    self.status = status
  }

  /// The limit plus what earlier months carried over.
  public var available: AmountE4 { amount + carry }
  /// Available minus spent; negative once the limit is overspent.
  public var remaining: AmountE4 { available - spent }
}

/// Why a limit cannot be saved. The app turns the case into words.
public enum BudgetIssue: String, Hashable, Sendable, CaseIterable {
  /// A system category or one under it: those accept no limit.
  case systemCategory
  /// Limits are on spending; an income category has none.
  case incomeCategory
  /// A category limit without a known category, a «for whom» limit without a value.
  case missingTarget
  /// Another limit already covers the same category, the same «for whom» value, or bad
  /// spending.
  case duplicate
  /// The amount is zero or below.
  case nonPositive
}

/// The rules of monthly limits. Every figure comes from the `Ledger`, so a limit spends
/// exactly what Overview and Analytics call my expenses.
public enum LimitRules {
  /// A limit is «on the edge» once this share of what is available is spent.
  public static let warningShareBp = 9_000

  /// The lines of every limit of the book for the month of `today`, in the book's order.
  ///
  /// `plannedByCategory` holds what is still due this month under each category a payment is
  /// filed under (its own id, a subcategory's or a parent's); a limit takes what falls in its
  /// scope, so a limit on a parent also takes what is due under its subcategories.
  /// `plannedByForWhom` does the same for «for whom» limits. Bad spending has no plan.
  public static func lines(
    book: PlanningBook, ledger: Ledger, today: DateOnly,
    plannedByCategory: [UUID: AmountE4] = [:], plannedByForWhom: [ForWhom: AmountE4] = [:]
  ) -> [LimitLine] {
    book.budgets.map { budget in
      line(
        budget: budget, ledger: ledger, today: today,
        planned: planned(
          for: budget, tree: ledger.tree, byCategory: plannedByCategory,
          byForWhom: plannedByForWhom))
    }
  }

  /// One limit for the month of `today`.
  ///
  /// * pace = (spent ÷ available) ÷ (today's day ÷ days in the month), from the exact values,
  ///   not from the rounded shares;
  /// * forecast = spent + planned + `meanDaily` × the days after today; that last term is
  ///   never below zero and is rounded half away from zero;
  /// * status: `over` when spent exceeds what is available; `warning` when the forecast does,
  ///   or 90 % of a positive limit is spent; `ok` otherwise.
  public static func line(
    budget: Budget, ledger: Ledger, today: DateOnly, planned: AmountE4 = .zero
  ) -> LimitLine {
    let month = today.monthKey
    let daysInMonth = month.dayCount
    let carry = carry(of: budget, into: month, ledger: ledger)
    let available = budget.amountE4 + carry
    let spent = spent(of: budget, in: month, ledger: ledger)

    let elapsedShareBp = basisPoints(
      Decimal(today.day) * Decimal(Shares.whole) / Decimal(daysInMonth))
    let spentShareBp = Shares.ratio(spent, of: available)
    let paceBp: Int? =
      available.raw > 0
      ? basisPoints(
        Decimal(spent.raw) * Decimal(daysInMonth) * Decimal(Shares.whole)
          / (Decimal(available.raw) * Decimal(today.day)))
      : nil

    let rate = meanDaily(of: budget, ledger: ledger, today: today)
    let daysLeft = daysInMonth - today.day
    let forecast = spent + planned + rounded(max(0, rate.amount * Decimal(daysLeft)))

    let status: LimitStatus
    if spent > available {
      status = .over
    } else if forecast > available
      || (available.raw > 0
        && Decimal(spent.raw) * Decimal(Shares.whole)
          >= Decimal(available.raw) * Decimal(warningShareBp))
    {
      status = .warning
    } else {
      status = .ok
    }

    return LimitLine(
      budget: budget, month: month, amount: budget.amountE4, carry: carry, spent: spent,
      spentShareBp: spentShareBp, elapsedShareBp: elapsedShareBp, paceBp: paceBp,
      planned: planned, forecast: forecast, lowData: rate.lowData, status: status)
  }

  // MARK: - What a limit counts

  /// The row falls under the limit.
  ///
  /// Only my spending counts, and never goal contributions or system categories: money put
  /// aside and the app's own categories are not what a limit is about. A limit on a
  /// category covers its subcategories; a limit on a subcategory covers only itself. Bad
  /// spending is every row rated bad; a «for whom» limit is every row with that value.
  public static func counts(_ row: LedgerRow, for budget: Budget) -> Bool {
    guard !row.isGoalContribution, row.systemRole == nil else { return false }
    // The difference a reconciliation wrote is the books catching up with the money, not
    // spending a limit is about. It was kept out by its category while that was «Не помню», a
    // system one; it lives in «Сверка» now, an ordinary category, so it is
    // named here. Only this link: a shortfall is real money the owner is out of pocket, and
    // a charge of a scheduled payment is real spending too.
    if case .reconciliation = row.link { return false }
    switch budget.scope {
    case .category:
      guard let categoryId = budget.categoryId else { return false }
      return row.categoryId == categoryId || row.rootCategoryId == categoryId
    case .badTotal:
      return row.quality == .bad
    case .forWhom:
      guard let value = budget.forWhom else { return false }
      return row.forWhom == value
    }
  }

  /// A row the daily rate is taken from: under the limit and not a payment that comes on its
  /// own schedule — a scheduled payment marked as paid, or a debt payment — since those are
  /// planned rather than spent day by day.
  public static func isVariable(_ row: LedgerRow, for budget: Budget) -> Bool {
    guard counts(row, for: budget), row.debtId == nil else { return false }
    if case .scheduled = row.link { return false }
    return true
  }

  /// Σ of the contributions to my expenses of the rows under the limit dated in the month:
  /// refunds negative, a part paid for somebody else zero until it is written off. The whole
  /// month, operations dated later than today included — the same month the reports show.
  public static func spent(of budget: Budget, in month: MonthKey, ledger: Ledger) -> AmountE4 {
    AmountE4.sum(
      ledger.rows(in: Period.month(month).range).lazy
        .filter { counts($0, for: budget) }
        .map(\.contribution))
  }

  /// What earlier months left unspent: only with rollover and a start month.
  /// Starting at zero in the start month, each month hands on max(0, available − spent),
  /// where available is the limit plus what it received: unspent money goes on piling up,
  /// an overspent month hands on nothing, and overspending is never carried as a debt.
  /// Months before the start carry nothing.
  public static func carry(of budget: Budget, into month: MonthKey, ledger: Ledger) -> AmountE4 {
    guard budget.rollover, let start = budget.startMonth, start < month else { return .zero }
    var carry = AmountE4.zero
    for earlier in MonthKey.range(start, through: month.previous) {
      let left = budget.amountE4 + carry - spent(of: budget, in: earlier, ledger: ledger)
      carry = left.raw > 0 ? left : .zero
    }
    return carry
  }

  /// The limit as it is written when saved in `month` over `stored`, its row as the book has
  /// it now (`nil` for a new limit).
  ///
  /// The carry is counted with the limit's current amount and scope, and the book keeps no
  /// history of them. So an edit that changes the amount or what the limit counts, or turns
  /// rollover on, starts the rollover again in `month`: counting the months before with the
  /// new figures would invent leftovers they never had or wipe the ones they had. A new
  /// limit, or one saved before limits had a start month, starts in `month`; any other save
  /// keeps its start.
  public static func saving(_ budget: Budget, over stored: Budget?, in month: MonthKey) -> Budget {
    var budget = budget
    let restarts =
      stored.map { stored in
        stored.amountE4 != budget.amountE4 || stored.scope != budget.scope
          || stored.categoryId != budget.categoryId || stored.forWhom != budget.forWhom
          || (!stored.rollover && budget.rollover)
      } ?? true
    budget.startMonth = restarts ? month : (budget.startMonth ?? stored?.startMonth ?? month)
    return budget
  }

  /// The average daily variable spending under the limit, as a decimal.
  ///
  /// The window is [max(today − 90, the first day with money under the limit), yesterday], a
  /// dense series where a day without spending is a zero — the window of the month forecast,
  /// narrowed to the limit. A window shorter than 28 days is too little
  /// history: the rate is then the variable spending since the 1st through today ÷ today's
  /// day.
  public static func meanDaily(
    of budget: Budget, ledger: Ledger, today: DateOnly
  ) -> (amount: Decimal, lowData: Bool) {
    let windowFloor = today.adding(days: -MonthForecast.windowLength)
    let earlierMatch =
      ledger.firstDay.map { first in
        ledger.rows(in: DayRange(first, windowFloor.adding(days: -1)))
          .contains { !$0.contribution.isZero && counts($0, for: budget) }
      } ?? false
    let firstInWindow = ledger.rows(in: DayRange(windowFloor, today))
      .first { !$0.contribution.isZero && counts($0, for: budget) }?.day
    let yesterday = today.adding(days: -1)

    if let start = earlierMatch ? windowFloor : firstInWindow {
      let window = DayRange(start, yesterday)
      if window.dayCount >= MonthForecast.minimumWindow {
        let sum = variableSpending(of: budget, in: window, ledger: ledger)
        return (sum / Decimal(window.dayCount), false)
      }
    }
    let sinceFirst = variableSpending(
      of: budget, in: DayRange(today.monthKey.firstDay, today), ledger: ledger)
    return (sinceFirst / Decimal(today.day), true)
  }

  private static func variableSpending(
    of budget: Budget, in range: DayRange, ledger: Ledger
  ) -> Decimal {
    AmountE4.sum(
      ledger.rows(in: range).lazy.filter { isVariable($0, for: budget) }.map(\.contribution)
    ).decimal
  }

  /// What is due under the limit: a category limit takes the payments filed under the
  /// category and, for a parent, under its subcategories — the scope `counts` gives rows.
  private static func planned(
    for budget: Budget, tree: CategoryTree, byCategory: [UUID: AmountE4],
    byForWhom: [ForWhom: AmountE4]
  ) -> AmountE4 {
    switch budget.scope {
    case .category:
      guard let categoryId = budget.categoryId else { return .zero }
      return AmountE4.sum(
        byCategory.lazy
          .filter { key, _ in key == categoryId || tree.root(of: key)?.id == categoryId }
          .map(\.value))
    case .forWhom:
      return budget.forWhom.flatMap { byForWhom[$0] } ?? .zero
    case .badTotal:
      return .zero
    }
  }

  // MARK: - Validation

  /// Why the limit cannot be saved next to `existing`, or `nil` when it can. `existing` may
  /// contain the limit itself (an edit): a limit never duplicates itself.
  public static func validate(
    _ budget: Budget, tree: CategoryTree, existing: [Budget]
  ) -> BudgetIssue? {
    switch budget.scope {
    case .category:
      guard let categoryId = budget.categoryId, let category = tree.category(categoryId) else {
        return .missingTarget
      }
      guard tree.acceptsLimit(categoryId) else { return .systemCategory }
      if category.kind == .income || tree.root(of: categoryId)?.kind == .income {
        return .incomeCategory
      }
    case .forWhom:
      guard budget.forWhom != nil else { return .missingTarget }
    case .badTotal:
      break
    }
    guard budget.amountE4.raw > 0 else { return .nonPositive }
    let taken = existing.contains { other in
      guard other.id != budget.id, other.scope == budget.scope else { return false }
      switch budget.scope {
      case .category: return other.categoryId == budget.categoryId
      case .forWhom: return other.forWhom == budget.forWhom
      case .badTotal: return true
      }
    }
    return taken ? .duplicate : nil
  }

  // MARK: - Rounding

  /// Half away from zero to stored units; sums of real money never reach the
  /// clamps.
  private static func rounded(_ value: Decimal) -> AmountE4 {
    (try? AmountE4(decimal: value)) ?? (value < 0 ? AmountE4(raw: .min) : AmountE4(raw: .max))
  }

  private static func basisPoints(_ value: Decimal) -> Int {
    Int((try? DecimalMath.int64(rounding: value)) ?? 0)
  }
}
