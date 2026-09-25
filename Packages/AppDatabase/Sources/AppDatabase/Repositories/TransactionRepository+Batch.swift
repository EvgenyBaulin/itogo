import AppCore
import CoreKit
import Foundation
import GRDB

/// What deleting operations dragged along, kept whole so that undo can put every piece of
/// it back.
public struct DeletionEffects: Hashable, Sendable {
  /// The operations the call deleted: those asked for that were still there.
  public var deletedIds: [UUID]
  /// The surplus and the shortfalls of deleted reimbursements, deleted together with them.
  public var companionIds: [UUID]
  /// Parts a deleted reimbursement had closed that went back to waiting. Their links stay,
  /// so undo only has to close them again.
  public var reopenedPartIds: [UUID]
  /// The debt movements of deleted debt payments, taken off the debt.
  public var removedDebtEntries: [DebtEntry]
  /// The `sched:<payment>:<due>` keys of deleted «Mark as paid» operations, and the
  /// `transfer:<transfer>:fee` keys of deleted fees, by operation. A deleted operation pays
  /// nothing, so its key is cleared: the unique index would otherwise refuse to pay that due
  /// date again, or to give the transfer a fee again.
  public var releasedExternalIds: [UUID: String]
  /// Scheduled payments whose `next_date` went back to the due date a deleted operation
  /// had paid (`ScheduledRules.reopened`), as they were before.
  public var reopenedPayments: [ScheduledPayment]

  public static let none = DeletionEffects()

  public init(
    deletedIds: [UUID] = [],
    companionIds: [UUID] = [],
    reopenedPartIds: [UUID] = [],
    removedDebtEntries: [DebtEntry] = [],
    releasedExternalIds: [UUID: String] = [:],
    reopenedPayments: [ScheduledPayment] = []
  ) {
    self.deletedIds = deletedIds
    self.companionIds = companionIds
    self.reopenedPartIds = reopenedPartIds
    self.removedDebtEntries = removedDebtEntries
    self.releasedExternalIds = releasedExternalIds
    self.reopenedPayments = reopenedPayments
  }
}

/// One operation a bulk change rewrote: as it was inside the write, and as it was written.
public struct ModifiedEntry: Hashable, Sendable {
  public var before: TransactionEntry
  public var after: TransactionEntry

  public init(before: TransactionEntry, after: TransactionEntry) {
    self.before = before
    self.after = after
  }
}

/// Changing and deleting many operations at once. Every method is one SQLite transaction —
/// all of it lands or none of it does — and sends ids in chunks of `chunkSize`, far below
/// the limit on bound parameters, so «select all» over any history still works.
///
/// Each method has a twin `…InBackground` that does the very same work through
/// `await writer.write` / `writer.read`: the caller's thread is free while SQLite works. The
/// app takes it for a selection of more than a thousand operations, whose write would
/// otherwise freeze the window.
extension TransactionRepository {

  /// Operations by id, deleted ones included, in no particular order.
  public func entries(ids: [UUID]) throws -> [TransactionEntry] {
    try writer.read { db in try Self.entries(ids: ids, db: db) }
  }

  public func entriesInBackground(ids: [UUID]) async throws -> [TransactionEntry] {
    try await writer.read { db in try Self.entries(ids: ids, db: db) }
  }

  /// Changes many operations in one write and returns them as they were before.
  ///
  /// The change is made to the rows as they are **inside** the write, not to a copy read
  /// earlier: the list may lag behind the database — a part written off a moment ago, a
  /// rate refined in the background — and writing an old copy back would quietly undo that.
  /// `transform` returns the operation after the change, or `nil` to leave it alone. A
  /// deleted operation is left alone. Parts must still add up, or nothing is written.
  @discardableResult
  public func modify(
    ids: [UUID],
    at instant: Date = Date(),
    transform: (TransactionEntry) throws -> TransactionEntry?
  ) throws -> [TransactionEntry] {
    try writer.write { db in
      try Self.modify(ids: ids, at: instant, transform: transform, db: db).map(\.before)
    }
  }

