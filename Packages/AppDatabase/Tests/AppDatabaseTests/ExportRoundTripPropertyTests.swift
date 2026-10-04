import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// Every value of the database reaches the export and comes back from it: the 24 files are
/// read back with the CSV reader, and each cell is checked against the raw value of its column
/// in SQLite by a rule written apart from the export — an amount times 10 000 is the stored
/// integer, a boolean is a word, an instant is the stored one to the second in UTC, a
/// breakdown is the same JSON, a currency is its code, and everything else is the text itself,
/// empty for NULL. Checked on a history with accounts whose names and notes carry commas,
/// quotes, line breaks and emoji, and on older databases drawn at random and updated.
///
/// The transfer archive carries the same files and the database beside them, and opening it
/// gives each of them back byte for byte.
@Suite("The export and the archive keep every value")
struct ExportRoundTripPropertyTests {
  /// Columns holding 0/1 that the export writes as words.
  private static let booleans: Set<String> = [
    "archived", "is_default", "reimbursable", "rate_provisional", "pinned", "recurring_yearly",
    "payments_are_expenses", "closed", "rollover", "active", "in_summary", "records_difference",
    "closes_term",
  ]
  /// Columns holding an instant, written in UTC to the second.
  private static let instants: Set<String> = [
    "occurred_at", "created_at", "updated_at", "deleted_at", "reconciled_at", "fetched_at",
  ]
  /// Columns holding a decimal kept as text.
  private static let decimals: Set<String> = ["rate", "rub_per_unit", "interest_rate", "share"]
  /// Columns holding a currency code.
  private static let currencies: Set<String> = [
    "currency", "account_currency", "reimbursement_currency", "from_currency", "to_currency",
    "cashback_currency",
  ]

  private static let posix = Locale(identifier: "en_US_POSIX")

