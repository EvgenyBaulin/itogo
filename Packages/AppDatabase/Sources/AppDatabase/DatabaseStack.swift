import CoreKit
import Foundation
import GRDB

/// Opens the database, applies the SQL migrations and hands out repositories.
/// Debug builds work in their own directory so synthetic data can never reach the real
/// database.
public final class DatabaseStack: Sendable {
  public let writer: any DatabaseWriter
  public let url: URL
  /// What opening this stack did to the schema, for the journal: which migrations were
  /// applied this time and how long they took. The package writes no log of its own — it
  /// says what happened and the app records it.
  public let applied: Migrations

  public struct Migrations: Sendable, Equatable {
    /// How many migrations the schema has in all — the version of the schema, in effect.
    public var onDisk: Int
    /// How many of them this open had to apply.
    public var applied: Int
    public var milliseconds: Int

    public init(onDisk: Int = 0, applied: Int = 0, milliseconds: Int = 0) {
      self.onDisk = onDisk
      self.applied = applied
      self.milliseconds = milliseconds
    }
  }

  /// A migration that stopped: the version the file was at, the version it was going to, the
  /// migration that stopped and how long the attempt ran — what `Migrations` says of an open
  /// that migrated. `underlying` is what stopped it, and what the app judges the failure by.
  /// The migrations before the failed one stay applied: GRDB runs each in a transaction of
  /// its own.
  public struct MigrationFailure: Error {
    public var from: Int
    public var to: Int
    /// The identifier of the migration that stopped: the file name in `Schema/`.
    public var migration: String?
    public var milliseconds: Int
    public var underlying: any Error

    public init(
      from: Int, to: Int, migration: String?, milliseconds: Int, underlying: any Error
    ) {
      self.from = from
      self.to = to
      self.migration = migration
      self.milliseconds = milliseconds
      self.underlying = underlying
    }
  }

  public init(url: URL, schema: any SchemaSource) throws {
    self.url = url
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    var configuration = Configuration()
    // This, and not the `PRAGMA foreign_keys = ON` in `Schema/0001`, is what turns the keys
    // on: a migration runs inside a transaction, where SQLite ignores that pragma. Every
    // connection that writes these tables has to set it itself.
    configuration.foreignKeysEnabled = true
    // `busyMode` stays GRDB's `.immediateError`, on purpose. Every write of the app goes
    // through this pool's one writer, which GRDB serialises, so the app never finds its own
    // file locked; only another process can — a second copy started with `open -n`, a
    // `sqlite3` writing by hand. The app writes from the main thread, and a busy timeout would
    // freeze the window for as long as that process holds the lock; failing at once shows
    // «не сохранено» and loses nothing that was saved.
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA journal_mode = WAL")
      // A sync on macOS stops at the drive's own cache unless it asks for F_FULLFSYNC;
      // a power-off by the button empties that cache. Checkpoints use it too.
      try db.execute(sql: "PRAGMA fullfsync = ON")
    }

