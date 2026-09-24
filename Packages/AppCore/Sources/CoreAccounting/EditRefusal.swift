import CoreKit
import Foundation

/// Why the edit of one saved operation — in the inspector or the edit sheet — is not
/// written. The app turns each case into words; nothing of the edit lands.
public enum EditRefusal: Error, Hashable, Sendable, CaseIterable {
  /// The operation moves a debt kept in another currency: its journal counts the debt's own
  /// units, and rubles are never taken for dollars — the rule the entry line keeps too.
  case debtCurrency
  /// The money of a reimbursement that closed parts, or of the surplus or a shortfall it
  /// left: the links, the statuses of the closed parts and those operations were all worked
  /// out from that money. Another amount, type or currency written over it would leave them
  /// telling the old story. It is changed by deleting the reimbursement — which takes all of
  /// it along — and recording it again.
  case settledReimbursement
  /// The edit takes away a part a reimbursement closed: that reimbursement would close
  /// nothing, and its shortfall would be my spending on a part that is not there. The
  /// reimbursement is deleted first, which opens the part again.
  case closedPartRemoved
  /// The edit changes the money of a part a reimbursement closed — takes «paid for someone»
  /// off it, gives it another amount, or the operation another currency or type. The part
  /// is off my spending because its money came back, and the link holds how much: un-ticked,
  /// the part would be my spending while the money still counted as returned — in neither
  /// income nor a reduction of spending; re-amounted, the link would tell the old sum. The
  /// reimbursement is deleted first, which opens the part again.
  case closedPartChanged
}

/// What the edit of one saved operation may not do. The storage layer asks it inside the
/// write, of the row as it is then, with the facts only the database knows.
public enum OperationEditRule {
  /// Why `before` may not become `after`, or `nil` when it may.
  ///
  /// `settles` — `before` is a reimbursement that closed parts through its links or left a
  /// surplus or a shortfall. A surplus or a shortfall itself is known by its `external_id`
  /// (`OperationLink`).
  public static func refusal(
    editing before: TransactionEntry, into after: TransactionEntry, settles: Bool
  ) -> EditRefusal? {
    if settles || isCompanion(before.transaction),
      changesMoney(before.transaction, after.transaction)
    {
      return .settledReimbursement
    }
    let kept = Set(after.parts.map(\.id))
    let closed = before.parts.filter { $0.reimbursementStatus == .returned }
    if closed.contains(where: { !kept.contains($0.id) }) { return .closedPartRemoved }
    if changesClosedParts(closed, before: before.transaction, after: after) {
      return .closedPartChanged
    }
    return nil
  }

  /// Whether the edit touches what a reimbursement settled on these parts: that each is paid
  /// for somebody else and still closed, its amount, and the currency and the type of their
  /// operation. Rubles are left out: they follow the rate of the day, not the edit.
  private static func changesClosedParts(
    _ closed: [TransactionPart], before: Transaction, after: TransactionEntry
  ) -> Bool {
    guard !closed.isEmpty else { return false }
    if before.kind != after.transaction.kind || before.currency != after.transaction.currency {
      return true
    }
    let edited = Dictionary(
      after.parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return closed.contains { part in
      guard let now = edited[part.id] else { return false }
      return !now.reimbursable || now.reimbursementStatus != .returned
        || now.amountE4 != part.amountE4
    }
  }

  /// The surplus or a shortfall of a reimbursement.
  public static func isCompanion(_ transaction: Transaction) -> Bool {
    switch OperationLink(externalId: transaction.externalId) {
    case .surplus, .shortfall: true
    default: false
    }
  }

  /// What a reimbursement's resolver worked out from: how much, in what, and what it is.
  private static func changesMoney(_ before: Transaction, _ after: Transaction) -> Bool {
    before.kind != after.kind || before.amountE4 != after.amountE4
      || before.currency != after.currency
  }
}
