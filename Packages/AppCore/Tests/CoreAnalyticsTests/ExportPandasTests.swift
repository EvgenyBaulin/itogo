import CoreCSV
import CoreKit
import CoreSample
import Foundation
import Testing

/// Every file of Export, written from a six-month sample with its accounts — so the groups,
/// the transfers and the counted balances have rows too — read back by pandas with
/// `read_csv(path)` and no parameters: the promise of the format. pandas sees as many rows as
/// were written and the columns under the names the export declares, in its order.
///
/// Gated like the Reports check (`PandasTests`): without `make pyenv` it is skipped and says
/// why, and `make verify` prints «pandas: NOT checked».
@Suite(
  "pandas reads every file of Export",
  .enabled(
    if: Pandas.python != nil,
    "ITOGO_PYTHON is not set: run `make pyenv`, then `make test-core` to read the CSV with pandas"
  ))
struct ExportPandasTests {
  struct Reading: Decodable {
    let rows: Int
    let columns: [String]
  }

  static let script = """
    import json, sys, pandas
    result = {}
    for path in sys.argv[2:]:
        frame = pandas.read_csv(path)
        result[path] = {"rows": int(len(frame)), "columns": [str(c) for c in frame.columns]}
    with open(sys.argv[1], "w", encoding="utf-8") as output:
        json.dump(result, output)
    """

  /// The rows of each file, as the export writes them from a database holding the sample.
  static func rows(of set: SampleDataSet) -> [ExportTable: [[String]]] {
    let planning = set.planning
    var rows: [ExportTable: [[String]]] = [:]
    rows[ExportTables.transactions] = set.entries.map { ExportTables.row($0.transaction) }
    rows[ExportTables.transactionParts] = set.entries.flatMap(\.parts).map(ExportTables.row)
    rows[ExportTables.reimbursementLinks] = set.links.map(ExportTables.row)
    rows[ExportTables.people] = set.people.map(ExportTables.row)
    rows[ExportTables.paymentMethods] = set.paymentMethods.map(ExportTables.row)
    rows[ExportTables.places] = set.places.map(ExportTables.row)
    rows[ExportTables.events] = set.events.map(ExportTables.row)
    rows[ExportTables.categories] = set.categories.map(ExportTables.row)
    rows[ExportTables.templates] = set.templates.map(ExportTables.row)
    rows[ExportTables.scheduledPayments] = planning.scheduled.map(ExportTables.row)
    rows[ExportTables.subscriptionPrices] = planning.prices.map(ExportTables.row)
    rows[ExportTables.expectedIncome] = planning.expected.map(ExportTables.row)
    rows[ExportTables.budgets] = planning.budgets.map(ExportTables.row)
    rows[ExportTables.goals] = set.goals.map(ExportTables.row)
    rows[ExportTables.debts] = set.debts.map(ExportTables.row)
    rows[ExportTables.debtEntries] = set.debtEntries.map(ExportTables.row)
    rows[ExportTables.reconciliations] = set.reconciliations.map(ExportTables.row)
    // The sample fetches no rates: the file is its header alone.
    rows[ExportTables.rates] = []
    rows[ExportTables.accountGroups] = set.accountGroups.map(ExportTables.row)
    rows[ExportTables.transfers] = set.transfers.map(ExportTables.row)
    rows[ExportTables.reconciliationBalances] = set.reconciledBalances.map(ExportTables.row)
    return rows
  }

  @Test func everyFileReadsBackWithNoParameters() throws {
    let python = try #require(Pandas.python)
    let set = SampleDataGenerator(seed: 20_260_918).generate(
      months: 6, endingOn: Synthetic.endingOn, calendar: Synthetic.calendar, language: "ru"
    ).withAccounts(seed: 20_260_918, calendar: Synthetic.calendar, language: "ru")
    let rows = Self.rows(of: set)
    #expect(ExportTables.all.count == 21)
    #expect(Set(rows.keys) == Set(ExportTables.all), "a file of Export has no rows here")
    for table in [
      ExportTables.accountGroups, ExportTables.transfers, ExportTables.reconciliationBalances,
    ] {
      #expect(!(rows[table] ?? []).isEmpty, "\(table.fileName) is empty")
    }

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-export-pandas-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var paths: [String: ExportTable] = [:]
    for table in ExportTables.all {
      var writer = CSVWriter(columns: table.columns)
      for row in rows[table] ?? [] {
        #expect(row.count == table.columns.count, "\(table.fileName): a row of another width")
        writer.append(row)
      }
      let url = folder.appendingPathComponent(table.fileName)
      try writer.data().write(to: url)
      paths[url.path] = table
    }

    let output = folder.appendingPathComponent("readings.json")
    let run = try Pandas.run(
      python, script: Self.script, arguments: [output.path] + paths.keys.sorted())
    try #require(run.status == 0, "pandas failed: \(run.output)")
    let readings = try JSONDecoder().decode(
      [String: Reading].self, from: Data(contentsOf: output))
    #expect(readings.count == 21)
    for (path, table) in paths.sorted(by: { $0.key < $1.key }) {
      let reading = try #require(readings[path], "pandas did not read \(table.fileName)")
      #expect(reading.rows == (rows[table] ?? []).count, "\(table.fileName): rows")
      #expect(reading.columns == table.columns, "\(table.fileName): columns")
    }
  }

