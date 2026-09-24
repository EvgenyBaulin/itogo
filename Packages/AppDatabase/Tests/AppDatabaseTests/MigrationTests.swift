import CoreKit
import Foundation
import Testing

@testable import AppDatabase

@Suite("Migrations come from Schema/ and nowhere else")
struct MigrationTests {
  @Test func everySqlFileBecomesOneMigration() throws {
    let files = try FileManager.default
      .contentsOfDirectory(at: TestSupport.schemaDirectory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "sql" }
      .map { $0.deletingPathExtension().lastPathComponent }
      .sorted()

    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations() == files)
    #expect(files.isEmpty == false)
  }

  @Test func schemaCreatesEveryTableTheSpecificationLists() throws {
    let stack = try TestSupport.makeStack()
    let expected = [
      "anomaly_dismissals", "budgets", "categories", "category_feedback", "currencies",
      "debt_entries", "debts", "events", "expected_income", "expected_income_links",
      "goals", "import_batches", "import_mappings", "ml_models", "payment_methods",
      "people", "places", "rates", "reconciliations", "reimbursement_links",
      "scheduled_payments", "settings", "subscription_prices", "templates",
      "transaction_parts", "transactions",
    ]
    let tables = try stack.writer.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
          ORDER BY name
          """)
    }
    #expect(tables == expected)
  }

  @Test func migratingTwiceChangesNothing() throws {
    let stack = try TestSupport.makeStack()
    let first = try stack.appliedMigrations()
    let second = try TestSupport.makeStack().appliedMigrations()
    #expect(first == second)
  }

  @Test func integrityCheckPasses() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.integrityCheckPassed())
  }
}

/// The schema as it was before the planning: the first migration alone.
private struct FirstMigrationOnly: SchemaSource {
  func migrations() throws -> [SchemaMigration] {
    Array(try TestSupport.schemaSource.migrations().prefix(1))
  }
}

extension MigrationTests {
  /// A database of the first schema, with a limit and a reconciliation in it, opens with the
  /// planning migration: the rows stay as they were, the new columns come empty, and the
  /// unique index on the limits is there.
  @Test func thePlanningMigrationKeepsTheRowsOfTheFirstSchema() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-db-tests")
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("finance.sqlite")
    let category = CoreKit.Category(kind: .expense, name: "Groceries")
    let budgetId = UUID()
    let reconciliationId = UUID()

    do {
      let old = try DatabaseStack(url: url, schema: FirstMigrationOnly())
      #expect(try old.appliedMigrations() == ["0001_initial"])
      try old.writer.write { db in
        try category.insert(db)
        try db.execute(
          sql: """
            INSERT INTO budgets (id, scope, category_id, amount_e4, rollover)
            VALUES (?, 'category', ?, 150000000, 1)
            """,
          arguments: [budgetId.uuidString, category.id.uuidString])
        try db.execute(
          sql: """
            INSERT INTO reconciliations
              (id, date, actual_total_rub_e4, expected_total_rub_e4, difference_e4)
            VALUES (?, '2026-08-31', 1000000000, 1000120000, -120000)
            """,
          arguments: [reconciliationId.uuidString])
      }
      let columns = try old.writer.read { db in try db.columns(in: "budgets").map(\.name) }
      #expect(!columns.contains("start_month"))
    }

    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    #expect(try stack.appliedMigrations() == TestSupport.schemaSource.migrations().map(\.name))
    #expect(try stack.appliedMigrations().contains("0002_planning"))
    let repository = PlanningRepository(writer: stack.writer)
    #expect(
      try repository.budgets() == [
        Budget(
          id: budgetId, scope: .category, categoryId: category.id,
          amountE4: AmountE4(whole: 15_000), rollover: true, startMonth: nil)
      ])
    #expect(
      try repository.reconciliations() == [
        Reconciliation(
          id: reconciliationId, date: DateOnly(year: 2026, month: 8, day: 31),
          reconciledAt: nil, actualTotalRubE4: AmountE4(whole: 100_000),
          expectedTotalRubE4: AmountE4(whole: 100_012), differenceE4: AmountE4(whole: -12))
      ])

    try stack.writer.read { db in
      #expect(try db.columns(in: "budgets").map(\.name).last == "start_month")
      #expect(
        try db.columns(in: "reconciliations").map(\.name).suffix(2)
          == ["reconciled_at", "breakdown"])
      // An index on expressions, which `db.indexes(on:)` leaves out: asked of SQLite itself.
      let unique = try Bool.fetchOne(
        db,
        sql: """
          SELECT "unique" FROM pragma_index_list('budgets') WHERE name = 'idx_budgets_target'
          """)
      #expect(unique == true)
    }

    // The new columns take values like any other.
    var budget = try #require(try repository.budgets().first)
    budget.startMonth = MonthKey(year: 2026, month: 9)
    _ = try repository.apply(PlanningChange(upsert: PlanningRows(budgets: [budget])))
    #expect(try repository.budgets() == [budget])
    #expect(try stack.integrityCheckPassed())
  }
}

/// The first migration makes a table; the second makes it again and stops.
private struct SecondMigrationBroken: SchemaSource {
  let count: Int
  func migrations() throws -> [SchemaMigration] {
    Array(
      [
        SchemaMigration(name: "0001_first", sql: "CREATE TABLE a (id INTEGER);"),
        SchemaMigration(name: "0002_broken", sql: "CREATE TABLE a (id INTEGER);"),
      ].prefix(count))
  }
}

extension MigrationTests {
  /// The journal says of a migration from which version to which, how long and with what
  /// result. A migration that stopped threw the bare SQLite error: the app could not say
  /// which migration, nor from which version to which.
  @Test func aMigrationThatStopsSaysWhichOneAndFromWhereToWhere() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-db-tests")
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("finance.sqlite")
    try DatabaseStack(url: url, schema: SecondMigrationBroken(count: 1)).close()

    let failure = try #require(
      throws: DatabaseStack.MigrationFailure.self,
      performing: { try DatabaseStack(url: url, schema: SecondMigrationBroken(count: 2)) })

    #expect(failure.from == 1)
    #expect(failure.to == 2)
    #expect(failure.migration == "0002_broken")
    #expect(failure.milliseconds >= 0)
    #expect((failure.underlying as NSError).domain == "GRDB.DatabaseError")
  }
}