    let pool = try DatabasePool(path: url.path, configuration: configuration)
    // GRDB turns WAL on after `prepareDatabase` and sets the writer to NORMAL, which syncs
    // the log only at a checkpoint: a commit that returned could still be lost to a kernel
    // panic or a power loss. FULL syncs it at every commit — about a millisecond and a half
    // on this Mac's disk, for writes a person makes one at a time.
    try pool.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA synchronous = FULL")
    }
    self.writer = pool
    self.applied = try Self.migrate(pool, schema: schema)
  }

  /// In-memory stack for tests.
  public init(inMemory schema: any SchemaSource) throws {
    self.url = URL(fileURLWithPath: ":memory:")
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let queue = try DatabaseQueue(configuration: configuration)
    self.writer = queue
    self.applied = try Self.migrate(queue, schema: schema)
  }

  /// Closes every connection. Reads and the write in flight finish first — GRDB waits for
  /// them — so nothing is left holding the file when its folder goes. Throws when
  /// a statement is still alive, which the caller logs rather than hides.
  public func close() throws {
    try writer.close()
  }

  /// Every file in `Schema/` is one migration, applied in file-name order. Returns what it
  /// had to do, so the app can write it in the journal.
  private static func migrate(
    _ writer: any DatabaseWriter, schema: any SchemaSource
  ) throws -> Migrations {
    let migrations = try schema.migrations()
    try refuseUnknownMigrations(writer, onDisk: migrations.map(\.name))
    var migrator = DatabaseMigrator()
    for migration in migrations {
      migrator.registerMigration(migration.name) { db in
        try db.execute(sql: migration.sql)
      }
    }
    let alreadyApplied = (try? writer.read { try migrator.appliedIdentifiers($0) }) ?? []
    let began = DispatchTime.now().uptimeNanoseconds
    do {
      try migrator.migrate(writer)
    } catch {
      // Each migration commits on its own and they run in order, so the first one still not
      // applied is the one that stopped.
      let appliedNow =
        (try? writer.read { try migrator.appliedIdentifiers($0) }) ?? alreadyApplied
      throw MigrationFailure(
        from: alreadyApplied.count, to: migrations.count,
        migration: migrations.first { !appliedNow.contains($0.name) }?.name,
        milliseconds: Int((DispatchTime.now().uptimeNanoseconds - began) / 1_000_000),
        underlying: error)
    }
    let elapsed = Int((DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
    return Migrations(
      onDisk: migrations.count,
      applied: migrations.filter { !alreadyApplied.contains($0.name) }.count,
      milliseconds: elapsed)
  }

  /// Refuses a database that was migrated by a build whose migrations we do not have.
  /// Writing into a schema we cannot see is how the owner's data gets lost: an older app,
  /// or one whose `Schema/` file was renamed, has to stop instead.
  private static func refuseUnknownMigrations(
    _ writer: any DatabaseWriter, onDisk: [String]
  ) throws {
    let applied = try writer.read { db -> [String] in
      guard try db.tableExists("grdb_migrations") else { return [] }
      return try String.fetchAll(
        db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }
    let known = Set(onDisk)
    guard applied.allSatisfy(known.contains) else {
      throw DatabaseError.migrationMismatch(applied: applied, onDisk: onDisk)
    }
  }

  // MARK: Changes

  /// The tables a `Dataset` is read from (`DatasetRepository.load`) — the planning book
  /// included, whose tables change with every «Mark as paid», limit and reconciliation — plus
  /// the rates, whose refinement rewrites the rubles of operations. The debt journals are part
  /// of the book: they move with every debt payment and hold the balances the debt figures
  /// are made of. The anomalies waved away come with the data too, so «Это нормально» is a
  /// change like any other, whoever writes it; so do the owner's choices of a category
  /// against the model, which «Качество модели» counts. A test holds this
  /// list against the statements the load runs.
  static let ledgerTables = [
    "transactions", "transaction_parts", "reimbursement_links", "categories", "people",
    "places", "events", "payment_methods", "goals", "debts", "debt_entries", "rates",
    "settings", "scheduled_payments", "subscription_prices", "expected_income",
    "expected_income_links", "budgets", "reconciliations", "anomaly_dismissals",
    "category_feedback",
  ]

  /// One element after every committed transaction that changed one of `ledgerTables` —
  /// whoever wrote it: the store, a sheet writing a part off, a merge of duplicates, the
  /// rate step. The elements carry nothing; the consumer reads what it needs.
  ///
  /// Threading. GRDB calls `onChange` on the writer's dispatch queue, inside the commit,
  /// before the writing call has returned — and the app writes synchronously from the main
  /// thread. So the callback does nothing but `yield`, which never blocks: a hop to the
  /// main thread from there would wait for the main thread while the main thread waits for
  /// the write — a deadlock — and any work there would stall every write. The buffer keeps
  /// only the newest element: ten writes in a row while the consumer is busy come out as
  /// one, and the consumer debounces anyway.
  ///
  /// The observation starts right away and blocks the calling thread until it can get
  /// write access. It stops when the stream terminates — the consuming task is cancelled or
  /// the stream is released.
  public func ledgerChanges() -> AsyncStream<Void> {
    ledgerChanges(onChange: {})
  }

  /// `ledgerChanges()` with a callback run inside every commit the observation sees, right
  /// before the element is yielded. It shows whether the observation itself is still
  /// registered: a yield on a finished stream is silently dropped, so the stream alone cannot
  /// tell a stopped observation from one left behind on the writer. The tests use it. Like
  /// the yield, the callback must never block.
  func ledgerChanges(onChange: @escaping @Sendable () -> Void) -> AsyncStream<Void> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
      let observation = DatabaseRegionObservation(
        tracking: Self.ledgerTables.map { Table($0) })
      let cancellable = observation.start(
        in: writer,
        onError: { _ in continuation.finish() },
        onChange: { _ in
          onChange()
          continuation.yield()
        })
      continuation.onTermination = { _ in cancellable.cancel() }
    }
  }

  /// Names of the migrations recorded in the database, in application order.
  public func appliedMigrations() throws -> [String] {
    try writer.read { db in
      try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }
  }

  /// Consistent snapshot for backups and for the transfer archive.
  public func backup(to destination: URL) throws {
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    // An SQLite database is up to three files. Anyone who opens a snapshot to look at it
    // leaves a write-ahead log beside it, and that log belongs to the snapshot that used
    // to be there: replacing the main file alone either resurrects the old contents or
    // makes the new copy unreadable.
    for path in Self.databaseFiles(of: destination)
    where FileManager.default.fileExists(atPath: path) {
      try FileManager.default.removeItem(atPath: path)
    }
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    let target = try DatabaseQueue(path: destination.path, configuration: configuration)
    try writer.backup(to: target)
  }

  /// A consistent snapshot of a database file this build did not open as its own — one written
  /// by a newer build, one a migration failed on. Nothing is applied to it and nothing is
  /// written into it: it is read as it is, through the backup API, log included, so the copy
  /// is the state the owner had. Throws when SQLite cannot read the file at all.
  public static func backup(fileAt source: URL, to destination: URL) throws {
    guard FileManager.default.fileExists(atPath: source.path) else {
      throw DatabaseError.notFound
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    for path in Self.databaseFiles(of: destination)
    where FileManager.default.fileExists(atPath: path) {
      try FileManager.default.removeItem(atPath: path)
    }
    // Not read-only: a database in WAL mode needs its `-shm`, which a read-only connection
    // cannot make. `query_only` keeps it from writing instead (see `integrityCheckPassed(at:)`).
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA query_only = ON")
    }
    let queue = try DatabaseQueue(path: source.path, configuration: configuration)
    defer { try? queue.close() }
    let target = try DatabaseQueue(path: destination.path)
    defer { try? target.close() }
    try queue.backup(to: target)
  }

  /// The database file together with the journals SQLite keeps next to it.
  static func databaseFiles(of url: URL) -> [String] {
    [url.path, url.path + "-wal", url.path + "-shm", url.path + "-journal"]
  }

  /// Integrity check of the live database, for the problem report and for telling a damaged
  /// database from a damaged copy of a sound one.
  public func integrityCheckPassed() throws -> Bool {
    try writer.read { db in
      let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
      return result == "ok"
    }
  }

  /// Integrity check of a database file nobody has open: a copy just written, or one about to
  /// take the place of the live database. It has to have tables — an empty file opens as an
  /// empty database, which `PRAGMA integrity_check` calls «ok».
  public static func integrityCheckPassed(at url: URL) -> Bool {
    inspect(fileAt: url, isSound) ?? false
  }

  /// What a database file nobody has open would be to this build, were it put in the place of
  /// the live one: a copy about to be restored, the database of an archive about to be
  /// imported.
  public enum FileCheck: Sendable, Equatable {
    /// It opens, has tables, passes `PRAGMA integrity_check`, and every migration it records
    /// is one this build has.
    case sound
    /// Not a database, empty, or it fails its integrity check.
    case damaged
    /// It records migrations this build does not have: a newer build wrote it. Opening it
    /// would be refused (`refuseUnknownMigrations`).
    case newerSchema
  }

  /// Checks a file before it replaces the live database, by the same rules the opening of the
  /// database will apply. The integrity check alone lets through a sound database of a newer
  /// build, which this build refuses to open — at the next launch, after the database it
  /// replaced is gone. Throws only when the schema of this build cannot be read.
  public static func check(fileAt url: URL, schema: any SchemaSource) throws -> FileCheck {
    let known = Set(try schema.migrations().map(\.name))
    let verdict = inspect(fileAt: url) { db -> FileCheck in
      guard try isSound(db) else { return .damaged }
      guard try db.tableExists("grdb_migrations") else { return .sound }
      let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
      return applied.allSatisfy(known.contains) ? .sound : .newerSchema
    }
    return verdict ?? .damaged
  }

  private static func isSound(_ db: Database) throws -> Bool {
    let tables = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master") ?? 0
    let result = try String.fetchOne(db, sql: "PRAGMA integrity_check")
    return tables > 0 && result == "ok"
  }

  /// Reads a database file nobody has open; nil when it does not open or the reading throws.
  ///
  /// The connection is not opened read-only: a copy of a database in WAL mode is in WAL mode
  /// too, and a read-only connection cannot make the `-shm` it needs, so it would call every
  /// good copy unreadable. It is kept from writing by `query_only` instead. The folder is left
  /// as it was found: a `-wal` or `-shm` the check made is removed, so no log is left for the
  /// next file of that name to read as its own.
  private static func inspect<T>(
    fileAt url: URL, _ read: (Database) throws -> T
  ) -> T? {
    let manager = FileManager.default
    guard manager.fileExists(atPath: url.path) else { return nil }
    let beside = [url.path + "-wal", url.path + "-shm"]
    let there = beside.filter { manager.fileExists(atPath: $0) }
    defer {
      for path in beside where !there.contains(path) {
        try? manager.removeItem(atPath: path)
      }
    }
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA query_only = ON")
    }
    guard let queue = try? DatabaseQueue(path: url.path, configuration: configuration) else {
      return nil
    }
    defer { try? queue.close() }
    return try? queue.read(read)
  }
}
