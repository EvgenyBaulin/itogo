import CoreAnalytics
import CoreKit
import Foundation

/// The debt load of the Advice section («нагрузка — платежи / доход»): what the monthly
/// payments of my debts take out of a month's income.
public struct DebtLoad: Hashable, Sendable {
  public enum Status: Hashable, Sendable {
    case ready
    /// No figure: the key says why, the app says it in words.
    case notEnoughData(reasonKey: String)
  }

  /// Where the income the load is measured against came from.
  public enum IncomeSource: Hashable, Sendable {
    /// The caller's estimate for the month.
    case given
    /// `IncomeEstimate` from the history: the median of the last complete months.
    case history
    case none
  }

  /// Neither an estimate nor a complete month of history to take the median of.
  public static let noIncomeKey = "debts.load.noIncome"

  /// Σ monthly payments of the open debts I owe, in rubles.
  public var monthlyPaymentsRub: AmountE4
  public var incomeRub: AmountE4?
  public var incomeSource: IncomeSource
  /// Payments ÷ income in basis points (10 000 = 100 %), rounded half away from zero.
  public var loadBp: Int?
  /// Open debts I owe in a currency without a known rate: left out, never guessed.
  public var withoutRate: [UUID]
  /// Open debts I owe with no monthly payment set: they add nothing to the load.
  public var withoutPayment: [UUID]
  public var status: Status

  public init(
    monthlyPaymentsRub: AmountE4, incomeRub: AmountE4?, incomeSource: IncomeSource,
    loadBp: Int?, withoutRate: [UUID], withoutPayment: [UUID], status: Status
  ) {
    self.monthlyPaymentsRub = monthlyPaymentsRub
    self.incomeRub = incomeRub
    self.incomeSource = incomeSource
    self.loadBp = loadBp
    self.withoutRate = withoutRate
    self.withoutPayment = withoutPayment
    self.status = status
  }

  /// The load for the month of `today`.
  ///
  /// Payments are the monthly payments of every open debt I owe — a payment on something
  /// bought in instalments is not spending, but it takes money out of the month all the
  /// same. A payment in another currency is converted at the last rate the caller knows
  /// (`rubPerUnit`); without one the debt is listed, not guessed.
  ///
  /// The income is the caller's estimate for the month (`income`, normally
  /// `IncomeEstimate.month`). Without one it is the same estimate from the history alone —
  /// the median of the last complete months, at most three, or what came this month when
  /// that is more — so the load and «can save» never divide by two different incomes. A
  /// month with only what came so far is no estimate: a half-month's income would inflate
  /// the load. No positive income — no load, «not enough data».
  ///
  /// A debt whose dues have sums of their own — a grace period, a main payment worked out over
  /// months — weighs what its next unpaid due asks for (`dues`, the states of the debts'
  /// dues); without its state, its monthly payment.
  public static func load(
    debts: [Debt], ledger: Ledger, today: DateOnly, income: AmountE4?,
    rubPerUnit: [CurrencyCode: Decimal], dues: [UUID: DebtDueState] = [:]
  ) -> DebtLoad {
    let payments = monthlyPayments(of: debts, rubPerUnit: rubPerUnit, dues: dues)
    let incomeRub: AmountE4?
    let source: IncomeSource
    if let income {
      incomeRub = income
      source = .given
    } else if let estimate = historyIncome(ledger: ledger, today: today) {
      incomeRub = estimate
      source = .history
    } else {
      incomeRub = nil
      source = .none
    }
    guard let incomeRub, incomeRub.raw > 0 else {
      return DebtLoad(
        monthlyPaymentsRub: payments.total, incomeRub: incomeRub, incomeSource: source,
        loadBp: nil, withoutRate: payments.withoutRate, withoutPayment: payments.withoutPayment,
        status: .notEnoughData(reasonKey: noIncomeKey))
    }
    let exact = payments.total.decimal * 10_000 / incomeRub.decimal
    let bp = (try? DecimalMath.int64(rounding: exact)).map { Int(clamping: $0) } ?? Int.max
    return DebtLoad(
      monthlyPaymentsRub: payments.total, incomeRub: incomeRub, incomeSource: source,
      loadBp: bp, withoutRate: payments.withoutRate, withoutPayment: payments.withoutPayment,
      status: .ready)
  }

  /// Σ monthly payments of the open debts I owe, in rubles — the figure on top of the Debts
  /// section too — with the debts it could not convert and the ones without a payment. A debt
  /// whose dues have sums of their own counts its next unpaid due (`payment(of:dues:)`).
  static func monthlyPayments(
    of debts: [Debt], rubPerUnit: [CurrencyCode: Decimal], dues: [UUID: DebtDueState] = [:]
  ) -> (total: AmountE4, withoutRate: [UUID], withoutPayment: [UUID]) {
    var total = AmountE4.zero
    var withoutRate: [UUID] = []
    var withoutPayment: [UUID] = []
    for debt in debts where !debt.closed && debt.direction == .iOwe {
      guard let payment = payment(of: debt, dues: dues[debt.id]), !payment.isZero else {
        withoutPayment.append(debt.id)
        continue
      }
      guard let rubles = DebtRubles.convert(payment, from: debt.currency, rubPerUnit: rubPerUnit)
      else {
        withoutRate.append(debt.id)
        continue
      }
      total += rubles
    }
    return (total, DebtRubles.sorted(withoutRate), DebtRubles.sorted(withoutPayment))
  }

  /// What a month of `debt` takes: the monthly payment — or, for a debt whose dues have sums of
  /// their own (a grace period, a main payment over `repayMonths`), what its next unpaid due asks
  /// for, as `dues` know it; the monthly payment when they know none.
  public static func payment(of debt: Debt, dues: DebtDueState?) -> AmountE4? {
    guard debt.grace != nil || debt.repayMonths != nil, let dues,
      let index = dues.firstUnpaidIndex
    else { return debt.monthlyPaymentE4 }
    let amount = dues.amount(ofDue: index)
    return amount.raw > 0 ? amount : debt.monthlyPaymentE4
  }

  /// The income estimate of the month from the history alone, without expectations; `nil`
  /// before the first complete month.
  static func historyIncome(ledger: Ledger, today: DateOnly) -> AmountE4? {
    let estimate = IncomeEstimate.month(ledger: ledger, statuses: [], today: today)
    guard estimate.source == .median else { return nil }
    return estimate.value
  }
}

/// Rubles for the Debts section: a foreign amount at the last rate the caller knows, or
/// nothing — never a guess.
enum DebtRubles {
  /// `nil` without a rate, and for rubles that do not fit into stored units: the debt is then
  /// left out of the totals like one without a rate, rather than counted at the largest figure
  /// that fits — which nobody owes, and which the next balance added to it would overflow.
  static func convert(
    _ amount: AmountE4, from currency: CurrencyCode, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    // Nothing is worth nothing in any currency: a settled foreign debt needs no rate.
    if currency == .rub || amount.isZero { return amount }
    guard let rate = rubPerUnit[currency] else { return nil }
    return try? AmountE4(decimal: amount.decimal * rate)
  }

  /// Ids in a stable order, so a list never depends on hashing.
  static func sorted(_ ids: some Sequence<UUID>) -> [UUID] {
    ids.sorted { $0.uuidString < $1.uuidString }
  }
}
