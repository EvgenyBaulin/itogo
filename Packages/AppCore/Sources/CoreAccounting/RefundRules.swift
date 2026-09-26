import CoreKit
import Foundation

/// Why a refund of a purchase cannot be made, or a purchase with refunds cannot go.
public enum RefundError: Error, Hashable, Sendable {
  /// The part is not something that can be refunded: not a live purchase of my own — paid
  /// for somebody else, bought on credit, a payment on a debt, a contribution to a goal, or a
  /// line the app wrote for its books.
  case notRefundable
  /// More than what is left of the part after the refunds already made.
  case exceedsRemaining
  /// A refund of nothing, or of less than nothing.
  case notPositive
  /// The purchase has refunds that take money back from it: deleting it would leave them
  /// taking back from nothing. The refunds go first, or in the same deletion.
  case purchaseHasRefunds
  /// A refund in another currency than its purchase: it takes back in the purchase's currency,
  /// at the purchase's rate.
  case otherCurrency
}

/// Refunds taken back from one part of one purchase.
///
/// A refund is made in the purchase's currency at the purchase's rate, so taking back the
/// whole part takes it to zero exactly. The money comes onto an account at the refund's own
/// moment — by default the purchase's account — and when that account does not hold the
/// currency, what it received is prefilled at the rates of the refund's own day, the way a
/// bank converts a card refund on the day it arrives (`prefillLeg`) — never at the purchase's
/// rate the refund carries.
public enum RefundRules {
  /// A live purchase of my own: not paid for somebody else, not bought on credit, not a
  /// payment on a debt, not a contribution to a goal, not a line the app wrote for its books.
  public static func isRefundable(
    part: TransactionPart, in entry: TransactionEntry, tree: CategoryTree
  ) -> Bool {
    let transaction = entry.transaction
    guard !transaction.isDeleted, transaction.kind == .expense,
      transaction.creditDebtId == nil, transaction.debtId == nil,
      entry.parts.contains(where: { $0.id == part.id })
    else { return false }
    guard !part.reimbursable else { return false }
    guard
      !QualityResolver.isGoalContribution(
        goalId: part.goalId, categoryId: part.categoryId, categories: tree)
    else { return false }
    return OperationLink(externalId: transaction.externalId)?.isBookkeeping != true
  }

  /// What `account` received for a refund of `amount` in `currency` on `day`, to prefill
  /// «Списано со счёта» — here what came onto the account —, editable: `nil` when the account
  /// holds the currency, or when a rate of the day is missing and the figure is typed.
  ///
  /// At the rates of the refund's day, in rubles too: the refund carries the purchase's rate for
  /// its own rubles, and `AccountRules.prefillLeg` would take that one.
  public static func prefillLeg(
    amount: AmountE4, currency: CurrencyCode, day: DateOnly, account: PaymentMethod,
    rates: DayRates
  ) -> AmountE4? {
    AccountRules.prefillLeg(
      amount: amount, currency: currency, rate: nil, day: day, account: account, rates: rates)
  }

  /// Whether the operation is a refund that takes money back from a purchase part.
  public static func takesBack(_ entry: TransactionEntry) -> Bool {
    entry.transaction.kind == .refund && entry.parts.contains { $0.refundOfPartId != nil }
  }

  /// The same for a draft.
  public static func takesBack(_ draft: TransactionDraft) -> Bool {
    draft.kind == .refund && draft.parts.contains { $0.refundOfPartId != nil }
  }

  /// What is left of the part to refund, in the purchase's currency.
  public static func remaining(part: TransactionPart, index: RefundIndex) -> AmountE4 {
    max(.zero, part.amountE4 - index.refunded(part: part.id))
  }

  /// The rubles a new refund of `amount` stores: what is left of the part's rubles when it
  /// completes the part — so the stored rubles of all its refunds add up to the part exactly —
  /// otherwise its share of the part's rubles. For display and the export only: the rubles
  /// taken off the purchase are worked out from the part itself (`RefundIndex`).
  ///
  /// A refund brings money back, so its rubles are above zero: when the refunds before it
  /// stored as much as the part is worth now, or more — its rate was edited down after them —
  /// nothing is left to complete it with, and it stores its own share at the part's rate
  /// instead.
  public static func rubles(
    refundAmount amount: AmountE4, part: TransactionPart,
    refundedBefore: (amount: AmountE4, rub: AmountE4)
  ) -> AmountE4 {
    let rest = part.amountRubE4 - refundedBefore.rub
    if amount == part.amountE4 - refundedBefore.amount, rest.raw > 0 {
      return rest
    }
    guard !part.amountE4.isZero else { return .zero }
    let exact = amount.decimal * part.amountRubE4.decimal / part.amountE4.decimal
    return (try? AmountE4(decimal: exact)) ?? .zero
  }

  /// What the refunds of the part already took back, in amount and in stored rubles — what
  /// `rubles(refundAmount:part:refundedBefore:)` needs for the next one.
  public static func refundedBefore(
    part: TransactionPart, index: RefundIndex
  ) -> (amount: AmountE4, rub: AmountE4) {
    (index.refunded(part: part.id), index.refundedStoredRub(part: part.id))
  }

  /// The refund of `amount` of `part` — «Вся сумма» when `amount` is nil: what is left of it.
  ///
  /// A refund in the purchase's currency at the purchase's rate, with one part that takes back
  /// from `part` and carries its category, quality, «на кого», person and event; the place is
  /// the purchase's, and so is the account unless `accountId` names another. What it copies is
  /// for display: the figures follow the purchase part, so later edits of the purchase are not
  /// carried over to the refund.
  ///
  /// The draft is materialized with the rubles of `rubles(refundAmount:part:refundedBefore:)`
  /// as its converter; the rate stays the purchase's.
  public static func draft(
    refunding part: TransactionPart, of purchase: TransactionEntry, amount: AmountE4?,
    occurredAt: Date, accountId: UUID?, index: RefundIndex, tree: CategoryTree
  ) throws -> TransactionDraft {
    guard isRefundable(part: part, in: purchase, tree: tree) else {
      throw RefundError.notRefundable
    }
    let left = remaining(part: part, index: index)
    let refund = amount ?? left
    guard refund.raw > 0 else {
      throw amount == nil ? RefundError.exceedsRemaining : RefundError.notPositive
    }
    guard refund <= left else { throw RefundError.exceedsRemaining }
    let transaction = purchase.transaction
    return TransactionDraft(
      kind: .refund,
      occurredAt: occurredAt,
      currency: transaction.currency,
      amount: refund,
      rate: transaction.rate,
      rateDate: transaction.rateDate,
      rateSource: transaction.rateSource,
      rateProvisional: transaction.rateProvisional,
      note: part.note ?? transaction.note,
      placeId: transaction.placeId,
      paymentMethodId: accountId ?? transaction.paymentMethodId,
      parts: [
        PartDraft(
          categoryId: part.categoryId,
          categorySource: part.categorySource,
          quality: part.quality,
          qualitySource: part.qualitySource,
          amount: refund,
          forWhom: part.forWhom,
          forPersonId: part.forPersonId,
          eventId: part.eventId,
          refundOfPartId: part.id)
      ])
  }
}
