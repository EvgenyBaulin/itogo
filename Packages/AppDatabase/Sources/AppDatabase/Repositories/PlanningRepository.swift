import AppCore
import CoreKit
import Foundation
import GRDB

/// Rows of the tables an action of the planning writes, one list per table. The reference
/// books are here because the planning makes rows of them too: the subcategory of a new goal,
/// of a new debt.
public struct PlanningRows: Sendable, Hashable {
  public var categories: [CoreKit.Category]
  public var events: [Event]
  public var goals: [Goal]
  public var debts: [Debt]
  public var scheduled: [ScheduledPayment]
  public var prices: [SubscriptionPrice]
  public var expected: [ExpectedIncome]
  public var expectedLinks: [ExpectedIncomeLink]
  public var budgets: [Budget]
  public var debtEntries: [DebtEntry]
  public var reconciliations: [Reconciliation]

  public init(
    categories: [CoreKit.Category] = [], events: [Event] = [], goals: [Goal] = [],
    debts: [Debt] = [], scheduled: [ScheduledPayment] = [], prices: [SubscriptionPrice] = [],
    expected: [ExpectedIncome] = [], expectedLinks: [ExpectedIncomeLink] = [],
    budgets: [Budget] = [], debtEntries: [DebtEntry] = [], reconciliations: [Reconciliation] = []
  ) {
    self.categories = categories
    self.events = events
    self.goals = goals
    self.debts = debts
    self.scheduled = scheduled
    self.prices = prices
    self.expected = expected
    self.expectedLinks = expectedLinks
    self.budgets = budgets
    self.debtEntries = debtEntries
    self.reconciliations = reconciliations
  }

  public static let empty = PlanningRows()
}

/// Ids of rows of the same tables as `PlanningRows`, one list per table.
public struct PlanningRowIDs: Sendable, Hashable {
  public var categories: [UUID]
  public var events: [UUID]
  public var goals: [UUID]
  public var debts: [UUID]
  public var scheduled: [UUID]
  public var prices: [UUID]
  public var expected: [UUID]
  public var expectedLinks: [UUID]
  public var budgets: [UUID]
  public var debtEntries: [UUID]
  public var reconciliations: [UUID]

  public init(
    categories: [UUID] = [], events: [UUID] = [], goals: [UUID] = [], debts: [UUID] = [],
    scheduled: [UUID] = [], prices: [UUID] = [], expected: [UUID] = [],
    expectedLinks: [UUID] = [], budgets: [UUID] = [], debtEntries: [UUID] = [],
    reconciliations: [UUID] = []
  ) {
    self.categories = categories
    self.events = events
    self.goals = goals
    self.debts = debts
    self.scheduled = scheduled
    self.prices = prices
    self.expected = expected
    self.expectedLinks = expectedLinks
    self.budgets = budgets
    self.debtEntries = debtEntries
    self.reconciliations = reconciliations
  }

  public static let empty = PlanningRowIDs()
}

/// One action of the planning, written whole or not at all: «Mark as paid»,
/// a contribution to a goal, a reconciliation, a debt payment, or an edit of a definition.
public struct PlanningChange: Sendable, Hashable {
  /// New operations with their parts.
  public var created: [TransactionEntry]
  /// Rows written over the row with the same id, or added when there is none.
  public var upsert: PlanningRows
  public var delete: PlanningRowIDs
  /// Keys of `settings` to set; a key whose value is `nil` is deleted. A dictionary drops a
  /// key assigned `nil`, so a deletion goes in as `.some(nil)` or through `updateValue`.
  public var settings: [String: String?]

  public init(
    created: [TransactionEntry] = [], upsert: PlanningRows = .empty,
    delete: PlanningRowIDs = .empty, settings: [String: String?] = [:]
  ) {
    self.created = created
    self.upsert = upsert
    self.delete = delete
    self.settings = settings
  }
}

