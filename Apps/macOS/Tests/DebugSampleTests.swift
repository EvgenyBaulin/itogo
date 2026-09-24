#if DEBUG

  import AppCore
  import AppDatabase
  import XCTest

  @testable import Itogo

  /// The Debug menu writes the sample in one transaction, so a record refused by the
  /// database leaves the whole sample out (and only a journal line behind). This proves the
  /// whole sample lands next to the starter tree the app has already seeded, and next to a
  /// sample of another length written before it.
  final class DebugSampleTests: XCTestCase {
    func testTheWholeSampleLandsNextToTheStarterTree() throws {
      let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
      let references = ReferenceRepository(writer: stack.writer)
      let transactions = TransactionRepository(writer: stack.writer)
      try references.seedCategoriesIfEmpty(StarterCategories.tree(language: "en"))
      let set = SampleDataGenerator(seed: 20_260_918).generate(
        months: 6, endingOn: DateOnly(year: 2026, month: 9, day: 18), calendar: .utc,
        language: "en")

      try DebugCommands.write(set, references: references, transactions: transactions)

      let counts = try ExportRepository(writer: stack.writer).rowCounts()
      XCTAssertEqual(counts["transactions"], set.entries.count)
      XCTAssertEqual(counts["reimbursement_links"], set.links.count)
      XCTAssertEqual(counts["debts"], set.debts.count)
      XCTAssertEqual(counts["debt_entries"], set.debtEntries.count)
      XCTAssertEqual(counts["goals"], set.goals.count)
      // Analytics counts cashback in the sample's own «Cashback», set in the same write.
      XCTAssertEqual(
        try SettingsRepository(writer: stack.writer).string(AnalyticsSettings.cashbackCategoryKey),
        set.cashbackCategoryId.uuidString)

      // The sample took the seeded system categories instead of adding its own.
      let roles = try references.categories(includeArchived: true).compactMap { category in
        category.systemRole.map { "\($0.rawValue) \(category.kind.rawValue)" }
      }
      XCTAssertEqual(roles.count, Set(roles).count)
      // Goals, Loans and Unknown among expenses; Surcharges and Unknown among income.
      XCTAssertEqual(Set(roles).count, 5)

      // Only the purchases the sample left waiting are owed — not the refund of a ticket
      // bought for a friend, which the app writes with the same flag.
      let waiting = set.entries
        .filter { !$0.transaction.isDeleted && $0.transaction.kind == .expense }
        .flatMap(\.parts)
        .filter { $0.reimbursable && $0.reimbursementStatus == .expected }.map(\.id)
      XCTAssertFalse(waiting.isEmpty)
      XCTAssertEqual(Set(try transactions.owedParts().map(\.partId)), Set(waiting))
    }

    /// «Generate sample data», then «Generate sample data (12 months)»: the second history
    /// pays the rent on the dates the first one paid, with operations of other ids. It lands
    /// whole, and each month's rent is paid once.
    func testALongerSampleLandsNextToAShorterOne() throws {
      let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
      let references = ReferenceRepository(writer: stack.writer)
      let transactions = TransactionRepository(writer: stack.writer)
      try references.seedCategoriesIfEmpty(StarterCategories.tree(language: "en"))
      let end = DateOnly(year: 2026, month: 9, day: 18)
      let generator = SampleDataGenerator(seed: 20_260_918)
      let short = generator.generate(months: 6, endingOn: end, calendar: .utc, language: "en")
      let long = generator.generate(months: 12, endingOn: end, calendar: .utc, language: "en")

      try DebugCommands.write(short, references: references, transactions: transactions)
      try DebugCommands.write(long, references: references, transactions: transactions)

      XCTAssertEqual(
        try transactions.entries(ids: long.entries.map(\.id)).count, long.entries.count)
      let rents = try transactions.entries(from: .distantPast, to: .distantFuture)
        .compactMap(\.transaction.externalId).filter { $0.hasPrefix("sched:") }
      let longRents = long.entries.compactMap(\.transaction.externalId)
        .filter { $0.hasPrefix("sched:") }
      XCTAssertEqual(rents.count, Set(rents).count)
      XCTAssertEqual(Set(rents), Set(longRents))
    }
  }

#endif