  /// The cell a raw value of `column` has to become, by the rule of the export.
  private static func expectedCell(
    column: String, databaseColumn: String, raw: DatabaseValue
  ) -> String? {
    if raw.isNull { return "" }
    if databaseColumn.hasSuffix("_e4"), let stored = Int64.fromDatabaseValue(raw) {
      return "e4:\(stored)"
    }
    if booleans.contains(column), let flag = Int64.fromDatabaseValue(raw) {
      return flag == 0 ? "false" : "true"
    }
    let text = String.fromDatabaseValue(raw) ?? "\(raw)"
    if instants.contains(column) {
      // 'YYYY-MM-DD HH:MM:SS.SSS' → 'YYYY-MM-DDTHH:MM:SSZ'
      let characters = Array(text)
      guard characters.count >= 19 else { return nil }
      return String(characters[0..<10]) + "T" + String(characters[11..<19]) + "Z"
    }
    if decimals.contains(column) { return "decimal:\(Decimal(string: text, locale: posix)!)" }
    if currencies.contains(column) {
      return text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
    if column == "aliases" { return aliases(text).joined(separator: "\n") }
    if column == "breakdown" { return "json:\(ReconciliationBreakdown.amounts(fromJSON: text))" }
    return text
  }

  /// The aliases a column holds: one per line, any line break — `\r\n` as one — separating
  /// them, empty lines none.
  private static func aliases(_ text: String) -> [String] {
    var found: [String] = []
    var current = ""
    for character in text {
      if character.isNewline {
        if !current.isEmpty { found.append(current) }
        current = ""
      } else {
        current.append(character)
      }
    }
    if !current.isEmpty { found.append(current) }
    return found
  }

  /// The cell as the rule compares it: an amount back to stored units, a decimal, JSON.
  private static func readCell(column: String, databaseColumn: String, cell: String) -> String {
    if cell.isEmpty { return "" }
    if databaseColumn.hasSuffix("_e4") {
      guard let value = Decimal(string: cell, locale: posix) else { return "unreadable \(cell)" }
      var units = value * 10_000
      var rounded = Decimal()
      NSDecimalRound(&rounded, &units, 0, .plain)
      return "e4:\(NSDecimalNumber(decimal: rounded).int64Value)"
    }
    if decimals.contains(column) { return "decimal:\(Decimal(string: cell, locale: posix)!)" }
    if column == "breakdown" { return "json:\(ReconciliationBreakdown.amounts(fromJSON: cell))" }
    return cell
  }

  /// Every file of the export against the database it was written from.
  private func expectEveryValueKept(_ stack: DatabaseStack, _ label: String) throws {
    let tables = try ExportRepository(writer: stack.writer).tables()
    #expect(tables.map(\.fileName) == ExportTables.all.map(\.fileName))
    try stack.writer.read { db in
      for (table, file) in zip(ExportTables.all, tables) {
        let name = String(table.fileName.dropLast(4))
        let header = try #require(try CSVReader.rows(from: file.data).first)
        #expect(header == table.columns, "\(label): \(name) header")
        let rows = try CSVReader.dictionaries(from: file.data)
        let databaseColumns = Set(try db.columns(in: name).map(\.name))
        let mapping = table.columns.map { column in
          databaseColumns.contains(column) ? column : column + "_e4"
        }
        #expect(
          mapping.allSatisfy(databaseColumns.contains), "\(label): \(name) has a column nowhere")
        let key = name == "rates" ? ["date", "currency", "source"] : ["id"]
        let stored = try Row.fetchAll(db, sql: "SELECT * FROM \(name)")
        #expect(rows.count == stored.count, "\(label): \(name) rows")
        var byKey: [String: Row] = [:]
        for row in stored {
          let identity = key.map { column -> String in
            let raw: DatabaseValue = row[column]
            let text = String.fromDatabaseValue(raw) ?? ""
            return column == "currency" ? text.uppercased() : text
          }.joined(separator: "|")
          byKey[identity] = row
        }
        // Row for row: every row of the table is in the file once, and the file has no other —
        // a row written twice in place of one left out would keep the count.
        #expect(byKey.count == stored.count, "\(label): \(name) has two rows of one key")
        let identities = rows.map { cells in key.map { cells[$0] ?? "" }.joined(separator: "|") }
        #expect(Set(identities).count == identities.count, "\(label): \(name) repeats a row")
        #expect(Set(identities) == Set(byKey.keys), "\(label): \(name) rows differ")
        for cells in rows {
          let identity = key.map { cells[$0] ?? "" }.joined(separator: "|")
          guard let row = byKey[identity] else {
            Issue.record("\(label): \(name) has a row the database does not")
            continue
          }
          for (column, databaseColumn) in zip(table.columns, mapping) {
            let expected = Self.expectedCell(
              column: column, databaseColumn: databaseColumn, raw: row[databaseColumn] ?? .null)
            let got = Self.readCell(
              column: column, databaseColumn: databaseColumn, cell: cells[column] ?? "?")
            #expect(got == expected, "\(label): \(name).\(column) of \(identity)")
          }
        }
      }
    }
  }

  /// A history with accounts — every one of the 24 tables has rows, and every column the cards
  /// brought a value somewhere — whose texts carry what a CSV file must never break on.
  @Test func aHistoryWithAccountsAndOddTextsIsExportedValueForValue() throws {
    let stack = try PlanningUndoPropertyTests.stack()
    try Self.addCards(to: stack)
    let odd = [
      "comma, inside", "a \"quoted\" word", "two\nlines", "carriage\r\nreturn", "emoji 🎂🇷🇺",
      "e\u{301}", "  spaces  ", "tab\tinside", "", "semi;colon", "back\\slash",
    ]
    try stack.writer.write { db in
      var index = 0
      func next() -> String {
        defer { index += 1 }
        return odd[index % odd.count]
      }
      for id in try String.fetchAll(db, sql: "SELECT id FROM transactions LIMIT 40") {
        try db.execute(
          sql: "UPDATE transactions SET note = ? WHERE id = ?", arguments: [next(), id])
      }
      for id in try String.fetchAll(db, sql: "SELECT id FROM transaction_parts LIMIT 40") {
        try db.execute(
          sql: "UPDATE transaction_parts SET note = ? WHERE id = ?", arguments: [next(), id])
      }
      for table in ["people", "places", "payment_methods", "events", "categories", "goals"] {
        for id in try String.fetchAll(db, sql: "SELECT id FROM \(table)") {
          try db.execute(
            sql: "UPDATE \(table) SET name = name || ? WHERE id = ?", arguments: [next(), id])
        }
      }
      // Rates as the bank publishes them: per a nominal, with many digits or none.
      try db.execute(
        sql: """
          INSERT INTO rates (date, currency, rub_per_unit, nominal, source, fetched_at) VALUES
            ('2026-09-01', 'JPY', '56.2349', 100, 'cbr', '2026-09-01 12:00:00.123'),
            ('2026-09-01', 'USD', '81.4321', 1, 'cbr_mirror', NULL),
            ('2026-09-02', 'USD', '81', 1, 'manual', '2026-09-02 09:30:59.999'),
            ('2026-09-02', 'KZT', '0.000123456789', 1, 'import', NULL)
          """)
      for id in try String.fetchAll(db, sql: "SELECT id FROM transfers") {
        try db.execute(sql: "UPDATE transfers SET note = ? WHERE id = ?", arguments: [next(), id])
      }
    }
    let counts = try ExportRepository(writer: stack.writer).rowCounts()
    for table in ExportTables.all {
      #expect(counts[String(table.fileName.dropLast(4))] ?? 0 > 0, "\(table.fileName) is empty")
    }
    try expectEveryValueKept(stack, "sample")
  }