/// Everything `revert` needs to take a `PlanningChange` back: one step of ⌘Z.
public struct PlanningUndo: Sendable, Hashable {
  public var createdTransactionIds: [UUID]
  /// Rows the change added.
  public var inserted: PlanningRowIDs
  /// Every row the change wrote over or removed — the rows a deletion cascaded to or cleared
  /// included — as it was before.
  public var before: PlanningRows
  /// The values the change's keys had; `nil` — the key was not there.
  public var settingsBefore: [String: String?]
  /// The rowid each row of `before` had, by id: lists read in rowid order — the limits, the
  /// lines of one day of a journal — get a removed row back in its place, not last.
  public var rowIDs: [UUID: Int64]
  /// Links to a deleted category the schema cleared in tables the planning does not write —
  /// templates, import mappings, the model's corrections — set back once the category is.
  public var cleared: [ClearedReference]

  public init(
    createdTransactionIds: [UUID] = [], inserted: PlanningRowIDs = .empty,
    before: PlanningRows = .empty, settingsBefore: [String: String?] = [:],
    rowIDs: [UUID: Int64] = [:], cleared: [ClearedReference] = []
  ) {
    self.createdTransactionIds = createdTransactionIds
    self.inserted = inserted
    self.before = before
    self.settingsBefore = settingsBefore
    self.rowIDs = rowIDs
    self.cleared = cleared
  }
}

/// One link a category deletion cleared (`ON DELETE SET NULL`) in a row the planning does not
/// otherwise write: `column` of the row `rowId` of `table` pointed at `categoryId`.
public struct ClearedReference: Sendable, Hashable {
  public let table: String
  public let column: String
  public let rowId: String
  public let categoryId: UUID
}

public enum PlanningWriteError: Error, Equatable, Sendable {
  /// An event, a goal or a debt that operations point at is archived or closed, never
  /// deleted (the schema's rule). Deleting it would quietly clear the operations' references
  /// — a contribution would stop counting towards its goal — and undo could not put them
  /// back, since operations are not rows of the planning.
  case referencedByOperations(UUID)
}

