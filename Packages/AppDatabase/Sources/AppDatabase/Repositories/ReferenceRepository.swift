import CoreKit
import Foundation
import GRDB

/// Categories, people, places, payment methods, events, templates and goals.
public struct ReferenceRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  // MARK: Categories

  /// Writes the starter categories on first launch. Existing rows are left untouched.
  public func seedCategoriesIfEmpty(_ categories: [CoreKit.Category]) throws {
    try writer.write { db in
      let existing = try CoreKit.Category.fetchCount(db)
      guard existing == 0 else { return }
      // Parents first: the table references itself.
      for category in categories.filter({ $0.parentId == nil }) {
        try category.insert(db)
      }
      for category in categories.filter({ $0.parentId != nil }) {
        try category.insert(db)
      }
    }
  }

  public func categories(includeArchived: Bool = false) throws -> [CoreKit.Category] {
    try writer.read { db in
      var request = CoreKit.Category.all()
      if !includeArchived {
        request = request.filter(Column("archived") == false)
      }
      return try request.order(Column("sort"), Column("name")).fetchAll(db)
    }
  }

  public func category(systemRole: SystemRole, kind: CategoryKind) throws -> CoreKit.Category? {
    try writer.read { db in
      try CoreKit.Category
        .filter(Column("system_role") == systemRole.rawValue)
        .filter(Column("kind") == kind.rawValue)
        .fetchOne(db)
    }
  }

  public func save(_ category: CoreKit.Category) throws {
    try writer.write { db in try category.save(db) }
  }

  // MARK: Simple dictionaries

  public func people(includeArchived: Bool = false) throws -> [Person] {
    try fetchAll(Person.self, includeArchived: includeArchived)
  }

  public func places(includeArchived: Bool = false) throws -> [Place] {
    try fetchAll(Place.self, includeArchived: includeArchived)
  }

  public func paymentMethods(includeArchived: Bool = false) throws -> [PaymentMethod] {
    try fetchAll(PaymentMethod.self, includeArchived: includeArchived)
  }

  public func events(includeArchived: Bool = false) throws -> [Event] {
    try fetchAll(Event.self, includeArchived: includeArchived)
  }

  public func goals(includeArchived: Bool = false) throws -> [Goal] {
    try fetchAll(Goal.self, includeArchived: includeArchived)
  }

  public func templates() throws -> [Template] {
    try writer.read { db in
      try Template.order(Column("pinned").desc, Column("use_count").desc).fetchAll(db)
    }
  }

  public func debts(includeClosed: Bool = false) throws -> [Debt] {
    try writer.read { db in
      var request = Debt.all()
      if !includeClosed {
        request = request.filter(Column("closed") == false)
      }
      return try request.order(Column("name")).fetchAll(db)
    }
  }

  public func save(_ person: Person) throws { try writer.write { db in try person.save(db) } }
  public func save(_ place: Place) throws { try writer.write { db in try place.save(db) } }
  public func save(_ method: PaymentMethod) throws {
    try writer.write { db in try method.save(db) }
  }
  public func save(_ event: Event) throws { try writer.write { db in try event.save(db) } }
  public func save(_ goal: Goal) throws { try writer.write { db in try goal.save(db) } }
  public func save(_ template: Template) throws { try writer.write { db in try template.save(db) } }
  public func save(_ debt: Debt) throws { try writer.write { db in try debt.save(db) } }

  /// One debt's journal in the order the planning book reads it (`PlanningRepository`): by
  /// day, undated lines first, lines of one day in the order they were written. The ties of
  /// a day are not left to the query plan.
  public func debtEntries(debtId: UUID) throws -> [DebtEntry] {
    try writer.read { db in
      try DebtEntry
        .filter(Column("debt_id") == debtId.uuidString)
        .order(Column("date"), Column.rowID)
        .fetchAll(db)
    }
  }

  public func save(_ entry: DebtEntry) throws {
    try writer.write { db in try entry.save(db) }
  }

  /// Templates are only shortcuts for the entry line: deleting one loses no money data.
  public func deleteTemplate(id: UUID) throws {
    _ = try writer.write { db in
      try db.execute(sql: "DELETE FROM templates WHERE id = ?", arguments: [id.uuidString])
    }
  }

  // MARK: Merging duplicates

  /// Every column that points at a row of a dictionary that can be merged, by the table it
  /// points at. Operations are not the only thing that does: a scheduled payment names the
  /// person it is for and the card it is paid with, and the charge it writes next month
  /// takes them from there — a merge that left it behind would undo itself one payment at a
  /// time. `MergeTests` holds this list against the foreign keys of the schema, so a column a
  /// later migration adds cannot be forgotten here.
  static let mergedColumns: [String: [(table: String, column: String)]] = [
    "people": [
      ("transaction_parts", "for_person_id"), ("transaction_parts", "debtor_person_id"),
      ("debts", "person_id"), ("scheduled_payments", "for_person_id"),
      ("scheduled_payments", "debtor_person_id"), ("expected_income", "person_id"),
      ("import_mappings", "target_for_person_id"),
    ],
    "places": [("transactions", "place_id")],
    "payment_methods": [
      ("transactions", "payment_method_id"), ("scheduled_payments", "payment_method_id"),
    ],
    "events": [("transaction_parts", "event_id"), ("import_mappings", "target_event_id")],
  ]

  /// Moves everything that points at one row of a dictionary — operations, debts, the
  /// planning book — to another and archives the one that was merged away. Nothing is
  /// deleted: whatever pointed at the old row points at a row that exists.
  public func mergePerson(_ source: UUID, into target: UUID) throws {
    guard source != target else { return }
    try writer.write { db in
      try Self.repoint("people", from: source, to: target, db: db)
      try Self.mergeAliases(Person.self, source: source, into: target, db: db)
      try db.execute(
        sql: "UPDATE people SET archived = 1 WHERE id = ?", arguments: [source.uuidString])
    }
  }

  public func mergePlace(_ source: UUID, into target: UUID) throws {
    guard source != target else { return }
    try writer.write { db in
      try Self.repoint("places", from: source, to: target, db: db)
      try Self.mergeAliases(Place.self, source: source, into: target, db: db)
      try db.execute(
        sql: "UPDATE places SET archived = 1 WHERE id = ?", arguments: [source.uuidString])
    }
  }

  public func mergePaymentMethod(_ source: UUID, into target: UUID) throws {
    guard source != target else { return }
    try writer.write { db in
      try Self.repoint("payment_methods", from: source, to: target, db: db)
      try Self.mergeAliases(PaymentMethod.self, source: source, into: target, db: db)
      try db.execute(
        sql: "UPDATE payment_methods SET archived = 1 WHERE id = ?",
        arguments: [source.uuidString])
    }
  }

  public func mergeEvent(_ source: UUID, into target: UUID) throws {
    guard source != target else { return }
    try writer.write { db in
      try Self.repoint("events", from: source, to: target, db: db)
      try db.execute(
        sql: "UPDATE events SET archived = 1 WHERE id = ?", arguments: [source.uuidString])
    }
  }

  private static func repoint(
    _ dictionary: String, from source: UUID, to target: UUID, db: Database
  ) throws {
    for (table, column) in mergedColumns[dictionary] ?? [] {
      try db.execute(
        sql: "UPDATE \(table) SET \(column) = ? WHERE \(column) = ?",
        arguments: [target.uuidString, source.uuidString])
    }
  }

  /// The name of the row that disappears becomes an alias of the row that stays, so the
  /// entry line still recognises what I used to type.
  private static func mergeAliases<T: FetchableRecord & TableRecord>(
    _ type: T.Type, source: UUID, into target: UUID, db: Database
  ) throws {
    let table = T.databaseTableName
    guard
      let sourceName = try String.fetchOne(
        db, sql: "SELECT name FROM \(table) WHERE id = ?", arguments: [source.uuidString]),
      let sourceAliases = try String.fetchOne(
        db, sql: "SELECT aliases FROM \(table) WHERE id = ?", arguments: [source.uuidString]),
      let targetAliases = try String.fetchOne(
        db, sql: "SELECT aliases FROM \(table) WHERE id = ?", arguments: [target.uuidString])
    else { return }

    var merged = RowMapping.split(targetAliases)
    for alias in ([sourceName] + RowMapping.split(sourceAliases)) {
      let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty,
        !merged.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
      else { continue }
      merged.append(trimmed)
    }
    try db.execute(
      sql: "UPDATE \(table) SET aliases = ? WHERE id = ?",
      arguments: [RowMapping.join(merged), target.uuidString])
  }

  /// Everything the entry-line parser needs to recognise names and aliases.
  public func vocabulary(enabledCurrencies: [CurrencyCode]) throws -> ParserVocabulary {
    ParserVocabulary(
      people: try people().map {
        ParserVocabulary.Entry(id: $0.id, name: $0.name, aliases: $0.aliases)
      },
      places: try places().map {
        ParserVocabulary.Entry(id: $0.id, name: $0.name, aliases: $0.aliases)
      },
      paymentMethods: try paymentMethods().map {
        ParserVocabulary.Entry(id: $0.id, name: $0.name, aliases: $0.aliases)
      },
      events: try events().map { ParserVocabulary.Entry(id: $0.id, name: $0.name) },
      goals: try goals().map { ParserVocabulary.Entry(id: $0.id, name: $0.name) },
      debts: try debts().map { ParserVocabulary.Entry(id: $0.id, name: $0.name) },
      enabledCurrencies: enabledCurrencies)
  }

  private func fetchAll<T: FetchableRecord & TableRecord>(
    _ type: T.Type, includeArchived: Bool
  ) throws -> [T] {
    try writer.read { db in
      var request = T.all()
      if !includeArchived {
        request = request.filter(Column("archived") == false)
      }
      return try request.order(Column("name")).fetchAll(db)
    }
  }
}
