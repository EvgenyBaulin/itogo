import AppCore
import CoreKit
import Foundation
import GRDB

/// One operation edited on its own — in the inspector or the edit sheet — and what the edit
/// moved with it, as it was before: everything undo needs to put it all back, since undoing
/// an edit writes the whole earlier state.
public struct EditedEntry: Hashable, Sendable {
  /// The operation as it was inside the write, before the edit.
  public var before: TransactionEntry
  /// The operation as the edit wrote it.
  public var after: TransactionEntry
  /// Journal lines of the operation the edit rewrote or took away, as they were.
  public var journalBefore: [DebtEntry]
  /// Journal lines the edit added.
  public var journalAdded: [UUID]
  /// The rowid each line of `journalBefore` had: a line taken away and given back returns to
  /// its place among the lines of its day, not last.
  public var journalRowIDs: [UUID: Int64]
  /// Links of reimbursements to the parts the edit took away: a link goes with its part
  /// (`ON DELETE CASCADE`), and the part given back by undo needs it — or deleting the
  /// reimbursement would never open the part again.
  public var removedLinks: [ReimbursementLink]

  public init(
    before: TransactionEntry, after: TransactionEntry, journalBefore: [DebtEntry] = [],
    journalAdded: [UUID] = [], journalRowIDs: [UUID: Int64] = [:],
    removedLinks: [ReimbursementLink] = []
  ) {
    self.before = before
    self.after = after
    self.journalBefore = journalBefore
    self.journalAdded = journalAdded
    self.journalRowIDs = journalRowIDs
    self.removedLinks = removedLinks
  }

  /// Whether the edit moved a debt.
  public var movedDebts: Bool { !journalBefore.isEmpty || !journalAdded.isEmpty }

  /// Whether the edit, or its undo, wrote more than the operation — journal lines, links —
  /// so the data the app shows has to be read again rather than laid over.
  public var reachesBeyondTheOperation: Bool { movedDebts || !removedLinks.isEmpty }
}

/// What became of `TransactionRepository.edit`.
public enum EditResult: Hashable, Sendable {
  /// The operation is deleted or was never there: nothing was written.
  case gone
  /// The edit changes nothing in the row as it is now.
  case unchanged
  case edited(EditedEntry)
}

extension TransactionRepository {

  /// Edits one operation in one write, together with the journal lines that point at it.
  ///
  /// `transform` gets the operation as it is inside the write — the row the edit is laid over
  /// (`TransactionEntry.rebased(onto:)`) — and returns it edited, or `nil` to leave it. The row
  /// is stamped with `instant`. An operation that moves a debt — a payment, money lent or
  /// borrowed, a purchase on credit — takes its journal line along
  /// (`DebtRules.journal(of:afterEditing:into:debts:calendar:)`): the days of the lines are
  /// days of `calendar`, the one the entry line dates them by.
  ///
  /// What a reimbursement worked out — its links, the parts it closed, its surplus and
  /// shortfalls — is not edited in place (`OperationEditRule`).
  ///
  /// Throws what `transform` throws, `EditRefusal` when the edit may not be written, and
  /// `DatabaseError.unbalancedParts` when the parts do not add up; nothing is written then.
  public func edit(
    id: UUID, at instant: Date = Date(), calendar: CalendarContext,
    transform: (TransactionEntry) throws -> TransactionEntry?
  ) throws -> EditResult {
    try writer.write { db in
      try Self.edit(id: id, at: instant, calendar: calendar, transform: transform, db: db)
    }
  }

  /// Takes an edit back in one write: the operation as it was, its journal lines as they
  /// were — the lines the edit added go, the ones it changed or took away come back — and the
  /// links of the parts it took away. A line whose debt is gone since, or a link whose
  /// reimbursement is, has nothing to come back to.
  public func revert(_ edit: EditedEntry) throws {
    guard edit.before.isBalanced else { throw DatabaseError.unbalancedParts }
    try writer.write { db in
      try edit.before.transaction.save(db)
      try Self.replaceParts(of: edit.before, db: db)
      _ = try DebtEntry.deleteAll(db, keys: edit.journalAdded.map(\.uuidString))
      for line in edit.journalBefore {
        guard try Debt.exists(db, key: line.debtId.uuidString) else { continue }
        try line.save(db)
        guard let rowID = edit.journalRowIDs[line.id] else { continue }
        // `OR IGNORE`: a rowid another line took meanwhile leaves this one last, nothing more.
        try db.execute(
          sql: "UPDATE OR IGNORE debt_entries SET rowid = ? WHERE id = ? AND rowid <> ?",
          arguments: [rowID, line.id.uuidString, rowID])
      }
      for link in edit.removedLinks {
        guard try CoreKit.Transaction.exists(db, key: link.reimbursementTxId.uuidString),
          try TransactionPart.exists(db, key: link.partId.uuidString)
        else { continue }
        try link.save(db)
      }
    }
  }