/// The one write path of the planning, so every action is one transaction and one step of
/// undo, plus the reads the planning screens need.
public struct PlanningRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  // MARK: Writing

  /// Writes the change in one transaction and returns how to take it back.
  ///
  /// Each row is read right before it is first written or deleted: a row that is there goes
  /// to `before`, a new one to `inserted`. A deletion also reads the rows of the planning the
  /// schema cascades it to or clears — the prices of a payment, the links of an expected
  /// income, the journal of a debt, the limits and definitions filed under a category — so
  /// undo gives them back as well.
  ///
  /// Rows go in the order their foreign keys need: categories (parents first), events, goals,
  /// debts, scheduled payments, prices, expected income, limits, then the operations with
  /// their parts, and after them the debt journal, the income links and the reconciliations,
  /// which may point at those operations. Deletions come last, in the reverse order, and the
  /// settings after everything.
  ///
  /// Throws `DatabaseError.unbalancedParts` before writing anything when an operation does
  /// not add up, and `PlanningWriteError.referencedByOperations` when an event, a goal or a
  /// debt to delete has operations. Any failure rolls the whole change back — among them the
  /// unique `external_id`, which keeps one due date from being paid twice.
  public func apply(_ change: PlanningChange) throws -> PlanningUndo {
    guard change.created.allSatisfy(\.isBalanced) else { throw DatabaseError.unbalancedParts }
    return try writer.write { db in
      var journal = UndoJournal()
      let rows = change.upsert
      try journal.upsert(Self.parentsFirst(rows.categories), db: db)
      try journal.upsert(rows.events, db: db)
      try journal.upsert(rows.goals, db: db)
      try journal.upsert(rows.debts, db: db)
      try journal.upsert(rows.scheduled, db: db)
      try journal.upsert(rows.prices, db: db)
      try journal.upsert(rows.expected, db: db)
      try journal.upsert(rows.budgets, db: db)
      // New operations are written the way `TransactionRepository.insert` writes them: as new
      // rows, so an id or an `external_id` that is already there fails the change.
      for entry in change.created {
        try entry.transaction.insert(db)
        for part in entry.parts { try part.insert(db) }
      }
      try journal.upsert(rows.debtEntries, db: db)
      try journal.upsert(rows.expectedLinks, db: db)
      try journal.upsert(rows.reconciliations, db: db)

      let gone = change.delete
      try journal.delete(Reconciliation.self, ids: gone.reconciliations, db: db)
      try journal.delete(ExpectedIncomeLink.self, ids: gone.expectedLinks, db: db)
      try journal.delete(DebtEntry.self, ids: gone.debtEntries, db: db)
      try journal.delete(Budget.self, ids: gone.budgets, db: db)
      try journal.delete(ExpectedIncome.self, ids: gone.expected, db: db)
      try journal.delete(SubscriptionPrice.self, ids: gone.prices, db: db)
      try journal.delete(ScheduledPayment.self, ids: gone.scheduled, db: db)
      try journal.delete(Debt.self, ids: gone.debts, db: db)
      try journal.delete(Goal.self, ids: gone.goals, db: db)
      try journal.delete(Event.self, ids: gone.events, db: db)
      try journal.delete(
        CoreKit.Category.self, ids: Self.childrenFirst(gone.categories, db: db), db: db)

      var settingsBefore: [String: String?] = [:]
      for (key, value) in change.settings.sorted(by: { $0.key < $1.key }) {
        settingsBefore.updateValue(try Self.setting(key, db: db), forKey: key)
        try Self.setSetting(key, to: value, db: db)
      }
      return PlanningUndo(
        createdTransactionIds: change.created.map(\.id), inserted: journal.inserted,
        before: journal.before, settingsBefore: settingsBefore, rowIDs: journal.rowIDs,
        cleared: journal.cleared)
    }
  }

  /// Takes a change back in one transaction.
  ///
  /// The operations it created go for good, with the journal lines and income links that
  /// point at them — deleted first, as `TransactionRepository.purge` does, since the foreign
  /// key would only clear a line's `transaction_id` and leave the debt moved by a payment
  /// that never happened. Then the rows it added go, in the reverse order of the foreign
  /// keys, and the rows it changed or removed are written back as they were, in the forward
  /// order, each at the rowid it had (`PlanningUndo.rowIDs`). The settings come last.
  ///
  /// A row changed elsewhere between the change and its undo is written back all the same.
  /// An operation made since that points at a row the change added — filed
  /// under a goal's new subcategory, tagged with a new event — makes the undo fail and roll
  /// back (`PlanningWriteError.referencedByOperations`, or the schema's `RESTRICT`).
  public func revert(_ undo: PlanningUndo) throws {
    try writer.write { db in
      for chunk in undo.createdTransactionIds.map(\.uuidString)
        .chunked(by: TransactionRepository.chunkSize)
      {
        let ids = StatementArguments(Array(chunk))
        let marks = databaseQuestionMarks(count: chunk.count)
        try db.execute(
          sql: "DELETE FROM debt_entries WHERE transaction_id IN (\(marks))", arguments: ids)
        try db.execute(
          sql: "DELETE FROM expected_income_links WHERE transaction_id IN (\(marks))",
          arguments: ids)
        try db.execute(sql: "DELETE FROM transactions WHERE id IN (\(marks))", arguments: ids)
      }

      let added = undo.inserted
      try Self.deleteAll(Reconciliation.self, ids: added.reconciliations, db: db)
      try Self.deleteAll(ExpectedIncomeLink.self, ids: added.expectedLinks, db: db)
      try Self.deleteAll(DebtEntry.self, ids: added.debtEntries, db: db)
      try Self.deleteAll(Budget.self, ids: added.budgets, db: db)
      try Self.deleteAll(ExpectedIncome.self, ids: added.expected, db: db)
      try Self.deleteAll(SubscriptionPrice.self, ids: added.prices, db: db)
      try Self.deleteAll(ScheduledPayment.self, ids: added.scheduled, db: db)
      try Self.deleteAll(Debt.self, ids: added.debts, db: db)
      try Self.deleteAll(Goal.self, ids: added.goals, db: db)
      try Self.deleteAll(Event.self, ids: added.events, db: db)
      for id in try Self.childrenFirst(added.categories, db: db) {
        _ = try CoreKit.Category.deleteOne(db, key: id.uuidString)
      }

      let before = undo.before
      for category in Self.parentsFirst(before.categories) { try category.save(db) }
      // Only where the link is still empty: the deletion did nothing else to these rows, and
      // a category given to one of them since is the owner's, not the deletion's.
      for reference in undo.cleared {
        try db.execute(
          sql: """
            UPDATE \(reference.table) SET \(reference.column) = ?
            WHERE id = ? AND \(reference.column) IS NULL
            """,
          arguments: [reference.categoryId.uuidString, reference.rowId])
      }
      for row in before.events { try row.save(db) }
      for row in before.goals { try row.save(db) }
      for row in before.debts { try row.save(db) }
      for row in before.scheduled { try row.save(db) }
      for row in before.prices { try row.save(db) }
      for row in before.expected { try row.save(db) }
      for row in before.budgets { try row.save(db) }
      for row in before.debtEntries { try row.save(db) }
      for row in before.expectedLinks { try row.save(db) }
      for row in before.reconciliations { try row.save(db) }
      try Self.restoreRowIDs(before.budgets, undo.rowIDs, db: db)
      try Self.restoreRowIDs(before.debtEntries, undo.rowIDs, db: db)
      try Self.restoreRowIDs(before.expectedLinks, undo.rowIDs, db: db)
      try Self.restoreRowIDs(before.prices, undo.rowIDs, db: db)
      try Self.restoreRowIDs(before.reconciliations, undo.rowIDs, db: db)
      try Self.restoreRowIDs(before.scheduled, undo.rowIDs, db: db)
      try Self.restoreRowIDs(before.expected, undo.rowIDs, db: db)

      for (key, value) in undo.settingsBefore.sorted(by: { $0.key < $1.key }) {
        try Self.setSetting(key, to: value, db: db)
      }
    }
  }

  /// Moves rows written back by `revert` to the rowid they had. `save` inserts a removed
  /// row at a new rowid, which would put it last in every list read in rowid order. A rowid
  /// another row took in the meantime is left alone (`OR IGNORE`): the row then stays last,
  /// which is all that happens.
  private static func restoreRowIDs<Record: PlanningRow>(
    _ rows: [Record], _ rowIDs: [UUID: Int64], db: Database
  ) throws {
    for row in rows {
      guard let rowID = rowIDs[row.id] else { continue }
      try db.execute(
        sql: """
          UPDATE OR IGNORE \(Record.databaseTableName) SET rowid = ?
          WHERE id = ? AND rowid <> ?
          """,
        arguments: [rowID, row.id.uuidString, rowID])
    }
  }

  // MARK: Reading

  public func scheduled() throws -> [ScheduledPayment] {
    try writer.read { db in try Self.scheduled(db) }
  }

  public func budgets() throws -> [Budget] {
    try writer.read { db in try Self.budgets(db) }
  }

  public func expected() throws -> [ExpectedIncome] {
    try writer.read { db in try Self.expected(db) }
  }

  /// Oldest first.
  public func reconciliations() throws -> [Reconciliation] {
    try writer.read { db in try ReconciliationRepository.all(db) }
  }

  /// The whole planning book in one read — what `DatasetRepository.load` puts in the dataset.
  public func book() throws -> PlanningBook {
    try writer.read { db in try Self.book(db) }
  }

  /// The planning book inside a read the caller already holds. Debt journals come for every
  /// debt, the closed ones included, like the debts themselves.
  static func book(_ db: Database) throws -> PlanningBook {
    PlanningBook(
      scheduled: try scheduled(db),
      prices: try prices(db),
      expected: try expected(db),
      expectedLinks: try ExpectedIncomeLink.order(Column.rowID).fetchAll(db),
      budgets: try budgets(db),
      reconciliations: try ReconciliationRepository.all(db),
      debtEntries: try debtEntries(db),
      settings: try settings(db))
  }

  /// Each payment's prices by day.
  private static func prices(_ db: Database) throws -> [SubscriptionPrice] {
    try SubscriptionPrice.order(Column("payment_id"), Column("date"), Column.rowID).fetchAll(db)
  }

  /// Each debt's journal by day, undated lines first (SQLite sorts NULL first), lines of one
  /// day in the order they were written.
  private static func debtEntries(_ db: Database) throws -> [DebtEntry] {
    try DebtEntry.order(Column("debt_id"), Column("date"), Column.rowID).fetchAll(db)
  }

  private static func scheduled(_ db: Database) throws -> [ScheduledPayment] {
    try ScheduledPayment.order(Column("name"), Column.rowID).fetchAll(db)
  }

  private static func expected(_ db: Database) throws -> [ExpectedIncome] {
    try ExpectedIncome.order(Column("name"), Column.rowID).fetchAll(db)
  }

  /// In the order they were made.
  private static func budgets(_ db: Database) throws -> [Budget] {
    try Budget.order(Column.rowID).fetchAll(db)
  }

  static func settings(_ db: Database) throws -> PlanningSettings {
    let keys = PlanningSettings.storageKeys
    let marks = databaseQuestionMarks(count: keys.count)
    let rows = try Row.fetchAll(
      db, sql: "SELECT key, value FROM settings WHERE key IN (\(marks))",
      arguments: StatementArguments(keys))
    var values: [String: String] = [:]
    for row in rows {
      values[row["key"]] = row["value"]
    }
    return PlanningSettings(storedValues: values)
  }

  // MARK: Helpers

  private static func setting(_ key: String, db: Database) throws -> String? {
    try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
  }

  private static func setSetting(_ key: String, to value: String?, db: Database) throws {
    if let value {
      try db.execute(
        sql: """
          INSERT INTO settings (key, value) VALUES (?, ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value
          """,
        arguments: [key, value])
    } else {
      try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
    }
  }

  /// Rows undo takes away, under the same refusal as a deletion of `apply`.
  private static func deleteAll<Record: PlanningRow>(
    _ type: Record.Type, ids: [UUID], db: Database
  ) throws {
    guard !ids.isEmpty else { return }
    for id in ids { try Record.refuseDeletion(of: id, db: db) }
    _ = try Record.deleteAll(db, keys: ids.map(\.uuidString))
  }

  /// The table refers to itself: a parent is written before its subcategories.
  private static func parentsFirst(_ categories: [CoreKit.Category]) -> [CoreKit.Category] {
    categories.filter { $0.parentId == nil } + categories.filter { $0.parentId != nil }
  }

  /// …and a subcategory is deleted before its parent, which it would otherwise hold on to
  /// (`ON DELETE RESTRICT`). Ids of categories that are not there are left out.
  private static func childrenFirst(_ ids: [UUID], db: Database) throws -> [UUID] {
    guard !ids.isEmpty else { return [] }
    let rows = try CoreKit.Category.fetchAll(db, keys: ids.map(\.uuidString))
    return rows.filter { $0.parentId != nil }.map(\.id)
      + rows.filter { $0.parentId == nil }.map(\.id)
  }
}