  /// `modify` off the calling thread. It hands back each operation as it was and as it was
  /// written, since a caller that awaits cannot collect the results from inside `transform`.
  public func modifyInBackground(
    ids: [UUID],
    at instant: Date = Date(),
    transform: @escaping @Sendable (TransactionEntry) throws -> TransactionEntry?
  ) async throws -> [ModifiedEntry] {
    try await writer.write { db in
      try Self.modify(ids: ids, at: instant, transform: transform, db: db)
    }
  }

  /// Deletes many operations softly, with everything that hangs on them:
  ///
  /// * a reimbursement takes its surplus and shortfalls along — found by the key they keep
  ///   in `external_id` — and the parts it closed go back to waiting, unless another live
  ///   reimbursement still closes them. The links stay, for undo;
  /// * a payment on a debt takes its movement off the debt.
  ///
  /// Operations already deleted are left as they are. Undo is `restore(ids:at:effects:)`
  /// with what this returns.
  ///
  /// With `choose`, what goes is decided inside the write, from the rows as they are then:
  /// it gets the operations asked for, deleted ones included, and returns the ids to delete.
  /// Choosing and deleting in one transaction keeps a write that lands in between from
  /// changing what the choice was made on.
  @discardableResult
  public func softDelete(
    ids: [UUID], at instant: Date = Date(),
    choosing choose: (([TransactionEntry]) throws -> [UUID])? = nil
  ) throws -> DeletionEffects {
    try writer.write { db in
      let chosen = try choose.map { try $0(Self.entries(ids: ids, db: db)) } ?? ids
      return try Self.softDelete(ids: chosen, at: instant, db: db)
    }
  }

  /// `softDelete` off the calling thread, choosing the same way. Choosing and deleting in one
  /// transaction also queues the whole deletion at once, behind the writes asked for before
  /// it — the app keeps its steps of undo in that order.
  public func softDeleteInBackground(
    ids: [UUID], at instant: Date = Date(),
    choosing choose: (@Sendable ([TransactionEntry]) -> [UUID])? = nil
  ) async throws -> DeletionEffects {
    try await writer.write { db in
      let chosen = try choose.map { try $0(Self.entries(ids: ids, db: db)) } ?? ids
      return try Self.softDelete(ids: chosen, at: instant, db: db)
    }
  }

  /// Brings deleted operations back together with everything their deletion took along:
  /// the companions return, the reopened parts are closed again — unless they were written
  /// off or closed otherwise since — and the debt movements go back on their debts.
  public func restore(
    ids: [UUID], at instant: Date = Date(), effects: DeletionEffects = .none
  ) throws {
    try writer.write { db in try Self.restore(ids: ids, at: instant, effects: effects, db: db) }
  }

  public func restoreInBackground(
    ids: [UUID], at instant: Date = Date(), effects: DeletionEffects = .none
  ) async throws {
    try await writer.write { db in
      try Self.restore(ids: ids, at: instant, effects: effects, db: db)
    }
  }

  // MARK: The bodies, inside a transaction the caller holds

  static func entries(ids: [UUID], db: Database) throws -> [TransactionEntry] {
    var transactions: [CoreKit.Transaction] = []
    for chunk in distinct(ids).chunked(by: chunkSize) {
      transactions += try CoreKit.Transaction
        .filter(chunk.map(\.uuidString).contains(Column("id")))
        .fetchAll(db)
    }
    return try attachParts(to: transactions, db: db)
  }

  static func modify(
    ids: [UUID], at instant: Date, transform: (TransactionEntry) throws -> TransactionEntry?,
    db: Database
  ) throws -> [ModifiedEntry] {
    var modified: [ModifiedEntry] = []
    for chunk in distinct(ids).chunked(by: chunkSize) {
      let transactions = try CoreKit.Transaction
        .filter(chunk.map(\.uuidString).contains(Column("id")))
        .filter(Column("deleted_at") == nil)
        .fetchAll(db)
      for fresh in try attachParts(to: transactions, db: db) {
        guard var changed = try transform(fresh), changed != fresh else { continue }
        guard changed.id == fresh.id, changed.parts.allSatisfy({ $0.transactionId == fresh.id })
        else { throw DatabaseError.notFound }
        guard changed.isBalanced else { throw DatabaseError.unbalancedParts }
        changed.transaction.updatedAt = instant
        try write(changed, over: fresh, db: db)
        modified.append(ModifiedEntry(before: fresh, after: changed))
      }
    }
    return modified
  }