  static func edit(
    id: UUID, at instant: Date, calendar: CalendarContext,
    transform: (TransactionEntry) throws -> TransactionEntry?, db: Database
  ) throws -> EditResult {
    guard let fresh = try entry(id: id, db: db), !fresh.transaction.isDeleted else {
      return .gone
    }
    guard var changed = try transform(fresh), changed != fresh else { return .unchanged }
    guard changed.id == fresh.id, changed.parts.allSatisfy({ $0.transactionId == fresh.id })
    else { throw DatabaseError.notFound }
    guard changed.isBalanced else { throw DatabaseError.unbalancedParts }
    if let refusal = OperationEditRule.refusal(
      editing: fresh, into: changed, settles: try settles(fresh.transaction, db: db))
    {
      throw refusal
    }
    changed.transaction.updatedAt = instant

    let lines = try DebtEntry.filter(Column("transaction_id") == id.uuidString)
      .order(Column.rowID)
      .fetchAll(db)
    let journal = try DebtRules.journal(
      of: lines, afterEditing: fresh.transaction, into: changed.transaction,
      debts: try debts(of: [fresh.transaction, changed.transaction], db: db), calendar: calendar)

    let kept = Set(changed.parts.map(\.id))
    let removedParts = fresh.parts.map(\.id).filter { !kept.contains($0) }
    let removedLinks =
      try ReimbursementLink
      .filter(removedParts.map(\.uuidString).contains(Column("part_id")))
      .order(Column.rowID)
      .fetchAll(db)

    try write(changed, over: fresh, db: db)

    let existing = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
    var edited = EditedEntry(before: fresh, after: changed, removedLinks: removedLinks)
    for line in journal.upsert {
      if let old = existing[line.id] {
        edited.journalBefore.append(old)
      } else {
        edited.journalAdded.append(line.id)
      }
    }
    for lineId in journal.delete {
      if let old = existing[lineId] { edited.journalBefore.append(old) }
    }
    for line in edited.journalBefore {
      edited.journalRowIDs[line.id] = try Int64.fetchOne(
        db, sql: "SELECT rowid FROM debt_entries WHERE id = ?", arguments: [line.id.uuidString])
    }
    for line in journal.upsert { try line.save(db) }
    _ = try DebtEntry.deleteAll(db, keys: journal.delete.map(\.uuidString))
    return .edited(edited)
  }

  /// Whether a reimbursement closed parts — a link of its own — or left a live surplus or
  /// shortfall, found by the key in `external_id`.
  private static func settles(_ transaction: CoreKit.Transaction, db: Database) throws -> Bool {
    guard transaction.kind == .reimbursement else { return false }
    let links =
      try ReimbursementLink
      .filter(Column("reimbursement_tx_id") == transaction.id.uuidString)
      .fetchCount(db)
    if links > 0 { return true }
    let companion = try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS (
          SELECT 1 FROM transactions WHERE deleted_at IS NULL AND substr(external_id, 1, ?) = ?)
        """,
      arguments: prefixArguments(of: transaction.id))
    return companion ?? false
  }

  /// The debts these operations point at, by id.
  private static func debts(
    of transactions: [CoreKit.Transaction], db: Database
  ) throws -> [UUID: Debt] {
    let ids = Set(transactions.flatMap { [$0.debtId, $0.creditDebtId] }.compactMap { $0 })
    guard !ids.isEmpty else { return [:] }
    let debts = try Debt.fetchAll(db, keys: ids.map(\.uuidString))
    return Dictionary(debts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }
}