// MARK: - Undo journal

/// A row the planning writes and undo puts back: where its list lives in `PlanningRows` and
/// in `PlanningRowIDs`, and what deleting it does besides.
protocol PlanningRow: FetchableRecord, PersistableRecord, Identifiable where ID == UUID {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { get }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { get }

  /// Throws when the row may not be deleted — by `apply`, nor by `revert` taking back a row
  /// it added.
  static func refuseDeletion(of id: UUID, db: Database) throws

  /// Right before `apply` deletes a row: reads into the journal the rows of the planning
  /// the schema cascades the deletion to, or clears a reference of.
  static func keepDependents(of id: UUID, journal: inout UndoJournal, db: Database) throws
}

extension PlanningRow {
  static func refuseDeletion(of id: UUID, db: Database) throws {}
  static func keepDependents(of id: UUID, journal: inout UndoJournal, db: Database) throws {}
}

/// What `apply` has seen of the rows it touched. The first sight of a row is the one that
/// counts: that is the row as it was before the change, whatever the change did to it later.
struct UndoJournal {
  private(set) var before = PlanningRows.empty
  private(set) var inserted = PlanningRowIDs.empty
  /// The rowid of every row kept in `before`, read before it could go.
  private(set) var rowIDs: [UUID: Int64] = [:]
  /// Links a deletion clears in tables the planning does not write.
  private(set) var cleared: [ClearedReference] = []
  private var seen: Set<RowKey> = []