  /// What an owner may type into a name or a note, each of it a way to break a hand-made CSV:
  /// a comma, quotes, line breaks of three kinds, a lone quote, emoji of several scalars,
  /// words pandas takes for a missing value, a leading `#`, spaces at the ends, a formula.
  static let awkward = [
    "Кофе, с молоком", "say \"hi\"", "две\nстроки", "crlf\r\nline", "lone\rcr",
    "☕️ 👨‍👩‍👧", "NA", "null", "nan", "#tag", "  spaced  ", "\"", "=1+2", "ё Ё й",
  ]

  /// The words `read_csv` reads as a missing value by default: it keeps the row and the
  /// column and loses only the word, which is its promise, not the export's.
  static let missingToPandas: Set<String> = ["", "NA", "null", "nan"]

  static let textScript = """
    import json, sys, pandas
    result = {}
    for path in sys.argv[2:]:
        frame = pandas.read_csv(path)
        texts = {}
        for column in ("name", "note"):
            if column in frame.columns:
                texts[column] = [None if pandas.isna(v) else str(v) for v in frame[column]]
        result[path] = {"rows": int(len(frame)), "columns": [str(c) for c in frame.columns],
                        "texts": texts}
    with open(sys.argv[1], "w", encoding="utf-8") as output:
        json.dump(result, output, ensure_ascii=False)
    """

  struct TextReading: Decodable {
    let rows: Int
    let columns: [String]
    let texts: [String: [String?]]
  }

  /// The same 21 files with every name and note of every row replaced by an awkward string —
  /// the accounts' groups, transfers and counts among them — read by pandas with no
  /// parameters: no row is lost or split, the columns stay, and every name and note reads
  /// back as written, except the words pandas takes for a missing value.
  @Test func awkwardNamesAndNotesReadBackWithNoParameters() throws {
    let python = try #require(Pandas.python)
    let set = SampleDataGenerator(seed: 20_260_918).generate(
      months: 6, endingOn: Synthetic.endingOn, calendar: Synthetic.calendar, language: "ru"
    ).withAccounts(seed: 20_260_918, calendar: Synthetic.calendar, language: "ru")
    var rows = Self.rows(of: set)
    var written: [ExportTable: [String: [String]]] = [:]
    var replaced = 0
    for table in ExportTables.all {
      for column in ["name", "note"] {
        guard let index = table.columns.firstIndex(of: column) else { continue }
        var values: [String] = []
        for position in (rows[table] ?? []).indices {
          let value = Self.awkward[(position + replaced) % Self.awkward.count]
          rows[table]?[position][index] = value
          values.append(value)
        }
        replaced += values.count
        written[table, default: [:]][column] = values
      }
    }
    #expect(replaced > Self.awkward.count * 4, "too few names and notes to replace")
    #expect(written[ExportTables.transfers]?["note"]?.isEmpty == false)
    #expect(written[ExportTables.accountGroups]?["name"]?.isEmpty == false)

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-export-awkward-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var paths: [String: ExportTable] = [:]
    for table in ExportTables.all {
      var writer = CSVWriter(columns: table.columns)
      for row in rows[table] ?? [] { writer.append(row) }
      let url = folder.appendingPathComponent(table.fileName)
      try writer.data().write(to: url)
      paths[url.path] = table
    }

    let output = folder.appendingPathComponent("readings.json")
    let run = try Pandas.run(
      python, script: Self.textScript, arguments: [output.path] + paths.keys.sorted())
    try #require(run.status == 0, "pandas failed: \(run.output)")
    let readings = try JSONDecoder().decode(
      [String: TextReading].self, from: Data(contentsOf: output))
    #expect(readings.count == 21)
    for (path, table) in paths.sorted(by: { $0.key < $1.key }) {
      let reading = try #require(readings[path], "pandas did not read \(table.fileName)")
      #expect(reading.rows == (rows[table] ?? []).count, "\(table.fileName): rows")
      #expect(reading.columns == table.columns, "\(table.fileName): columns")
      for (column, values) in written[table] ?? [:] {
        let expected: [String?] = values.map { Self.missingToPandas.contains($0) ? nil : $0 }
        #expect(reading.texts[column] == expected, "\(table.fileName): \(column)")
      }
    }
  }
}
