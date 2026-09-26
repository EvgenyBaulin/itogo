import AppCore
import CoreKit
import Foundation
import GRDB

/// What a migration needs from the app beyond its SQL, run right after that SQL inside the same
/// transaction: all of it lands, or the file stays exactly as it was.
///
/// Every read and write here is raw SQL against the columns as the migration left them, never
/// through the record types: a record grows with every later schema, and the step of an older
/// migration must do tomorrow exactly what it does today.
enum MigrationDataSteps {
  /// Thrown after the SQL of `0004_accounts` ran, when the context asks for it: the proof that a
  /// migration stopped halfway leaves nothing behind.
  struct StoppedOnPurpose: Error {}

  /// Runs the step of the migration `name`, if it has one, and says what it did — counts only.
  static func after(
    _ name: String, db: Database, context: MigrationContext
  ) throws -> [String: Int] {
    switch name {
    case "0004_accounts": try accounts(db: db, context: context)
    default: [:]
    }
  }

  /// One live main account, and an account for every operation (`AccountsMigration`). These
  /// are the only values of the older build the update changes:
  /// - `is_default` of the chosen main account becomes 1, and of every other row 0;
  /// - `transactions.payment_method_id` that was NULL becomes the main account, in the bin too.
  ///
  /// `updated_at` of the operations stays as it was: the owner's last rating of a description
  /// is found by it. A currency left empty by the older build is not filled either — it is read
  /// as rubles.
  ///
  /// The counts: `mainKept` — an account already flagged main stays main; `mainChosen` — an
  /// account not flagged was made main; `mainCreated` — an account was made for it. One of the
  /// three is 1 exactly when the database has a main account afterwards, so the journal tells
  /// «kept» from «none at all». `defaultsCleared` — rows that lost the flag; `assigned` —
  /// operations that got the main account.
  private static func accounts(db: Database, context: MigrationContext) throws -> [String: Int] {
    var ids: [UUID: String] = [:]
    var accounts: [MigratingAccount] = []
    let rows = try Row.fetchAll(
      db, sql: "SELECT rowid, id, name, archived, is_default FROM payment_methods ORDER BY rowid")
    for row in rows {
      // An id that is NULL or not a UUID cannot be chosen; the flag still goes by the SQL below.
      guard let text: String = row["id"], let id = UUID(uuidString: text) else { continue }
      ids[id] = text
      accounts.append(
        MigratingAccount(
          id: id, name: row["name"] ?? "",
          archived: try RowMapping.flag(row, "archived", fallback: false),
          isDefault: try RowMapping.flag(row, "is_default", fallback: false), rowid: row["rowid"]))
    }
    var live: [UUID: Int] = [:]
    for row in try Row.fetchAll(
      db,
      sql: """
        SELECT payment_method_id, COUNT(*) FROM transactions
        WHERE deleted_at IS NULL AND payment_method_id IS NOT NULL
        GROUP BY payment_method_id
        """)
    {
      guard let text: String = row[0], let id = UUID(uuidString: text) else { continue }
      live[id, default: 0] += row[1]
    }
    let unassigned =
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM transactions WHERE payment_method_id IS NULL") ?? 0
    let operations = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") ?? 0

    let plan = AccountsMigration.plan(
      accounts: accounts, liveOperations: live, unassigned: unassigned, operations: operations,
      mainAccountName: context.mainAccountName, makeId: context.makeId)

    var counts = [
      "mainKept": 0, "mainChosen": 0, "mainCreated": 0, "defaultsCleared": 0, "assigned": 0,
    ]
    if let created = plan.created {
      try db.execute(
        sql: """
          INSERT INTO payment_methods (id, name, kind, currency, aliases, is_default, archived)
          VALUES (?, ?, ?, ?, '', 1, 0)
          """,
        arguments: [
          created.id.uuidString, created.name, created.kind.rawValue, created.currency?.code,
        ])
      ids[created.id] = created.id.uuidString
      counts["mainCreated"] = 1
    }
    if let mainId = plan.mainId, let main = ids[mainId] {
      try db.execute(
        sql: "UPDATE payment_methods SET is_default = 0 WHERE is_default = 1 AND id <> ?",
        arguments: [main])
      counts["defaultsCleared"] = db.changesCount
      try db.execute(
        sql: "UPDATE payment_methods SET is_default = 1 WHERE id = ? AND is_default = 0",
        arguments: [main])
      if plan.created == nil {
        let chosen = db.changesCount
        counts["mainChosen"] = chosen
        counts["mainKept"] = 1 - chosen
      }
      if plan.assignUnassignedTo == mainId {
        try db.execute(
          sql: "UPDATE transactions SET payment_method_id = ? WHERE payment_method_id IS NULL",
          arguments: [main])
        counts["assigned"] = db.changesCount
      }
    }
    if context.failAfterSQL { throw StoppedOnPurpose() }
    return counts
  }
}