  private struct RowKey: Hashable {
    var table: String
    var id: UUID
  }

  mutating func upsert<Record: PlanningRow>(_ rows: [Record], db: Database) throws {
    for row in rows {
      if firstSight(of: Record.self, id: row.id) {
        if let current = try Record.fetchOne(db, key: row.id.uuidString) {
          before[keyPath: Record.rows].append(current)
        } else {
          inserted[keyPath: Record.ids].append(row.id)
        }
      }
      try row.save(db)
    }
  }

  /// Ids that are not there are passed over.
  mutating func delete<Record: PlanningRow>(
    _ type: Record.Type, ids: [UUID], db: Database
  ) throws {
    for id in ids {
      guard let current = try Record.fetchOne(db, key: id.uuidString) else { continue }
      try Record.refuseDeletion(of: id, db: db)
      try Record.keepDependents(of: id, journal: &self, db: db)
      try keepRowID(of: current, db: db)
      keep(current)
      _ = try Record.deleteOne(db, key: id.uuidString)
    }
  }

  /// Rows of a table the planning does not write whose `column` points at `id`: the schema
  /// clears the link when `id` goes (`ON DELETE SET NULL`), and undo sets it back.
  mutating func keepReference(table: String, column: String, to id: UUID, db: Database) throws {
    let rows = try String.fetchAll(
      db, sql: "SELECT id FROM \(table) WHERE \(column) = ? ORDER BY rowid",
      arguments: [id.uuidString])
    cleared += rows.map {
      ClearedReference(table: table, column: column, rowId: $0, categoryId: id)
    }
  }

