import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

@Suite("The sample's planning lands with its history, in the same write")
struct SamplePlanningStorageTests {
  private static let today = TestSupport.sampleEnd

  /// Every row of the planning comes back as it was generated, next to the history.
  @Test func aSampleLandsWithItsPlanning() async throws {
    let stack = try TestSupport.makeStack()
    let set = TestSupport.sample()
    let planning = set.planning
    // This history has a side job in its last two months: the prepayment is linked.
    #expect(planning.expectedLinks.count == 1)
    try TransactionRepository(writer: stack.writer).insert(HistoryBatch(sample: set))

    let book = try PlanningRepository(writer: stack.writer).book()
    #expect(Set(book.scheduled) == Set(planning.scheduled))
    #expect(Set(book.prices) == Set(planning.prices))
    #expect(book.expected == planning.expected)
    #expect(book.expectedLinks == planning.expectedLinks)
    #expect(book.budgets == planning.budgets)
    #expect(book.reconciliations.isEmpty)
    #expect(Set(book.debtEntries) == Set(set.debtEntries))

    let counts = try ExportRepository(writer: stack.writer).rowCounts()
    #expect(counts["scheduled_payments"] == 5)
    #expect(counts["subscription_prices"] == 2)
    #expect(counts["expected_income"] == 1)
    #expect(try Self.count("expected_income_links", in: stack) == planning.expectedLinks.count)
    #expect(counts["budgets"] == 2)
    #expect(counts["reconciliations"] == 0)
    #expect(counts["transactions"] == set.entries.count)

    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 1)
    #expect(dataset.planning == book)
  }

  /// The planning read back from the database is what the core counts on the Planning
  /// screen: five payments due from today on, the cloud's price change reminded, the music
  /// paid for Kim split into 250 back and 49 mine, two limits, the expected income with its
  /// prepayment — and the first reconciliation still to make.
  @Test func theStoredPlanningIsWhatThePlanningScreenCounts() async throws {
    let stack = try TestSupport.makeStack()
    let set = TestSupport.sample()
    try TransactionRepository(writer: stack.writer).insert(HistoryBatch(sample: set))
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 1)
    let ledger = Ledger(dataset: dataset, calendar: TestSupport.sampleCalendar)
    let book = dataset.planning

    for payment in book.scheduled {
      #expect(ScheduledRules.validate(payment, tree: ledger.tree) == nil)
    }
    let statuses = ScheduledRules.statuses(
      book: book, ledger: ledger, today: Self.today, rubPerUnit: [.usd: 95])
    #expect(statuses.count == 5)
    #expect(statuses.allSatisfy { !$0.isOverdue && !$0.isWithoutRate })
    let byName = Dictionary(uniqueKeysWithValues: statuses.map { ($0.payment.name, $0) })
    #expect(byName["Apartment rent"]?.amountNext == AmountE4(whole: 45_000))
    #expect(byName["Apartment rent"]?.nextDue == DateOnly(year: 2026, month: 10, day: 1))
    #expect(byName["Cloud storage"]?.amountNext == AmountE4(whole: 249))
    #expect(byName["Music subscription"]?.expectedReturnRubNext == AmountE4(whole: 250))
    #expect(byName["Music subscription"]?.myShareRubNext == AmountE4(whole: 49))
    #expect(byName["Domain and hosting"]?.myShareRubNext == AmountE4(whole: 4_560))

    let reminders = ReminderRules.build(
      book: book, debts: dataset.debts, ledger: ledger, today: Self.today)
    let cloud = try #require(book.scheduled.first { $0.name == "Cloud storage" })
    #expect(reminders.contains { $0.kind == .priceChange && $0.subjectId == cloud.id })
    #expect(reminders.contains { $0.id == "reconcile:none" })

    let limits = LimitRules.lines(book: book, ledger: ledger, today: Self.today)
    #expect(limits.map(\.budget.scope) == [.category, .badTotal])
    #expect(limits.allSatisfy { $0.month == Self.today.monthKey })

    let expected = ExpectedIncomeRules.statuses(book: book, ledger: ledger, today: Self.today)
    let website = try #require(expected.first)
    #expect(expected.count == 1)
    #expect(website.partsExpected == 2)
    #expect(website.partsReceived == book.expectedLinks.count)
    #expect(website.linkedTransactionIds == book.expectedLinks.map(\.transactionId))
    #expect(!website.isFulfilled)
    #expect(!website.isOverdue)
  }

  /// The Debug menu writes the same seed again: the planning is written over its own rows.
  @Test func savingTheSampleTwiceWritesOverItsOwnPlanning() throws {
    let stack = try TestSupport.makeStack()
    let set = TestSupport.sample(months: 2)
    let transactions = TransactionRepository(writer: stack.writer)
    try transactions.save(HistoryBatch(sample: set))
    try transactions.save(HistoryBatch(sample: set))

    let counts = try ExportRepository(writer: stack.writer).rowCounts()
    #expect(counts["scheduled_payments"] == 5)
    #expect(counts["subscription_prices"] == 2)
    #expect(counts["expected_income"] == 1)
    #expect(
      try Self.count("expected_income_links", in: stack) == set.planning.expectedLinks.count)
    #expect(counts["budgets"] == 2)
    #expect(counts["transactions"] == set.entries.count)
  }

  /// The Debug menu writes the same seed as a longer history, or after the month has
  /// turned: the operations are new ids, but the rent pays the same payment on the same due
  /// dates, and `sched:<payment>:<date>` is unique. The new history lands whole, its rent
  /// taking each due date over, so every date is paid once.
  @Test(arguments: [
    (TestSupport.sampleEnd, 2, TestSupport.sampleEnd, 4),
    (TestSupport.sampleEnd, 2, DateOnly(year: 2026, month: 10, day: 3), 2),
  ])
  func anotherHistoryOfTheSameSeedTakesTheRentsDueDatesOver(
    firstEnd: DateOnly, firstMonths: Int, secondEnd: DateOnly, secondMonths: Int
  ) throws {
    let stack = try TestSupport.makeStack()
    let first = TestSupport.sample(months: firstMonths, endingOn: firstEnd)
    let second = TestSupport.sample(months: secondMonths, endingOn: secondEnd)
    let transactions = TransactionRepository(writer: stack.writer)
    try transactions.save(HistoryBatch(sample: first))

    let keyed = second.entries.filter { $0.transaction.externalId?.hasPrefix("sched:") == true }
    let taken = Set(keyed.compactMap(\.transaction.externalId))
    let replaced = first.entries.filter { entry in
      entry.transaction.externalId.map(taken.contains) == true
        && !second.entries.contains { $0.id == entry.id }
    }
    // The case the test is about: the first history holds due dates the second pays with
    // operations of other ids.
    #expect(!replaced.isEmpty)

    try transactions.save(HistoryBatch(sample: second))

    let stored = try transactions.entries(ids: second.entries.map(\.id))
    #expect(stored.count == second.entries.count)
    for entry in keyed {
      let holder = try stack.writer.read { db in
        try String.fetchAll(
          db, sql: "SELECT id FROM transactions WHERE external_id = ?",
          arguments: [entry.transaction.externalId])
      }
      #expect(holder == [entry.id.uuidString])
    }
    #expect(try transactions.entries(ids: replaced.map(\.id)).isEmpty)
    let firstIds = Set(first.entries.map(\.id)).subtracting(replaced.map(\.id))
    #expect(
      try Self.count("transactions", in: stack)
        == firstIds.union(second.entries.map(\.id)).count)
  }

  /// A limit on bad spending the owner set already holds the target: the Debug menu keeps it
  /// and leaves the sample's out, and writes the rest. Written as new rows, the same sample
  /// fails whole, the history with it.
  @Test func theOwnersOwnLimitOnBadSpendingStays() throws {
    let stack = try TestSupport.makeStack()
    let set = TestSupport.sample(months: 2)
    let own = Budget(scope: .badTotal, amountE4: AmountE4(whole: 3_000))
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(upsert: PlanningRows(budgets: [own])))
    let transactions = TransactionRepository(writer: stack.writer)

    #expect(throws: (any Error).self) { try transactions.insert(HistoryBatch(sample: set)) }
    #expect(try transactions.count() == 0)
    #expect(try PlanningRepository(writer: stack.writer).scheduled().isEmpty)

    try transactions.save(HistoryBatch(sample: set))
    let budgets = try PlanningRepository(writer: stack.writer).budgets()
    let sampleLimit = try #require(set.planning.budgets.first { $0.scope == .category })
    #expect(budgets == [own, sampleLimit])
    #expect(try PlanningRepository(writer: stack.writer).scheduled().count == 5)
    #expect(try transactions.count() > 0)
  }

  /// The cashback category of Analytics goes in with the history, in the same write: a
  /// sample that lands has it, one that is refused leaves the setting as it was.
  @Test func aSampleLandsWithItsCashbackCategory() throws {
    let stack = try TestSupport.makeStack()
    let set = TestSupport.sample(months: 2)
    let settings = SettingsRepository(writer: stack.writer)
    let transactions = TransactionRepository(writer: stack.writer)
    let own = Budget(scope: .badTotal, amountE4: AmountE4(whole: 3_000))
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(upsert: PlanningRows(budgets: [own])))

    #expect(throws: (any Error).self) { try transactions.insert(HistoryBatch(sample: set)) }
    #expect(try settings.string(AnalyticsSettings.cashbackCategoryKey) == nil)

    try transactions.save(HistoryBatch(sample: set))
    #expect(
      try settings.string(AnalyticsSettings.cashbackCategoryKey)
        == set.cashbackCategoryId.uuidString)
  }

  /// The batch the sample makes carries the rows of its history as the field-by-field batch
  /// always did, and the planning on top.
  @Test func theBatchOfASampleIsItsHistoryAndItsPlanning() {
    let set = TestSupport.sample(months: 2)
    let batch = HistoryBatch(sample: set)
    let history = TestSupport.batch(set)
    let planning = set.planning

    #expect(batch.categories == history.categories)
    #expect(batch.people == history.people)
    #expect(batch.places == history.places)
    #expect(batch.paymentMethods == history.paymentMethods)
    #expect(batch.events == history.events)
    #expect(batch.templates == history.templates)
    #expect(batch.goals == history.goals)
    #expect(batch.debts == history.debts)
    #expect(batch.entries == history.entries)
    #expect(batch.debtEntries == history.debtEntries)
    #expect(batch.links == history.links)
    #expect(batch.scheduled == planning.scheduled)
    #expect(batch.prices == planning.prices)
    #expect(batch.expected == planning.expected)
    #expect(batch.expectedLinks == planning.expectedLinks)
    #expect(batch.budgets == planning.budgets)
  }

  /// Rows of a table the export leaves out.
  private static func count(_ table: String, in stack: DatabaseStack) throws -> Int {
    try stack.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }
  }
}