  /// Older databases drawn at random, updated: lower-case and blank currencies come out as
  /// their codes, zero amounts as zero, and every other value as it is.
  @Test(arguments: [UInt64(401), 402, 403, 404, 405, 406, 407, 408, 409, 410])
  func anUpdatedOlderDatabaseIsExportedValueForValue(seed: UInt64) throws {
    let book = try RandomLegacyDatabase(seed: seed)
    defer { book.remove() }
    let stack = try DatabaseStack(url: book.url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    try expectEveryValueKept(stack, "seed \(seed)")
  }

  /// The archive of a history: the database snapshot and the 23 files go in, and opening the
  /// archive — plain or sealed with a password — gives every one of them back byte for byte;
  /// the database inside holds the same data as the one it was taken of.
  @Test func theArchiveGivesBackEveryFileByteForByte() throws {
    let stack = try PlanningUndoPropertyTests.stack()
    try Self.addCards(to: stack)
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-archive-round-trip-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let snapshotURL = folder.appendingPathComponent("snapshot.sqlite")
    let snapshot = try ExportRepository(writer: stack.writer).snapshot(to: snapshotURL)
    let database = try Data(contentsOf: snapshotURL)

    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "1.1.0", schemaVersion: stack.applied.onDisk,
        createdAt: DateOnly(year: 2026, month: 9, day: 26), platform: "macOS",
        rowCounts: snapshot.rowCounts))
    try builder.add(path: ArchivePaths.database, data: database)
    var files = [ArchivePaths.database: database]
    for table in snapshot.tables {
      try builder.add(path: ArchivePaths.csv(table: table.name), data: table.data)
      files[ArchivePaths.csv(table: table.name)] = table.data
    }
    let settings = Data(#"{"language":"ru"}"#.utf8)
    try builder.add(path: ArchivePaths.settings, data: settings)
    files[ArchivePaths.settings] = settings

    let plain = try ArchiveOpener.open(try builder.build(), supportedSchemaVersion: 6)
    #expect(plain.files == files)
    #expect(plain.csvTables.count == 24)
    #expect(plain.manifest.schemaVersion == 6)

    var random = SeededRandom(seed: 7)
    let sealed = try builder.build(
      password: "пароль 🔑", cipher: RoundTripCipher(), random: &random, iterations: 1_000)
    #expect(ArchiveOpener.isEncrypted(sealed))
    let opened = try ArchiveOpener.open(
      sealed, password: "пароль 🔑", cipher: RoundTripCipher(), supportedSchemaVersion: 6)
    #expect(opened.files == files)

    let inside = folder.appendingPathComponent("inside.sqlite")
    try (opened.database ?? Data()).write(to: inside)
    #expect(try DatabaseStack.sameData(fileAt: inside, as: snapshotURL))
    #expect(try DatabaseStack.check(fileAt: inside, schema: TestSupport.schemaSource) == .sound)
  }