  /// Rows of `Record` whose `column` points at `id`, kept as they are now.
  mutating func keepRows<Record: PlanningRow>(
    _ type: Record.Type, where column: String, is id: UUID, db: Database
  ) throws {
    for row in try Record.filter(Column(column) == id.uuidString).fetchAll(db) {
      try keepRowID(of: row, db: db)
      keep(row)
    }
  }

  private mutating func keepRowID<Record: PlanningRow>(of row: Record, db: Database) throws {
    guard rowIDs[row.id] == nil else { return }
    rowIDs[row.id] = try Int64.fetchOne(
      db, sql: "SELECT rowid FROM \(Record.databaseTableName) WHERE id = ?",
      arguments: [row.id.uuidString])
  }

  private mutating func keep<Record: PlanningRow>(_ row: Record) {
    guard firstSight(of: Record.self, id: row.id) else { return }
    before[keyPath: Record.rows].append(row)
  }

  private mutating func firstSight<Record: PlanningRow>(of type: Record.Type, id: UUID) -> Bool {
    seen.insert(RowKey(table: Record.databaseTableName, id: id)).inserted
  }
}

/// Refuses to delete a row that operations point at, deleted operations included: undo of
/// their deletion would bring them back pointing at nothing. `sql` names the row `:id`.
private func refuseIfOperations(_ sql: String, point id: UUID, db: Database) throws {
  let found = try Bool.fetchOne(
    db, sql: "SELECT EXISTS (\(sql))", arguments: ["id": id.uuidString])
  if found == true { throw PlanningWriteError.referencedByOperations(id) }
}