  static func softDelete(ids: [UUID], at instant: Date, db: Database) throws -> DeletionEffects {
    var alive: [CoreKit.Transaction] = []
    for chunk in distinct(ids).chunked(by: chunkSize) {
      alive += try CoreKit.Transaction
        .filter(chunk.map(\.uuidString).contains(Column("id")))
        .filter(Column("deleted_at") == nil)
        .fetchAll(db)
    }
    var effects = DeletionEffects(deletedIds: alive.map(\.id))
    try mark(effects.deletedIds, deletedAt: instant, at: instant, db: db)

    // Everything asked for is marked first: a reimbursement deleted in the same batch no
    // longer keeps a part closed.
    for reimbursement in alive where reimbursement.kind == .reimbursement {
      let companions = try String.fetchAll(
        db,
        sql: """
          SELECT id FROM transactions
          WHERE deleted_at IS NULL AND substr(external_id, 1, ?) = ?
          """,
        arguments: prefixArguments(of: reimbursement.id)
      ).compactMap(UUID.init(uuidString:))
      try mark(companions, deletedAt: instant, at: instant, db: db)
      effects.companionIds += companions

      let reopened = try String.fetchAll(
        db,
        sql: """
          SELECT p.id FROM transaction_parts p
          WHERE p.reimbursement_status = ?
            AND p.id IN (SELECT part_id FROM reimbursement_links WHERE reimbursement_tx_id = ?)
            AND NOT EXISTS (
              SELECT 1 FROM reimbursement_links l
              JOIN transactions t ON t.id = l.reimbursement_tx_id
              WHERE l.part_id = p.id AND t.deleted_at IS NULL)
          """,
        arguments: [ReimbursementStatus.returned.rawValue, reimbursement.id.uuidString]
      ).compactMap(UUID.init(uuidString:))
      try setStatus(.expected, of: reopened, onlyWhere: .returned, at: instant, db: db)
      effects.reopenedPartIds += reopened
    }

    let payments = alive.filter { $0.debtId != nil }.map(\.id.uuidString)
    for chunk in payments.chunked(by: chunkSize) {
      let request = DebtEntry.filter(chunk.contains(Column("transaction_id")))
      effects.removedDebtEntries += try request.fetchAll(db)
      try request.deleteAll(db)
    }

    try releaseScheduledLinks(of: alive, effects: &effects, db: db)
    return effects
  }

  /// A deleted «Mark as paid» operation pays nothing: its due date is owed again. The key
  /// `sched:<payment>:<due>` is cleared, so the date can be paid anew (the unique index
  /// counts deleted rows too), and the payment's `next_date` goes back to that date when it
  /// was the latest one paid (`ScheduledRules.reopened`).
  ///
  /// The key `transfer:<transfer>:fee` of a deleted fee is cleared the same way, so the
  /// transfer can be given a fee again.
  private static func releaseScheduledLinks(
    of deleted: [CoreKit.Transaction], effects: inout DeletionEffects, db: Database
  ) throws {
    var paid: [(transaction: CoreKit.Transaction, key: String, payment: UUID, due: DateOnly)] = []
    for transaction in deleted {
      guard let key = transaction.externalId else { continue }
      switch OperationLink(externalId: key) {
      case .scheduled(let paymentId, let due):
        paid.append((transaction, key, paymentId, due))
      case .transferFee:
        try db.execute(
          sql: "UPDATE transactions SET external_id = NULL WHERE id = ?",
          arguments: [transaction.id.uuidString])
        effects.releasedExternalIds[transaction.id] = key
      default:
        continue
      }
    }
    // The latest date first: each one goes back only from the date right after it.
    paid.sort { $0.due > $1.due }
    for (transaction, key, paymentId, due) in paid {
      try db.execute(
        sql: "UPDATE transactions SET external_id = NULL WHERE id = ?",
        arguments: [transaction.id.uuidString])
      effects.releasedExternalIds[transaction.id] = key
      guard let payment = try ScheduledPayment.fetchOne(db, key: paymentId.uuidString),
        let reopened = ScheduledRules.reopened(payment, due: due)
      else { continue }
      try reopened.update(db)
      effects.reopenedPayments.append(payment)
    }
  }

