import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// How much one payment method needs in one currency this month for the scheduled payments,
/// as in «card X: 10 000 ₸, 50 €, 75 $». Never converted: a card in tenge is topped up in
/// tenge.
public struct FundingLine: Hashable, Sendable {
  public var paymentMethodId: UUID?
  public var currency: CurrencyCode
  /// Every due date of the month: the ones still ahead at their price, the paid ones at
  /// what their operations took from this method in this currency.
  public var due: AmountE4
  /// What «Mark as paid» operations for the due dates of the month took from this method in
  /// this currency.
  public var paid: AmountE4
  /// max(0, due − paid): what still has to be there.
  public var remaining: AmountE4

  public init(
    paymentMethodId: UUID?, currency: CurrencyCode, due: AmountE4, paid: AmountE4,
    remaining: AmountE4
  ) {
    self.paymentMethodId = paymentMethodId
    self.currency = currency
    self.due = due
    self.paid = paid
    self.remaining = remaining
  }
}

public enum Funding {

  /// The funding of `month`, by payment method and currency.
  ///
  /// * Due — every due date of the month. The dates still ahead come from the schedule of
  ///   each active payment, from its `next_date`, at the price on that date, grouped by the
  ///   payment method and the currency of the payment. The dates already paid come from the
  ///   operations that paid them (`sched:<payment>:<due>`), because `next_date` has moved
  ///   past them: each is settled where its money came from — the operation's method and
  ///   currency, at its amount. A skipped date is in neither and needs no money.
  /// * Paid — those operations, in their own currency and with their own payment method: a
  ///   subscription paid from another card draws on that card, and the payment's own card
  ///   is not asked for it again. A paid date never leaves anything remaining.
  ///
  /// An operation counts in the month of the due date it paid, not of its own date: paying
  /// the 1 October charge on 30 September settles October, and September does not show
  /// money spent without a due date. `today` does not change the figures — an overdue date
  /// of the month still needs its money.
  ///
  /// Sorted by payment method (none last), then by currency code.
  public static func month(
    _ month: MonthKey, book: PlanningBook, ledger: Ledger, today: DateOnly
  ) -> [FundingLine] {
    struct Key: Hashable {
      let method: UUID?
      let currency: CurrencyCode
    }
    var due: [Key: AmountE4] = [:]
    var paid: [Key: AmountE4] = [:]
    let payments = Dictionary(
      book.scheduled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    var paidDues: [UUID: Set<DateOnly>] = [:]
    for row in ledger.rows where row.isFirstPart {
      guard case .scheduled(let paymentId, let dueDate) = row.link, dueDate.monthKey == month,
        payments[paymentId] != nil, let entry = ledger.entry(row.transactionId)
      else { continue }
      let transaction = entry.transaction
      let key = Key(method: transaction.paymentMethodId, currency: transaction.currency)
      due[key, default: .zero] += transaction.amountE4
      paid[key, default: .zero] += transaction.amountE4
      paidDues[paymentId, default: []].insert(dueDate)
    }

    for payment in book.scheduled where payment.active {
      guard let next = payment.nextDate else { continue }
      let dates = Recurrence.occurrences(
        from: next, through: month.lastDay, rule: RecurrenceRule(payment: payment),
        end: payment.endDate, limit: 10_000)
      for date in dates where date >= month.firstDay {
        guard paidDues[payment.id]?.contains(date) != true else { continue }
        due[Key(method: payment.paymentMethodId, currency: payment.currency), default: .zero] +=
          SubscriptionMath.price(of: payment, on: date, prices: book.prices)
      }
    }

    let keys = Set(due.keys).union(paid.keys)
    return
      keys
      .map { key in
        let owed = due[key] ?? .zero
        let spent = paid[key] ?? .zero
        return FundingLine(
          paymentMethodId: key.method, currency: key.currency, due: owed, paid: spent,
          remaining: max(.zero, owed - spent))
      }
      .sorted { left, right in
        if left.paymentMethodId != right.paymentMethodId {
          guard let first = left.paymentMethodId else { return false }
          guard let second = right.paymentMethodId else { return true }
          return first.uuidString < second.uuidString
        }
        return left.currency.code < right.currency.code
      }
  }
}