extension CoreKit.Category: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.categories }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.categories }

  /// Every row in `dependents` that points at the category, kept before it goes.
  static func keepDependents(of id: UUID, journal: inout UndoJournal, db: Database) throws {
    for (table, column) in dependents {
      switch table {
      case Goal.databaseTableName: try journal.keepRows(Goal.self, where: column, is: id, db: db)
      case Debt.databaseTableName: try journal.keepRows(Debt.self, where: column, is: id, db: db)
      case ScheduledPayment.databaseTableName:
        try journal.keepRows(ScheduledPayment.self, where: column, is: id, db: db)
      case ExpectedIncome.databaseTableName:
        try journal.keepRows(ExpectedIncome.self, where: column, is: id, db: db)
      case Budget.databaseTableName:
        try journal.keepRows(Budget.self, where: column, is: id, db: db)
      default: try journal.keepReference(table: table, column: column, to: id, db: db)
      }
    }
  }

  /// Every column of another table that points at a category and is not `RESTRICT`
  /// (operations are refused by the schema itself, `ON DELETE RESTRICT` on their parts).
  /// Limits on the category go with it; goals, debts, payments and expected income filed
  /// under it lose the reference; these rows of the planning are kept whole. The rest are
  /// not rows the planning writes — a template of the entry line, a mapping of the import, a
  /// correction of the model — and lose only the link (`ON DELETE SET NULL`), which is all
  /// that is kept and all undo sets back. A test holds this list against the foreign keys of
  /// the schema, so a column a later migration adds cannot be forgotten.
  static let dependents: [(table: String, column: String)] = [
    ("goals", "subcategory_id"), ("debts", "loans_subcategory_id"),
    ("scheduled_payments", "category_id"), ("expected_income", "category_id"),
    ("budgets", "category_id"), ("templates", "category_id"),
    ("import_mappings", "target_category_id"), ("category_feedback", "predicted_category_id"),
    ("category_feedback", "chosen_category_id"),
  ]
}

extension Event: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.events }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.events }

  static func refuseDeletion(of id: UUID, db: Database) throws {
    try refuseIfOperations(
      "SELECT 1 FROM transaction_parts WHERE event_id = :id", point: id, db: db)
  }
}

extension Goal: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.goals }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.goals }

  static func refuseDeletion(of id: UUID, db: Database) throws {
    try refuseIfOperations(
      "SELECT 1 FROM transaction_parts WHERE goal_id = :id", point: id, db: db)
  }
}

extension Debt: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.debts }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.debts }

  static func refuseDeletion(of id: UUID, db: Database) throws {
    try refuseIfOperations(
      "SELECT 1 FROM transactions WHERE debt_id = :id OR credit_debt_id = :id", point: id, db: db)
  }

  /// Its journal goes with it.
  static func keepDependents(of id: UUID, journal: inout UndoJournal, db: Database) throws {
    try journal.keepRows(DebtEntry.self, where: "debt_id", is: id, db: db)
  }
}

extension ScheduledPayment: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.scheduled }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.scheduled }

  /// Its price history goes with it.
  static func keepDependents(of id: UUID, journal: inout UndoJournal, db: Database) throws {
    try journal.keepRows(SubscriptionPrice.self, where: "payment_id", is: id, db: db)
  }
}

extension SubscriptionPrice: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.prices }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.prices }
}

extension ExpectedIncome: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.expected }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.expected }

  /// Its links to the income received go with it; the operations stay.
  static func keepDependents(of id: UUID, journal: inout UndoJournal, db: Database) throws {
    try journal.keepRows(ExpectedIncomeLink.self, where: "expected_income_id", is: id, db: db)
  }
}

extension ExpectedIncomeLink: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.expectedLinks }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.expectedLinks }
}

extension Budget: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.budgets }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.budgets }
}

extension DebtEntry: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.debtEntries }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.debtEntries }
}

extension Reconciliation: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.reconciliations }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.reconciliations }
}
