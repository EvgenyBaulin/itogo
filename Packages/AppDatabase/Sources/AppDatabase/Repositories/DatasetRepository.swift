import AppCore
import CoreKit
import Foundation
import GRDB

/// Reads everything the numbers of Overview, Analytics and Reports are made of — the
/// core's `Dataset` — in one go.
public struct DatasetRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// One snapshot of the whole history and of every reference book.
  ///
  /// - One read transaction. In WAL mode it sees the database as it was when it began, so
  ///   an operation never points at a category, a debt or a link the same snapshot lacks —
  ///   separate reads through the repositories could each see a different moment.
  /// - Cancellable. Cancelling the calling task interrupts SQLite (`sqlite3_interrupt`)
  ///   and the call throws `CancellationError`: a new ⌘R never waits for the old load to
  ///   finish. The work runs on a reader queue of GRDB, not on the Swift concurrency pool.
  /// - Deleted operations are left out. The ledger would skip them, and so would the
  ///   history of manual ratings; a link to a deleted operation finds nothing alive to
  ///   count, exactly as after `Dataset.removing`. Links are all read — whether one counts
  ///   is the ledger's rule, not the loader's.
  /// - Reference books come with their archived rows and debts with the closed ones:
  ///   archiving or closing must not change past months.
  /// - The planning book comes in the same read: scheduled payments, prices, expected income
  ///   and its links, limits, reconciliations oldest first with the balances they counted,
  ///   the journals of every debt and the planning settings (`PlanningRepository.book`).
  /// - So do the transfers between accounts, oldest first, the groups of the accounts in the
  ///   owner's order, and the settings of the accounts.
  ///
  /// `version` is the caller's mark for the snapshot (the pipeline's count of writes taken
  /// before the read), so a result can be told apart from one built on older data.
  public func load(version: Int) async throws -> Dataset {
    try await writer.read { db in
      try Self.dataset(db, version: version)
    }
  }

  /// The body of `load`, inside a read the caller already holds.
  static func dataset(_ db: Database, version: Int) throws -> Dataset {
    // The parts come through a join, never through a list of bound ids: no history is too
    // long for it. `CROSS JOIN` keeps the parts as the outer loop, so SQLite reads them in
    // one pass in the order they were written instead of searching its index once per
    // operation — about a third of the time on the large set. Stepping the cursors is where
    // SQLite notices an interruption; the checks in between stop the work outside it.
    let transactions = try CoreKit.Transaction.fetchAll(
      db, sql: "SELECT * FROM transactions WHERE deleted_at IS NULL ORDER BY occurred_at")
    try Task.checkCancellation()
    let entries = try TransactionRepository.attachParts(
      to: transactions,
      selectedBy: """
        SELECT p.* FROM transaction_parts p
        CROSS JOIN transactions t ON t.id = p.transaction_id
        WHERE t.deleted_at IS NULL
        ORDER BY p.rowid
        """,
      db: db)
    try Task.checkCancellation()
    let links = try ReimbursementLink.order(Column.rowID).fetchAll(db)
    let categories = try CoreKit.Category.order(Column("sort"), Column("name")).fetchAll(db)
    let people = try Person.order(Column("name")).fetchAll(db)
    let places = try Place.order(Column("name")).fetchAll(db)
    let events = try Event.order(Column("name")).fetchAll(db)
    let paymentMethods = try PaymentMethod.order(Column("name")).fetchAll(db)
    let debts = try Debt.order(Column("name")).fetchAll(db)
    let goals = try Goal.order(Column("name")).fetchAll(db)
    let cashback = try String.fetchOne(
      db, sql: "SELECT value FROM settings WHERE key = ?",
      arguments: [AnalyticsSettings.cashbackCategoryKey])
    let sensitivity = try String.fetchOne(
      db, sql: "SELECT value FROM settings WHERE key = ?",
      arguments: [AnalyticsSettings.anomalySensitivityKey])
    let dismissals = try AnomalyRepository.all(db)
    let feedback = try ModelRepository.feedback(db)
    let planning = try PlanningRepository.book(db)
    let transfers = try Transfer.order(Column("occurred_at"), Column.rowID).fetchAll(db)
    let groups = try AccountGroup.order(Column("sort"), Column("name")).fetchAll(db)
    let accountSettings = AccountSettings(
      storedValues: try SettingsRepository.values(of: AccountSettings.storageKeys, db: db))
    try Task.checkCancellation()
    return Dataset(
      entries: entries,
      links: links,
      categories: categories,
      people: people,
      places: places,
      events: events,
      paymentMethods: paymentMethods,
      debts: debts,
      goals: goals,
      planning: planning,
      dismissals: dismissals,
      feedback: feedback,
      settings: AnalyticsSettings(
        cashbackCategoryId: cashback.flatMap(UUID.init(uuidString:)),
        anomalySensitivity: sensitivity.flatMap(AnomalySensitivity.init(rawValue:)) ?? .standard),
      transfers: transfers,
      accountGroups: groups,
      accountSettings: accountSettings,
      version: version)
  }
}
