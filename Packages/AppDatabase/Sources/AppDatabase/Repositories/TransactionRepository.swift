import AppCore
import CoreKit
import Foundation
import GRDB

/// Reads and writes operations together with their parts. Deletion is always soft, so
/// ⌘Z can bring an operation back exactly as it was.
public struct TransactionRepository: Sendable {
  let writer: any DatabaseWriter
  /// My ratings by description (`manualQualityHistory()`), kept between reads.
  let manualRatings = ManualRatingsCache()

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// Saves an operation and its parts in one transaction. Parts must add up to the total.
  public func save(_ entry: TransactionEntry) throws {
    guard entry.isBalanced else { throw DatabaseError.unbalancedParts }
    try writer.write { db in
      try entry.transaction.save(db)
      try Self.replaceParts(of: entry, db: db)
    }
  }

  /// Brings the parts of an operation in line with the entry, updating the rows that stay
  /// instead of recreating them.
  ///
  /// A `reimbursement_links` row cascades away with the part it points at, so deleting
  /// every part and inserting it again would wipe the trail of a reimbursement each time
  /// the operation is edited. Only the parts that really went away are deleted.
  static func replaceParts(of entry: TransactionEntry, db: Database) throws {
    let kept = entry.parts.map(\.id.uuidString)
    try TransactionPart
      .filter(Column("transaction_id") == entry.transaction.id.uuidString)
      .filter(!kept.contains(Column("id")))
      .deleteAll(db)
    for part in entry.parts {
      try part.save(db)
    }
  }

  public func entry(id: UUID) throws -> TransactionEntry? {
    try writer.read { db in try Self.entry(id: id, db: db) }
  }

  /// One operation with its parts, in the order they were written, inside a read or a
  /// write the caller already holds.
  static func entry(id: UUID, db: Database) throws -> TransactionEntry? {
    guard let transaction = try CoreKit.Transaction.fetchOne(db, key: id.uuidString) else {
      return nil
    }
    let parts =
      try TransactionPart
      .filter(Column("transaction_id") == id.uuidString)
      .order(Column.rowID)
      .fetchAll(db)
    return TransactionEntry(transaction: transaction, parts: parts)
  }

  /// Operations of a period, newest first, deleted ones left out.
  ///
  /// Operations of the same instant — imported and generated rows share theirs — come by
  /// their ids, the way the ledger orders them (`Ledger`), not in whatever order the index
  /// happens to reach them.
  public func entries(from: Date, to: Date) throws -> [TransactionEntry] {
    try writer.read { db in
      try Self.entries(
        where: "deleted_at IS NULL AND occurred_at >= ? AND occurred_at <= ?",
        arguments: [from, to], order: "occurred_at DESC, id DESC", db: db)
    }
  }

  /// The latest operations, newest first; ties go by the time they were written, then by id.
  public func recentEntries(limit: Int = 200) throws -> [TransactionEntry] {
    try writer.read { db in
      let transactions = try CoreKit.Transaction
        .filter(Column("deleted_at") == nil)
        .order(Column("occurred_at").desc, Column("created_at").desc, Column("id").desc)
        .limit(limit)
        .fetchAll(db)
      return try Self.attachParts(to: transactions, db: db)
    }
  }

  /// Operations with at least one part I rated by hand — everything rule 2 of the qualities
  /// needs (`ManualQualityHistory`), without reading the whole history for it.
  public func entriesRatedByHand() throws -> [TransactionEntry] {
    try writer.read { db in
      try Self.entries(
        where: """
          deleted_at IS NULL
            AND id IN (SELECT transaction_id FROM transaction_parts WHERE quality_source = ?)
          """,
        arguments: [QualitySource.manual.rawValue], db: db)
    }
  }

  /// Rule 2 of the qualities — my ratings by description — built from `entriesRatedByHand()`,
  /// read from the database once and kept until an operation or a part is written, by this
  /// repository or any other on the same database (`ManualRatingsCache`).
  public func manualQualityHistory() throws -> ManualQualityHistory {
    try manualRatings.history(in: writer) {
      ManualQualityHistory(entries: try entriesRatedByHand())
    }
  }