  static func restore(
    ids: [UUID], at instant: Date, effects: DeletionEffects, db: Database
  ) throws {
    try mark(distinct(ids + effects.companionIds), deletedAt: nil, at: instant, db: db)
    try setStatus(
      .returned, of: effects.reopenedPartIds, onlyWhere: .expected, at: instant, db: db)
    for entry in effects.removedDebtEntries {
      // A debt deleted in the meantime took its journal with it; there is nothing to put
      // the movement back on.
      guard try Debt.exists(db, key: entry.debtId.uuidString) else { continue }
      try entry.save(db)
    }
    // The keys come back unless the due date was paid anew in the meantime: then the
    // restored operation stays an ordinary expense rather than a second payment of it. The
    // app never gets here with the date paid anew — paying it is a step of ⌘Z above the
    // deletion, taken back first (PlanningFlowTests) — so this is a caller's fallback only.
    let released = effects.releasedExternalIds.sorted { $0.key.uuidString < $1.key.uuidString }
    for (id, key) in released {
      try db.execute(
        sql: "UPDATE OR IGNORE transactions SET external_id = ? WHERE id = ?",
        arguments: [key, id.uuidString])
    }
    // A payment moves forward again only while it still waits on the date it went back to;
    // the earliest date went back last, so it goes forward first.
    let keys = Set(effects.releasedExternalIds.values)
    for payment in effects.reopenedPayments.reversed() {
      guard var current = try ScheduledPayment.fetchOne(db, key: payment.id.uuidString),
        let due = current.nextDate,
        keys.contains(OperationLink.scheduled(paymentId: payment.id, due: due).externalId)
      else { continue }
      current.nextDate = payment.nextDate
      try current.update(db)
    }
  }

  // MARK: Helpers

  static func distinct(_ ids: [UUID]) -> [UUID] {
    var seen = Set<UUID>()
    return ids.filter { seen.insert($0).inserted }
  }

  /// Sets or clears `deleted_at`; either way the row was updated at `instant`.
  private static func mark(
    _ ids: [UUID], deletedAt: Date?, at instant: Date, db: Database
  ) throws {
    for chunk in ids.map(\.uuidString).chunked(by: chunkSize) {
      let marks = databaseQuestionMarks(count: chunk.count)
      try db.execute(
        sql: "UPDATE transactions SET deleted_at = ?, updated_at = ? WHERE id IN (\(marks))",
        arguments: StatementArguments([deletedAt, instant] as [(any DatabaseValueConvertible)?])
          + StatementArguments(chunk))
    }
  }

  /// Moves the status of the parts that still have `current`, and stamps their operations
  /// as updated at `instant`.
  private static func setStatus(
    _ status: ReimbursementStatus, of partIds: [UUID], onlyWhere current: ReimbursementStatus,
    at instant: Date, db: Database
  ) throws {
    try stampOperations(ofParts: partIds, whereStatus: current, at: instant, db: db)
    for chunk in partIds.map(\.uuidString).chunked(by: chunkSize) {
      let marks = databaseQuestionMarks(count: chunk.count)
      try db.execute(
        sql: """
          UPDATE transaction_parts SET reimbursement_status = ?
          WHERE reimbursement_status = ? AND id IN (\(marks))
          """,
        arguments: StatementArguments([status.rawValue, current.rawValue])
          + StatementArguments(chunk))
    }
  }

  static func prefixArguments(of reimbursementId: UUID) -> StatementArguments {
    let prefix = ReimbursementCompanions.keyPrefix(of: reimbursementId)
    return [prefix.count, prefix]
  }

  /// Writes a changed operation over the row it was made from. When the parts are the same
  /// ones, only the parts that changed are touched; otherwise they are brought in line the
  /// way `save` does it, which keeps the links of the parts that stay.
  static func write(
    _ entry: TransactionEntry, over previous: TransactionEntry, db: Database
  ) throws {
    try entry.transaction.update(db)
    let old = Dictionary(
      previous.parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    guard Set(entry.parts.map(\.id)) == Set(old.keys) else {
      try replaceParts(of: entry, db: db)
      return
    }
    for part in entry.parts where old[part.id] != part {
      try part.update(db)
    }
  }
}