  /// An archive an older build wrote — schema 3, its database and the 18 files with the columns
  /// they had — opens in this build, its database is one this build updates, and the update
  /// keeps every row the files counted.
  @Test(arguments: [UInt64(421), 422, 423, 424])
  func anArchiveOfTheOlderBuildOpensAndItsDatabaseUpdates(seed: UInt64) throws {
    let book = try RandomLegacyDatabase(seed: seed)
    defer { book.remove() }
    // One file, as the older build's archive held it: its snapshot through the backup API.
    let snapshot = book.url.deletingLastPathComponent().appendingPathComponent("snapshot.sqlite")
    try DatabaseStack.backup(fileAt: book.url, to: snapshot)
    let database = try Data(contentsOf: snapshot)
    let older = ExportTables.all.prefix(18).map { table in
      ExportTable(
        fileName: table.fileName,
        columns: table.columns.filter {
          !Self.addedByTheAccounts.contains("\(table.fileName):\($0)")
            && !Self.addedByTheCards.contains("\(table.fileName):\($0)")
            && !Self.addedByTheBanks.contains("\(table.fileName):\($0)")
        })
    }
    var counts: [String: Int] = [:]
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "1.0.0", schemaVersion: 3, createdAt: DateOnly(year: 2026, month: 9, day: 25),
        platform: "macOS",
        rowCounts: try book.read { db in
          var counts: [String: Int] = [:]
          for table in older {
            let name = String(table.fileName.dropLast(4))
            counts[name] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(name)") ?? 0
          }
          return counts
        }))
    try builder.add(path: ArchivePaths.database, data: database)
    try book.read { db in
      for table in older {
        let name = String(table.fileName.dropLast(4))
        var csv = CSVWriter(columns: table.columns)
        let known = Set(try db.columns(in: name).map(\.name))
        let columns = table.columns.map { known.contains($0) ? $0 : $0 + "_e4" }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM \(name)") {
          csv.append(
            columns.map { column in
              let raw: DatabaseValue = row[column]
              return raw.isNull ? "" : (String.fromDatabaseValue(raw) ?? "\(raw)")
            })
        }
        counts[name] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(name)") ?? 0
        try builder.add(path: ArchivePaths.csv(table: name), data: csv.data())
      }
    }
    try builder.add(path: ArchivePaths.settings, text: #"{"language":"ru"}"#)

    let opened = try ArchiveOpener.open(try builder.build(), supportedSchemaVersion: 6)
    #expect(opened.manifest.schemaVersion == 3)
    #expect(opened.csvTables.count == 18)

    let folder = book.url.deletingLastPathComponent()
    let staged = folder.appendingPathComponent("imported.sqlite")
    try (opened.database ?? Data()).write(to: staged)
    #expect(try DatabaseStack.check(fileAt: staged, schema: TestSupport.schemaSource) == .sound)
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: staged, schema: TestSupport.schemaSource)
        == ["0004_accounts", "0005_cards", "0006_banks"])
    let stack = try DatabaseStack(url: staged, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    let after = try ExportRepository(writer: stack.writer).rowCounts()
    let created = stack.applied.dataSteps["mainCreated"] ?? 0
    for (table, count) in counts {
      #expect(after[table] == count + (table == "payment_methods" ? created : 0), "\(table)")
    }
    for table in ["account_groups", "transfers", "reconciliation_balances", "cashback_rules"] {
      #expect(after[table] == 0)
    }
    #expect(after["cards"] == stack.applied.dataSteps["cardsCreated"] ?? 0)
  }

  /// The archive checks its manifest against the rows it counts in each file, and it counts
  /// them the way the reader reads them: for the 24 files of an export and for tables of drawn
  /// texts full of quotes and line breaks.
  @Test func theArchiveCountsTheRowsTheReaderReads() throws {
    let stack = try PlanningUndoPropertyTests.stack()
    for table in try ExportRepository(writer: stack.writer).tables() {
      #expect(
        ArchiveOpener.countCSVRows(table.data)
          == (try CSVReader.dictionaries(from: table.data).count),
        "\(table.fileName)")
    }
    var random = SeededRandom(seed: 99)
    let pieces = ["a", ",", "\"", "\n", "\r", "\r\n", " ", "", "🎂", "e\u{301}"]
    for round in 0..<500 {
      let width = random.int(in: 1...4)
      var writer = CSVWriter(columns: (0..<width).map { "c\($0)" })
      let count = random.int(in: 0...12)
      for _ in 0..<count {
        writer.append(
          (0..<width).map { _ in
            (0..<random.int(in: 0...4)).map { _ in pieces[random.int(in: 0..<pieces.count)] }
              .joined()
          })
      }
      let data = writer.data()
      #expect(ArchiveOpener.countCSVRows(data) == count, "round \(round)")
      #expect(try CSVReader.dictionaries(from: data).count == count, "round \(round)")
    }
  }

  /// Every column of every table the export writes is in its file — an amount under its name
  /// without `_e4` —, and the file has no column the table lacks: a column a later migration
  /// adds cannot be left out of the export without this test saying so.
  @Test func everyColumnOfAnExportedTableIsInItsFile() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.read { db in
      for table in ExportTables.all {
        let name = String(table.fileName.dropLast(4))
        let stored = Set(try db.columns(in: name).map(\.name))
        #expect(!stored.isEmpty, "\(name) is no table")
        let written = Set(table.columns.map { stored.contains($0) ? $0 : $0 + "_e4" })
        #expect(
          written == stored,
          "\(name): only in the table \(stored.subtracting(written)), only in the file \(written.subtracting(stored))"
        )
        #expect(table.columns.count == Set(table.columns).count, "\(name) names a column twice")
      }
    }
  }

  /// The tables the export leaves out, each for a reason of its own: the model's and the
  /// import's own books, the settings and the list of currencies (the archive carries the
  /// database whole), the anomalies waved away, the choices of a category, the links of the
  /// expected income. A table a later migration adds is either exported or named here.
  @Test func theTablesLeftOutOfTheExportAreNamed() throws {
    let stack = try TestSupport.makeStack()
    let tables = try stack.writer.read { db in
      try String.fetchSet(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
          """)
    }
    let exported = Set(ExportTables.all.map { String($0.fileName.dropLast(4)) })
    #expect(exported.isSubset(of: tables))
    #expect(
      tables.subtracting(exported) == [
        "anomaly_dismissals", "category_feedback", "currencies", "expected_income_links",
        "import_batches", "import_mappings", "ml_models", "settings",
      ])
  }

  /// The columns the accounts added to the files of the older build, file by file.
  private static let addedByTheAccounts: Set<String> = [
    "transactions.csv:account_currency", "transactions.csv:account_amount",
    "transaction_parts.csv:refund_of_part_id", "payment_methods.csv:group_id",
    "payment_methods.csv:sort", "payment_methods.csv:other_currencies",
    "templates.csv:archived", "goals.csv:currency", "debt_entries.csv:payment_method_id",
    "debt_entries.csv:occurred_at", "debt_entries.csv:account_currency",
    "debt_entries.csv:account_amount", "reconciliations.csv:kind",
  ]

  /// The columns the cards added to the files of the older build, file by file.
  private static let addedByTheCards: Set<String> = [
    "transactions.csv:card_id", "transactions.csv:cashback_currency", "transactions.csv:cashback",
    "scheduled_payments.csv:card_id", "scheduled_payments.csv:event_id",
    "expected_income.csv:payment_method_id", "goals.csv:plan_start_month", "debts.csv:deleted_at",
    "reconciliations.csv:origin",
  ]

  /// The columns the banks and the cashback settings of the accounts added to the files of the
  /// older build, file by file.
  private static let addedByTheBanks: Set<String> = [
    "payment_methods.csv:bank_id", "payment_methods.csv:cashback_precision",
    "payment_methods.csv:cashback_direction", "payment_methods.csv:cashback_payout",
    "payment_methods.csv:cashback_payout_day", "payment_methods.csv:cashback_points_account_id",
    "debt_entries.csv:closes_term",
  ]

  /// Cards on two accounts of the history, one with other names that break a CSV cell; the
  /// cashback rules of one of them, a month and a category among them; operations and a payment
  /// that name a card, cashback typed for some purchases; a payment of an event, the plan start
  /// of a goal, the account of an expected income and a deleted debt — every column the cards
  /// brought holds a value somewhere.
  static func addCards(to stack: DatabaseStack) throws {
    try stack.writer.write { db in
      let accounts = try String.fetchAll(
        db, sql: "SELECT id FROM payment_methods WHERE archived = 0 ORDER BY rowid LIMIT 2")
      let category = try String.fetchOne(
        db, sql: "SELECT id FROM categories WHERE kind = 'expense' ORDER BY rowid LIMIT 1")
      let event = try String.fetchOne(db, sql: "SELECT id FROM events ORDER BY rowid LIMIT 1")
      for (index, account) in accounts.enumerated() {
        let card = UUID().uuidString
        try db.execute(
          sql: """
            INSERT INTO cards (id, payment_method_id, name, aliases, sort, archived)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            card, account, index == 0 ? "Visa, «золотая» \"1\"" : "Mir",
            index == 0 ? "gold\nзолотая, карта" : "", index, index == 1,
          ])
        try db.execute(
          sql: """
            INSERT INTO cashback_rules (id, payment_method_id, card_id, category_id, month,
              percent_e4)
            VALUES (?, ?, ?, NULL, NULL, 15000), (?, ?, ?, ?, '2026-09', 333333),
              (?, ?, NULL, NULL, NULL, 7500)
            """,
          arguments: [
            UUID().uuidString, account, card, UUID().uuidString, account, card, category,
            UUID().uuidString, account,
          ])
        try db.execute(
          sql: """
            UPDATE transactions SET card_id = ?
            WHERE id IN (
              SELECT id FROM transactions WHERE payment_method_id = ? ORDER BY rowid LIMIT 12)
            """,
          arguments: [card, account])
        try db.execute(
          sql: """
            UPDATE scheduled_payments SET card_id = ?, event_id = ?
            WHERE id IN (
              SELECT id FROM scheduled_payments WHERE payment_method_id = ? ORDER BY rowid
              LIMIT 1)
            """,
          arguments: [card, event, account])
      }
      try db.execute(
        sql: """
          UPDATE transactions
          SET cashback_currency = COALESCE(account_currency, currency),
            cashback_e4 = amount_e4 / 100
          WHERE id IN (
            SELECT id FROM transactions WHERE kind = 'expense' ORDER BY rowid LIMIT 15)
          """)
      try db.execute(
        sql: """
          UPDATE goals SET plan_start_month = '2026-07'
          WHERE id IN (SELECT id FROM goals ORDER BY rowid LIMIT 1)
          """)
      if let account = accounts.first {
        try db.execute(
          sql: """
            UPDATE expected_income SET payment_method_id = ?
            WHERE id IN (SELECT id FROM expected_income ORDER BY rowid LIMIT 1)
            """,
          arguments: [account])
      }
      try db.execute(
        sql: """
          UPDATE debts SET deleted_at = '2026-09-10 08:15:30.250'
          WHERE id IN (SELECT id FROM debts ORDER BY rowid LIMIT 1)
          """)
    }
  }
}