  public func count() throws -> Int {
    try writer.read { db in
      try CoreKit.Transaction.filter(Column("deleted_at") == nil).fetchCount(db)
    }
  }

  /// How many operations **in the bin** still have a part filed under one of these
  /// categories. Asked before a category is deleted: a deleted operation keeps its parts, and
  /// the schema refuses to drop a category while any part points at it — but nothing in the
  /// app can re-file the parts of an operation that is in the bin. Counted here rather than
  /// over the pipeline's data, which is live-only by construction.
  public func binnedOperations(inCategories ids: [UUID]) throws -> Int {
    guard !ids.isEmpty else { return 0 }
    return try writer.read { db in
      let marks = databaseQuestionMarks(count: ids.count)
      return try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(DISTINCT p.transaction_id)
          FROM transaction_parts p
          JOIN transactions t ON t.id = p.transaction_id
          WHERE t.deleted_at IS NOT NULL AND p.category_id IN (\(marks))
          """,
        arguments: StatementArguments(ids.map { $0.uuidString })) ?? 0
    }
  }

  /// Soft delete: the row stays, so undo brings it back with a single update. It goes the
  /// same way as a deletion of many (`softDelete(ids:at:)`), so a reimbursement deleted on
  /// its own also takes its surplus and shortfalls along and gives its parts back.
  @discardableResult
  public func softDelete(id: UUID, at instant: Date = Date()) throws -> DeletionEffects {
    try softDelete(ids: [id], at: instant)
  }

  public func restore(
    id: UUID, at instant: Date = Date(), effects: DeletionEffects = .none
  ) throws {
    try restore(ids: [id], at: instant, effects: effects)
  }

  /// Hard delete, used only when undoing a save that has just been made.
  ///
  /// A debt payment moved its debt right after it was saved, and that movement goes in the
  /// same write: the foreign key would only set its `transaction_id` to NULL and leave the
  /// debt reduced by a payment that never happened.
  public func purge(id: UUID) throws {
    _ = try writer.write { db in
      try db.execute(
        sql: "DELETE FROM debt_entries WHERE transaction_id = ?", arguments: [id.uuidString])
      try db.execute(sql: "DELETE FROM transactions WHERE id = ?", arguments: [id.uuidString])
    }
  }

  // MARK: Parts paid for somebody else

  /// Parts that are still waiting to come back — the "Owed to me" list.
  ///
  /// Only purchases with a part that can still be waiting for are read: `owedToMe` would
  /// pass over every other operation, and there is no point in mapping the whole history
  /// for it.
  public func owedParts() throws -> [OwedPart] {
    let entries = try writer.read { db -> [TransactionEntry] in
      try Self.entries(
        where: """
          deleted_at IS NULL AND kind = ?
            AND id IN (
              SELECT transaction_id FROM transaction_parts
              WHERE reimbursable = 1
                AND (reimbursement_status IS NULL OR reimbursement_status = ?))
          """,
        arguments: [TransactionKind.expense.rawValue, ReimbursementStatus.expected.rawValue],
        db: db)
    }
    return MyExpensesRule.owedToMe(entries: entries)
  }

  /// Writes the result of a reimbursement: the links, the new statuses and, when the
  /// money did not match, the extra income or expense the rules produced.
  ///
  /// The parts were read when the sheet opened, and each of them may have stopped waiting
  /// since — its purchase deleted from another window or taken back by ⌘Z, the part written
  /// off or closed by another reimbursement. Such a part is refused inside the write with
  /// `ReimbursementError.partNoLongerOwed`, and nothing is written: a link to it would count
  /// the money as returned with nothing behind it.
  public func apply(
    _ outcome: ReimbursementOutcome,
    reimbursement: TransactionEntry,
    extra: [TransactionEntry] = [],
    at instant: Date = Date()
  ) throws {
    guard reimbursement.isBalanced else { throw DatabaseError.unbalancedParts }
    // The surplus and the shortfalls are operations like any other: their parts have to
    // add up too, or the totals would never match again.
    guard extra.allSatisfy(\.isBalanced) else { throw DatabaseError.unbalancedParts }
    try writer.write { db in
      var checked: Set<UUID> = []
      for partId in outcome.closedPartIds + outcome.links.map(\.partId)
      where checked.insert(partId).inserted {
        guard try Self.isOwed(partId: partId, db: db) else {
          throw ReimbursementError.partNoLongerOwed(partId)
        }
      }
      try reimbursement.transaction.save(db)
      try Self.replaceParts(of: reimbursement, db: db)
      for entry in extra {
        try entry.transaction.save(db)
        try Self.replaceParts(of: entry, db: db)
      }
      for link in outcome.links {
        try link.insert(db)
      }
      for partId in outcome.closedPartIds {
        try db.execute(
          sql: "UPDATE transaction_parts SET reimbursement_status = ? WHERE id = ?",
          arguments: [ReimbursementStatus.returned.rawValue, partId.uuidString])
      }
      try Self.stampOperations(ofParts: outcome.closedPartIds, at: instant, db: db)
    }
  }

  /// How far a part has come back is a fact about its operation, like any field of it: the
  /// operation was updated when a reimbursement closed the part, when deleting that
  /// reimbursement reopened it (and ⌘Z closed it again), and when it was written off.
  /// `status` narrows it to the parts whose status is that one, read before the status moves.
  static func stampOperations(
    ofParts partIds: [UUID], whereStatus status: ReimbursementStatus? = nil, at instant: Date,
    db: Database
  ) throws {
    let condition = status == nil ? "" : "reimbursement_status = ? AND "
    let statusArgument = status.map { StatementArguments([$0.rawValue]) } ?? []
    for chunk in partIds.map(\.uuidString).chunked(by: chunkSize) {
      let marks = databaseQuestionMarks(count: chunk.count)
      try db.execute(
        sql: """
          UPDATE transactions SET updated_at = ?
          WHERE id IN (
            SELECT transaction_id FROM transaction_parts WHERE \(condition)id IN (\(marks)))
          """,
        arguments: StatementArguments([instant]) + statusArgument + StatementArguments(chunk))
    }
  }

  /// Whether a part still waits for its money, by the same condition as `owedParts()`: a
  /// part «for somebody else» of a live purchase, neither returned nor written off.
  private static func isOwed(partId: UUID, db: Database) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS (
          SELECT 1 FROM transaction_parts p
          JOIN transactions t ON t.id = p.transaction_id
          WHERE p.id = ? AND t.deleted_at IS NULL AND t.kind = ? AND p.reimbursable = 1
            AND (p.reimbursement_status IS NULL OR p.reimbursement_status = ?))
        """,
      arguments: [
        partId.uuidString, TransactionKind.expense.rawValue,
        ReimbursementStatus.expected.rawValue,
      ]) ?? false
  }