/// A stand-in cipher for sealing an archive in a test of the database package: a keystream of
/// SHA-256 blocks and an HMAC tag, enough to prove the archive travels intact through the
/// envelope. It must never leave the tests.
struct RoundTripCipher: ArchiveCipher {
  struct Refused: Error {}

  func seal(plaintext: Data, key: Data, nonce: Data) throws -> Data {
    let stream = keystream(count: plaintext.count, key: key, nonce: nonce)
    var bytes = [UInt8](plaintext)
    for index in bytes.indices { bytes[index] ^= stream[index] }
    return Data(bytes) + Data(tag(key: key, nonce: nonce, bytes: bytes))
  }

  func open(sealed: Data, key: Data, nonce: Data) throws -> Data {
    let all = [UInt8](sealed)
    guard all.count >= EncryptionHeader.tagByteCount else { throw Refused() }
    let split = all.count - EncryptionHeader.tagByteCount
    var bytes = [UInt8](all[0..<split])
    guard HMACSHA256.equal([UInt8](all[split...]), tag(key: key, nonce: nonce, bytes: bytes))
    else { throw Refused() }
    let stream = keystream(count: bytes.count, key: key, nonce: nonce)
    for index in bytes.indices { bytes[index] ^= stream[index] }
    return Data(bytes)
  }

  private func keystream(count: Int, key: Data, nonce: Data) -> [UInt8] {
    var stream: [UInt8] = []
    var counter: UInt32 = 0
    while stream.count < count {
      var block = [UInt8](key) + [UInt8](nonce)
      block += withUnsafeBytes(of: counter.bigEndian) { Array($0) }
      stream += SHA256.hash(block)
      counter += 1
    }
    return stream
  }

  private func tag(key: Data, nonce: Data, bytes: [UInt8]) -> [UInt8] {
    let code = HMACSHA256(key: key).authenticationCode(for: [UInt8](nonce) + bytes)
    return [UInt8](code[0..<EncryptionHeader.tagByteCount])
  }
}