  /// Writing a part off: it stops waiting and becomes my spending.
  ///
  /// The sheet offers the parts it read when it opened. One that stopped waiting since —
  /// closed by a reimbursement, written off, its purchase deleted — is refused inside the
  /// write with `ReimbursementError.partNoLongerOwed`, as `apply` refuses it: a closed part
  /// written off would leave its link counting money for a part given up on.
  public func writeOffPart(id: UUID, at instant: Date = Date()) throws {
    _ = try writer.write { db in
      guard try Self.isOwed(partId: id, db: db) else {
        throw ReimbursementError.partNoLongerOwed(id)
      }
      try db.execute(
        sql: "UPDATE transaction_parts SET reimbursement_status = ? WHERE id = ?",
        arguments: [ReimbursementStatus.writtenOff.rawValue, id.uuidString])
      try Self.stampOperations(ofParts: [id], at: instant, db: db)
    }
  }

  /// Ids go to SQLite in chunks: one `IN (…)` per operation would run into the limit on
  /// bound parameters (32 766) long before the history is large.
  static let chunkSize = 500

  /// Parts of a list of operations already in hand, their ids sent in chunks. For lists
  /// with a bound of their own — a page of recent operations, a selection.
  ///
  /// Parts come out in the order they were written (`rowid`), which is the order of the
  /// draft they were saved from: the last part is the one that took the rounding remainder
  /// of the rubles, and the first is the one the list shows.
  static func attachParts(
    to transactions: [CoreKit.Transaction], db: Database
  ) throws
    -> [TransactionEntry]
  {
    guard !transactions.isEmpty else { return [] }
    var parts: [TransactionPart] = []
    for chunk in transactions.map(\.id.uuidString).chunked(by: chunkSize) {
      parts += try TransactionPart.filter(chunk.contains(Column("transaction_id")))
        .order(Column.rowID)
        .fetchAll(db)
    }
    let grouped = Dictionary(grouping: parts, by: \.transactionId)
    return transactions.map {
      TransactionEntry(transaction: $0, parts: grouped[$0.id] ?? [])
    }
  }

  /// Operations a condition on `transactions` selects, with their parts.
  ///
  /// The parts are read by the same condition, as a subquery, in one statement: no id is
  /// ever bound as a parameter, so a history of any length reads the same way. `condition`
  /// and `order` are SQL written in this file, never text from outside; the values go in
  /// `arguments`, which the two statements share.
  static func entries(
    where condition: String, arguments: StatementArguments, order: String? = nil,
    db: Database
  ) throws -> [TransactionEntry] {
    let ordering = order.map { " ORDER BY \($0)" } ?? ""
    let transactions = try CoreKit.Transaction.fetchAll(
      db, sql: "SELECT * FROM transactions WHERE \(condition)\(ordering)", arguments: arguments)
    return try attachParts(
      to: transactions,
      selectedBy: """
        SELECT * FROM transaction_parts
        WHERE transaction_id IN (SELECT id FROM transactions WHERE \(condition))
        ORDER BY rowid
        """,
      arguments: arguments, db: db)
  }

  /// Attaches the parts a statement reads — in the order it reads them, which must be
  /// `rowid` — to the operations they belong to. Parts of operations not in the list are
  /// passed over.
  static func attachParts(
    to transactions: [CoreKit.Transaction], selectedBy sql: String,
    arguments: StatementArguments = [], db: Database
  ) throws -> [TransactionEntry] {
    guard !transactions.isEmpty else { return [] }
    var grouped: [UUID: [TransactionPart]] = [:]
    grouped.reserveCapacity(transactions.count)
    let parts = try TransactionPart.fetchCursor(db, sql: sql, arguments: arguments)
    while let part = try parts.next() {
      grouped[part.transactionId, default: []].append(part)
    }
    return transactions.map {
      TransactionEntry(transaction: $0, parts: grouped[$0.id] ?? [])
    }
  }
}

extension Array {
  /// Consecutive slices of at most `size` elements, in order.
  func chunked(by size: Int) -> [ArraySlice<Element>] {
    guard size > 0 else { return [self[...]] }
    return stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
  }
}

/// Why a write did not land, as far as the owner can do something about it.
public enum WriteFailureCause: Hashable, Sendable {
  /// Rows are tied the other way: a row the write takes away is pointed at by one made since
  /// — an operation filed under a category the undone step created — or a row it puts back
  /// points at one removed since. The schema's foreign keys, or
  /// `PlanningWriteError.referencedByOperations`.
  case tiedToOtherRows
  /// Anything else: the database did not take the write.
  case other

  public init(of error: any Error) {
    if error is PlanningWriteError {
      self = .tiedToOtherRows
    } else if let database = error as? GRDB.DatabaseError,
      Self.foreignKeyCodes.contains(database.extendedResultCode)
    {
      self = .tiedToOtherRows
    } else {
      self = .other
    }
  }

  /// A row inserted or put back that points at nothing fails as a foreign key; a row deleted
  /// while another points at it by `ON DELETE RESTRICT` fails through SQLite's trigger code,
  /// with the same «FOREIGN KEY constraint failed». The schema has no triggers of its own.
  private static let foreignKeyCodes: [ResultCode] = [
    .SQLITE_CONSTRAINT_FOREIGNKEY, .SQLITE_CONSTRAINT_TRIGGER,
  ]
}
