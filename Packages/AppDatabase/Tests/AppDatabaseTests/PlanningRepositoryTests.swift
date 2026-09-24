import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// MARK: - Fixture

/// One row of every table of the planning, pointing at the references `seedReferences`
/// wrote and at one operation the change itself creates — an income, which the expected
/// income, a journal line and a reconciliation point at.
struct PlanningFixture {
  var income: TransactionEntry
  var rows: PlanningRows

  var subcategory: CoreKit.Category { rows.categories[0] }
  var event: Event { rows.events[0] }
  var goal: Goal { rows.goals[0] }
  var debt: Debt { rows.debts[0] }
  var payment: ScheduledPayment { rows.scheduled[0] }
  var price: SubscriptionPrice { rows.prices[0] }
  var expected: ExpectedIncome { rows.expected[0] }
  var link: ExpectedIncomeLink { rows.expectedLinks[0] }
  var budget: Budget { rows.budgets[0] }
  var line: DebtEntry { rows.debtEntries[0] }
  var reconciliation: Reconciliation { rows.reconciliations[0] }

  /// Everything above as one change, with two settings.
  var change: PlanningChange {
    PlanningChange(
      created: [income], upsert: rows,
      settings: [
        PlanningSettings.reconcileEveryDaysKey: "30",
        PlanningSettings.dismissedRemindersKey: "reconcile\nsched:x:2026-09-01",
      ])
  }

  init(_ references: ReferenceFixture) {
    let incomeTransaction = CoreKit.Transaction(
      kind: .income, occurredAt: PlanningTests.instant(hour: 9),
      amountE4: AmountE4(whole: 70_000), paymentMethodId: references.paymentMethod.id,
      periodMonth: MonthKey(year: 2026, month: 9), createdAt: PlanningTests.instant(hour: 9),
      updatedAt: PlanningTests.instant(hour: 9))
    let income = TransactionEntry(
      transaction: incomeTransaction,
      parts: [
        TransactionPart(transactionId: incomeTransaction.id, amountE4: AmountE4(whole: 70_000))
      ])
    self.income = income

    let subcategory = CoreKit.Category(
      parentId: references.category.id, kind: .expense, name: "Streaming", sort: 4)
    let goal = Goal(
      name: "Laptop", targetE4: AmountE4(whole: 150_000),
      targetDate: DateOnly(year: 2027, month: 3, day: 1),
      monthlyPlanE4: AmountE4(whole: 12_500), subcategoryId: subcategory.id)
    let debt = Debt(
      direction: .owedToMe, type: .personal, name: "Lent to Alex",
      personId: references.person.id, currency: .usd, paymentDay: 10)
    let payment = ScheduledPayment(
      name: "Cinema", kind: .subscription, amountE4: AmountE4(raw: 4_990_000),
      categoryId: subcategory.id, paymentMethodId: references.paymentMethod.id,
      forWhom: .partner, forPersonId: references.person.id, reimbursable: true,
      debtorPersonId: references.person.id, reimbursementAmountE4: AmountE4(whole: 250),
      reimbursementCurrency: .rub, freq: .monthly, interval: 1, day: 12,
      nextDate: DateOnly(year: 2026, month: 10, day: 12),
      trialEnd: DateOnly(year: 2026, month: 9, day: 30), cancelURL: "https://example.com/x",
      remindDaysBefore: 2)
    let expected = ExpectedIncome(
      name: "Salary", categoryId: references.category.id, personId: references.person.id,
      kind: .recurring, totalE4: AmountE4(whole: 140_000),
      dueDate: DateOnly(year: 2026, month: 9, day: 5), freq: .monthly, day: 5,
      partsExpected: 2)
    rows = PlanningRows(
      categories: [subcategory],
      events: [
        Event(
          name: "Birthday", kind: .birthday,
          startDate: DateOnly(year: 2026, month: 11, day: 2),
          endDate: DateOnly(year: 2026, month: 11, day: 2), budgetE4: AmountE4(whole: 8_000))
      ],
      goals: [goal],
      debts: [debt],
      scheduled: [payment],
      prices: [
        SubscriptionPrice(
          paymentId: payment.id, date: DateOnly(year: 2026, month: 11, day: 1),
          amountE4: AmountE4(whole: 599))
      ],
      expected: [expected],
      expectedLinks: [ExpectedIncomeLink(expectedIncomeId: expected.id, transactionId: income.id)],
      budgets: [
        Budget(
          scope: .category, categoryId: subcategory.id, amountE4: AmountE4(whole: 1_000),
          rollover: true, startMonth: MonthKey(year: 2026, month: 9))
      ],
      debtEntries: [
        DebtEntry(
          debtId: debt.id, groupName: "Trip", date: DateOnly(year: 2026, month: 9, day: 1),
          description: "tickets", fullAmountE4: AmountE4(whole: 600),
          share: Decimal(string: "0.5"), amountE4: AmountE4(whole: 300), kind: .borrowed,
          transactionId: income.id, note: "half")
      ],
      reconciliations: [
        Reconciliation(
          date: DateOnly(year: 2026, month: 9, day: 17),
          reconciledAt: PlanningTests.instant(hour: 6),
          actualTotalRubE4: AmountE4(raw: 1_234_567_890),
          expectedTotalRubE4: AmountE4(raw: 1_234_580_235), differenceE4: AmountE4(raw: -12_345),
          transactionId: income.id,
          breakdown: [
            ReconciliationAmount(
              currency: .usd, amountE4: AmountE4(whole: 1_000),
              rubPerUnit: Decimal(string: "81.4321")!, rubE4: AmountE4(raw: 814_321_000)),
            ReconciliationAmount(
              currency: .rub, amountE4: AmountE4(raw: 420_246_890), rubPerUnit: nil,
              rubE4: AmountE4(raw: 420_246_890)),
          ])
      ])
  }
}

/// Everything a planning change can touch, each list in order of id, so two moments compare
/// whatever order the rows were written back in.
struct PlanningSnapshot: Equatable {
  var categories: [CoreKit.Category]
  var events: [Event]
  var goals: [Goal]
  var debts: [Debt]
  var book: PlanningBook
  var entries: [TransactionEntry]
  var settings: [String: String]

  init(_ stack: DatabaseStack) throws {
    let references = ReferenceRepository(writer: stack.writer)
    categories = Self.byId(try references.categories(includeArchived: true))
    events = Self.byId(try references.events(includeArchived: true))
    goals = Self.byId(try references.goals(includeArchived: true))
    debts = Self.byId(try references.debts(includeClosed: true))
    var book = try PlanningRepository(writer: stack.writer).book()
    book.scheduled = Self.byId(book.scheduled)
    book.prices = Self.byId(book.prices)
    book.expected = Self.byId(book.expected)
    book.expectedLinks = Self.byId(book.expectedLinks)
    book.budgets = Self.byId(book.budgets)
    book.reconciliations = Self.byId(book.reconciliations)
    book.debtEntries = Self.byId(book.debtEntries)
    self.book = book
    entries = Self.byId(
      try stack.writer.read { db in
        try TransactionRepository.entries(where: "1", arguments: [], db: db)
      })
    settings = try stack.writer.read { db in
      Dictionary(
        uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT key, value FROM settings").map {
          (row: Row) -> (String, String) in (row["key"], row["value"])
        })
    }
  }

  private static func byId<Element: Identifiable>(_ rows: [Element]) -> [Element]
  where Element.ID == UUID {
    rows.sorted { $0.id.uuidString < $1.id.uuidString }
  }
}

enum PlanningTests {
  /// 17 September 2026 at the hour, UTC, in whole seconds: GRDB keeps instants to the
  /// millisecond, and a whole second compares equal after the trip.
  static func instant(hour: Int, minute: Int = 0) -> Date {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    return utc.date(
      from: DateComponents(year: 2026, month: 9, day: 17, hour: hour, minute: minute))!
  }

  /// A stack with the references and the fixture written.
  static func stackWithFixture() throws -> (DatabaseStack, PlanningFixture) {
    let stack = try TestSupport.makeStack()
    let fixture = PlanningFixture(try TestSupport.seedReferences(stack))
    _ = try PlanningRepository(writer: stack.writer).apply(fixture.change)
    return (stack, fixture)
  }
}

// MARK: - Records

@Suite("Every field of every planning row survives SQLite")
struct PlanningRecordTests {
  @Test func everyRowComesBackAsItWasWritten() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let repository = PlanningRepository(writer: stack.writer)

    #expect(try repository.scheduled() == fixture.rows.scheduled)
    #expect(try repository.expected() == fixture.rows.expected)
    #expect(try repository.budgets() == fixture.rows.budgets)
    #expect(try repository.reconciliations() == fixture.rows.reconciliations)
    let book = try repository.book()
    #expect(book.scheduled == fixture.rows.scheduled)
    #expect(book.prices == fixture.rows.prices)
    #expect(book.expected == fixture.rows.expected)
    #expect(book.expectedLinks == fixture.rows.expectedLinks)
    #expect(book.budgets == fixture.rows.budgets)
    #expect(book.reconciliations == fixture.rows.reconciliations)
    #expect(book.debtEntries == fixture.rows.debtEntries)
    let references = ReferenceRepository(writer: stack.writer)
    #expect(try references.categories().contains(fixture.subcategory))
    #expect(try references.events().contains(fixture.event))
    #expect(try references.goals().contains(fixture.goal))
    #expect(try references.debts().contains(fixture.debt))
  }

  /// A payment with nothing optional set reads back with nothing optional set.
  @Test func aBarePaymentKeepsItsEmptyFields() throws {
    let stack = try TestSupport.makeStack()
    let bare = ScheduledPayment(name: "Rent", amountE4: AmountE4(whole: 50_000))
    let income = ExpectedIncome(name: "Bonus", totalE4: AmountE4(whole: 10_000))
    let limit = Budget(scope: .badTotal, amountE4: AmountE4(whole: 5_000))
    let start = Reconciliation(
      date: DateOnly(year: 2026, month: 1, day: 1), actualTotalRubE4: AmountE4(whole: 1))
    let repository = PlanningRepository(writer: stack.writer)
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          scheduled: [bare], expected: [income], budgets: [limit], reconciliations: [start])))

    #expect(try repository.scheduled() == [bare])
    #expect(try repository.expected() == [income])
    #expect(try repository.budgets() == [limit])
    #expect(try repository.reconciliations() == [start])
  }

  /// The columns hold the plain values of the schema: the instant as GRDB writes every
  /// instant, the month and days as ISO text, the breakdown as the sorted JSON of
  /// `ReconciliationBreakdown`.
  @Test func theColumnsHoldThePlainValuesOfTheSchema() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let reconciliation = try stack.writer.read { db in
      try #require(
        try Row.fetchOne(
          db, sql: "SELECT * FROM reconciliations WHERE id = ?",
          arguments: [fixture.reconciliation.id.uuidString]))
    }
    #expect(reconciliation["reconciled_at"] as String? == "2026-09-17 06:00:00.000")
    #expect(reconciliation["date"] as String? == "2026-09-17")
    #expect(reconciliation["difference_e4"] as Int64? == -12_345)
    #expect(
      reconciliation["breakdown"] as String?
        == #"[{"amount_e4":10000000,"currency":"USD","rub_e4":814321000,"rub_per_unit":"81.4321"},"#
        + #"{"amount_e4":420246890,"currency":"RUB","rub_e4":420246890,"rub_per_unit":null}]"#)

    let budget = try stack.writer.read { db in
      try #require(try Row.fetchOne(db, sql: "SELECT * FROM budgets"))
    }
    #expect(budget["start_month"] as String? == "2026-09")
    #expect(budget["amount_e4"] as Int64? == 10_000_000)
    #expect(budget["category_id"] as String? == fixture.subcategory.id.uuidString)

    let payment = try stack.writer.read { db in
      try #require(try Row.fetchOne(db, sql: "SELECT * FROM scheduled_payments"))
    }
    #expect(payment["next_date"] as String? == "2026-10-12")
    #expect(payment["amount_e4"] as Int64? == 4_990_000)
    #expect(payment["reimbursable"] as Int64? == 1)
  }

  @Test func anEmptyBreakdownIsNull() throws {
    let stack = try TestSupport.makeStack()
    let start = Reconciliation(
      date: DateOnly(year: 2026, month: 1, day: 1), actualTotalRubE4: AmountE4(whole: 1))
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(upsert: PlanningRows(reconciliations: [start])))
    let stored = try stack.writer.read { db in
      try Row.fetchOne(db, sql: "SELECT breakdown, reconciled_at FROM reconciliations")
    }
    #expect(stored?["breakdown"] == nil)
    #expect(stored?["reconciled_at"] == nil)
  }

  // MARK: Settings

  @Test func settingsComeBackAsTheyWereStored() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    #expect(try repository.book().settings == PlanningSettings())

    let chosen = PlanningSettings(
      reconcileEveryDays: 30, savingsTargetBp: 1_500, reserveGoalPlan: false,
      reconcileIncludesGoalSavings: false, dismissedReminders: ["b:2", "a:1"])
    _ = try repository.apply(PlanningChange(settings: chosen.storedValues))
    #expect(try repository.book().settings == chosen)
    let dismissed = try SettingsRepository(writer: stack.writer)
      .string(PlanningSettings.dismissedRemindersKey)
    #expect(dismissed == "a:1\nb:2")
    #expect(
      try SettingsRepository(writer: stack.writer).string(PlanningSettings.reserveGoalPlanKey)
        == "0")

    // No dismissed reminder deletes the key rather than storing an empty value.
    _ = try repository.apply(PlanningChange(settings: PlanningSettings().storedValues))
    #expect(try repository.book().settings == PlanningSettings())
    #expect(
      try SettingsRepository(writer: stack.writer).string(PlanningSettings.dismissedRemindersKey)
        == nil)
  }

  /// A value that does not read keeps the default instead of stopping the planning.
  @Test func anUnreadableSettingKeepsItsDefault() {
    let settings = PlanningSettings(storedValues: [
      PlanningSettings.reconcileEveryDaysKey: "often",
      PlanningSettings.savingsTargetKey: " 2000 ",
      PlanningSettings.reserveGoalPlanKey: "maybe",
      PlanningSettings.reconcileIncludesGoalSavingsKey: "false",
      PlanningSettings.dismissedRemindersKey: "one\r\ntwo\n\n",
    ])
    #expect(settings.reconcileEveryDays == 14)
    #expect(settings.savingsTargetBp == 2_000)
    #expect(settings.reserveGoalPlan == true)
    #expect(settings.reconcileIncludesGoalSavings == false)
    #expect(settings.dismissedReminders == ["one", "two"])

    let senseless = PlanningSettings(storedValues: [
      PlanningSettings.reconcileEveryDaysKey: "0",
      PlanningSettings.savingsTargetKey: "-100",
    ])
    #expect(senseless.reconcileEveryDays == 14)
    #expect(senseless.savingsTargetBp == 1_000)
  }

  // MARK: Limits

  /// One limit per category, per «for whom» value, and one on bad spending
  /// (`idx_budgets_target`).
  @Test func theDatabaseRefusesASecondLimitOnTheSameTarget() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let repository = PlanningRepository(writer: stack.writer)
    let other = CoreKit.Category(kind: .expense, name: "Cafe")
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          categories: [other],
          budgets: [
            Budget(scope: .category, categoryId: references.category.id, amountE4: .init(whole: 1)),
            Budget(scope: .category, categoryId: other.id, amountE4: .init(whole: 2)),
            Budget(scope: .badTotal, amountE4: .init(whole: 3)),
            Budget(scope: .forWhom, forWhom: .friends, amountE4: .init(whole: 4)),
            Budget(scope: .forWhom, forWhom: .partner, amountE4: .init(whole: 5)),
          ])))

    for duplicate in [
      Budget(scope: .category, categoryId: references.category.id, amountE4: .init(whole: 9)),
      Budget(scope: .badTotal, amountE4: .init(whole: 9)),
      Budget(scope: .forWhom, forWhom: .friends, amountE4: .init(whole: 9)),
    ] {
      #expect(throws: (any Error).self) {
        _ = try repository.apply(PlanningChange(upsert: PlanningRows(budgets: [duplicate])))
      }
    }
    #expect(try repository.budgets().count == 5)
  }
}

// MARK: - Apply and revert

@Suite("A planning change is one write and one undo")
struct PlanningUndoTests {
  /// Everything new: undo takes the rows, the operation with its part, the journal line and
  /// the link that point at it, and the settings, and leaves the database as it was.
  @Test func undoOfAChangeThatAddsRowsLeavesNothingBehind() throws {
    let stack = try TestSupport.makeStack()
    let fixture = PlanningFixture(try TestSupport.seedReferences(stack))
    let repository = PlanningRepository(writer: stack.writer)
    let untouched = try PlanningSnapshot(stack)

    let undo = try repository.apply(fixture.change)

    #expect(undo.createdTransactionIds == [fixture.income.id])
    #expect(undo.before == .empty)
    #expect(
      undo.inserted
        == PlanningRowIDs(
          categories: [fixture.subcategory.id], events: [fixture.event.id],
          goals: [fixture.goal.id], debts: [fixture.debt.id], scheduled: [fixture.payment.id],
          prices: [fixture.price.id], expected: [fixture.expected.id],
          expectedLinks: [fixture.link.id], budgets: [fixture.budget.id],
          debtEntries: [fixture.line.id], reconciliations: [fixture.reconciliation.id]))
    #expect(
      undo.settingsBefore
        == [
          PlanningSettings.reconcileEveryDaysKey: nil, PlanningSettings.dismissedRemindersKey: nil,
        ])
    let written = try PlanningSnapshot(stack)
    #expect(written.entries.map(\.id) == [fixture.income.id])
    #expect(written.book.settings.reconcileEveryDays == 30)
    #expect(written.book.settings.dismissedReminders == ["reconcile", "sched:x:2026-09-01"])

    try repository.revert(undo)

    #expect(try PlanningSnapshot(stack) == untouched)
    let leftovers = try stack.writer.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT (SELECT COUNT(*) FROM transactions WHERE id = :id)
            + (SELECT COUNT(*) FROM transaction_parts WHERE transaction_id = :id)
            + (SELECT COUNT(*) FROM debt_entries WHERE transaction_id = :id)
            + (SELECT COUNT(*) FROM expected_income_links WHERE transaction_id = :id)
          """,
        arguments: ["id": fixture.income.id.uuidString])
    }
    #expect(leftovers == 0)
  }

  /// Every row written over: undo writes each back exactly as it was.
  @Test func undoOfAChangeThatEditsRowsPutsEveryFieldBack() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let repository = PlanningRepository(writer: stack.writer)

    var edited = fixture.rows
    edited.categories[0].name = "Streaming and music"
    edited.events[0].budgetE4 = nil
    edited.goals[0].monthlyPlanE4 = AmountE4(whole: 20_000)
    edited.debts[0].closed = true
    edited.scheduled[0].nextDate = DateOnly(year: 2026, month: 11, day: 12)
    edited.scheduled[0].active = false
    edited.prices[0].amountE4 = AmountE4(whole: 649)
    edited.expected[0].closed = true
    edited.expectedLinks[0].transactionId = try seedOperation(stack)
    edited.budgets[0].rollover = false
    edited.budgets[0].startMonth = nil
    edited.debtEntries[0].amountE4 = AmountE4(whole: 250)
    edited.reconciliations[0].breakdown = []
    edited.reconciliations[0].reconciledAt = nil
    let before = try PlanningSnapshot(stack)

    let undo = try repository.apply(
      PlanningChange(
        upsert: edited, settings: [PlanningSettings.reconcileEveryDaysKey: "7"]))

    #expect(undo.inserted == .empty)
    #expect(undo.before == fixture.rows)
    #expect(undo.settingsBefore == [PlanningSettings.reconcileEveryDaysKey: "30"])
    let book = try repository.book()
    #expect(book.scheduled == edited.scheduled)
    #expect(book.reconciliations == edited.reconciliations)
    #expect(book.settings.reconcileEveryDays == 7)

    try repository.revert(undo)

    #expect(try PlanningSnapshot(stack) == before)
  }

  /// Every row deleted: undo brings each back, and the settings key the change deleted.
  @Test func undoOfAChangeThatDeletesRowsBringsThemBack() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let repository = PlanningRepository(writer: stack.writer)
    let before = try PlanningSnapshot(stack)

    let undo = try repository.apply(
      PlanningChange(
        delete: PlanningRowIDs(
          categories: [fixture.subcategory.id], events: [fixture.event.id],
          goals: [fixture.goal.id], debts: [fixture.debt.id], scheduled: [fixture.payment.id],
          prices: [fixture.price.id], expected: [fixture.expected.id],
          expectedLinks: [fixture.link.id], budgets: [fixture.budget.id],
          debtEntries: [fixture.line.id], reconciliations: [fixture.reconciliation.id]),
        settings: [PlanningSettings.dismissedRemindersKey: nil]))

    #expect(undo.inserted == .empty)
    #expect(Set(undo.before.categories) == Set(fixture.rows.categories))
    #expect(undo.before.scheduled == fixture.rows.scheduled)
    #expect(undo.before.prices == fixture.rows.prices)
    #expect(undo.before.reconciliations == fixture.rows.reconciliations)
    #expect(undo.settingsBefore.count == 1)
    let emptied = try repository.book()
    #expect(emptied.scheduled.isEmpty)
    #expect(emptied.prices.isEmpty)
    #expect(emptied.expected.isEmpty)
    #expect(emptied.expectedLinks.isEmpty)
    #expect(emptied.budgets.isEmpty)
    #expect(emptied.reconciliations.isEmpty)
    #expect(emptied.debtEntries.isEmpty)
    #expect(emptied.settings.dismissedReminders.isEmpty)
    // The operation stays: deleting what points at it never touches it.
    #expect(try TransactionRepository(writer: stack.writer).entry(id: fixture.income.id) != nil)

    try repository.revert(undo)

    #expect(try PlanningSnapshot(stack) == before)
  }

  /// Deleting only the parents: the rows the schema cascades the deletion to, or clears, are
  /// read first, so undo gives them back too.
  @Test func undoBringsBackWhatADeletionCascadedToOrCleared() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let repository = PlanningRepository(writer: stack.writer)
    let before = try PlanningSnapshot(stack)

    let undo = try repository.apply(
      PlanningChange(
        delete: PlanningRowIDs(
          categories: [fixture.subcategory.id], debts: [fixture.debt.id],
          scheduled: [fixture.payment.id], expected: [fixture.expected.id])))

    // The price, the link and the journal line went with their parents; the limit went with
    // its category, and the goal lost its subcategory.
    let after = try repository.book()
    #expect(after.prices.isEmpty)
    #expect(after.expectedLinks.isEmpty)
    #expect(after.debtEntries.isEmpty)
    #expect(after.budgets.isEmpty)
    #expect(try ReferenceRepository(writer: stack.writer).goals().first?.subcategoryId == nil)
    #expect(undo.before.prices == fixture.rows.prices)
    #expect(undo.before.expectedLinks == fixture.rows.expectedLinks)
    #expect(undo.before.debtEntries == fixture.rows.debtEntries)
    #expect(undo.before.budgets == fixture.rows.budgets)
    #expect(undo.before.goals == fixture.rows.goals)

    try repository.revert(undo)

    #expect(try PlanningSnapshot(stack) == before)
  }

  /// Deleting a category clears the links of more than the planning: a template of the entry
  /// line, a mapping of the import, a correction of the model (`ON DELETE SET NULL`). ⌘Z
  /// brings the category back, and every one of those links with it.
  @Test func undoOfACategoryDeletionGivesEveryLinkItClearedBack() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let repository = PlanningRepository(writer: stack.writer)
    let category = fixture.subcategory.id.uuidString
    try ReferenceRepository(writer: stack.writer).save(
      Template(text: "cinema", categoryId: fixture.subcategory.id))
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO import_mappings (id, source_kind, source_category, target_category_id)
          VALUES ('mapping', 'expense', 'Кино', ?)
          """,
        arguments: [category])
      try db.execute(
        sql: """
          INSERT INTO category_feedback (id, text, predicted_category_id, chosen_category_id, at)
          VALUES ('feedback', 'кино', ?, ?, '2026-09-24 12:00:00.000')
          """,
        arguments: [category, category])
    }
    func links() throws -> [String?] {
      try stack.writer.read { db in
        [
          try String.fetchOne(db, sql: "SELECT category_id FROM templates"),
          try String.fetchOne(db, sql: "SELECT target_category_id FROM import_mappings"),
          try String.fetchOne(db, sql: "SELECT predicted_category_id FROM category_feedback"),
          try String.fetchOne(db, sql: "SELECT chosen_category_id FROM category_feedback"),
        ]
      }
    }
    let before = try PlanningSnapshot(stack)

    let undo = try repository.apply(
      PlanningChange(delete: PlanningRowIDs(categories: [fixture.subcategory.id])))
    #expect(try links() == [nil, nil, nil, nil])

    try repository.revert(undo)

    #expect(try PlanningSnapshot(stack) == before)
    #expect(
      try links() == [category, category, category, category],
      "templates, import mappings, feedback")
  }

  /// Undo of a category deletion keeps what the list names; the schema is what points. A
  /// column a later migration points at the categories must join the list, or ⌘Z leaves it
  /// empty. Outside the planning's own rows only the link is kept, which is enough only when
  /// the schema clears it rather than deleting the row.
  @Test func theUndoOfACategoryDeletionKnowsEveryColumnThatPointsAtOne() throws {
    let stack = try TestSupport.makeStack()
    let pointing = try stack.writer.read { db in
      var found: [String: String] = [:]
      let tables = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
      for table in tables {
        for key in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))")
        where key["table"] as String == "categories" && key["on_delete"] as String != "RESTRICT" {
          found["\(table).\(key["from"] as String)"] = key["on_delete"]
        }
      }
      return found
    }

    let listed = Set(CoreKit.Category.dependents.map { "\($0.table).\($0.column)" })
    #expect(listed == Set(pointing.keys))
    let keptWhole: Set<String> = [
      "goals", "debts", "scheduled_payments", "expected_income", "budgets",
    ]
    for (column, onDelete) in pointing
    where !keptWhole.contains(String(column.prefix { $0 != "." })) {
      #expect(onDelete == "SET NULL", "\(column) is kept by its link alone")
    }
  }

  /// A row the change both adds and deletes is neither in `before` nor brought back.
  @Test func aRowAddedAndDeletedInOneChangeLeavesNoTrace() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let limit = Budget(scope: .badTotal, amountE4: AmountE4(whole: 5_000))
    let before = try PlanningSnapshot(stack)

    let undo = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(budgets: [limit]), delete: PlanningRowIDs(budgets: [limit.id])))
    #expect(try repository.budgets().isEmpty)
    #expect(undo.before == .empty)

    try repository.revert(undo)
    #expect(try PlanningSnapshot(stack) == before)
  }

  /// A contribution points at its goal: deleting the goal would quietly make it ordinary
  /// spending, so the change is refused and nothing of it is written.
  @Test func aGoalWithOperationsIsNotDeleted() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let repository = PlanningRepository(writer: stack.writer)
    let transaction = CoreKit.Transaction(
      kind: .expense, occurredAt: PlanningTests.instant(hour: 12),
      amountE4: AmountE4(whole: 5_000))
    try TransactionRepository(writer: stack.writer).save(
      TransactionEntry(
        transaction: transaction,
        parts: [
          TransactionPart(
            transactionId: transaction.id, categoryId: fixture.subcategory.id,
            amountE4: AmountE4(whole: 5_000), goalId: fixture.goal.id)
        ]))
    try TransactionRepository(writer: stack.writer).softDelete(id: transaction.id)
    let before = try PlanningSnapshot(stack)

    var renamed = fixture.payment
    renamed.name = "Renamed"
    #expect(throws: PlanningWriteError.referencedByOperations(fixture.goal.id)) {
      _ = try repository.apply(
        PlanningChange(
          upsert: PlanningRows(scheduled: [renamed]),
          delete: PlanningRowIDs(goals: [fixture.goal.id])))
    }
    #expect(try PlanningSnapshot(stack) == before)
  }

  /// «Mark as paid» of the same due date twice — from two windows — writes once: the second
  /// change fails on the unique `external_id` and leaves nothing of itself.
  @Test func oneDueDateIsPaidOnce() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let repository = PlanningRepository(writer: stack.writer)
    let due = DateOnly(year: 2026, month: 10, day: 12)
    func payment() -> PlanningChange {
      let transaction = CoreKit.Transaction(
        kind: .expense, occurredAt: PlanningTests.instant(hour: 10),
        amountE4: fixture.payment.amountE4,
        externalId: OperationLink.scheduled(paymentId: fixture.payment.id, due: due).externalId)
      var moved = fixture.payment
      moved.nextDate = DateOnly(year: 2026, month: 11, day: 12)
      return PlanningChange(
        created: [
          TransactionEntry(
            transaction: transaction,
            parts: [
              TransactionPart(
                transactionId: transaction.id, categoryId: fixture.subcategory.id,
                amountE4: fixture.payment.amountE4)
            ])
        ],
        upsert: PlanningRows(scheduled: [moved]))
    }

    _ = try repository.apply(payment())
    let paid = try PlanningSnapshot(stack)
    #expect(throws: (any Error).self) { _ = try repository.apply(payment()) }
    #expect(try PlanningSnapshot(stack) == paid)
  }

  /// An operation tagged with the new event after the change: undo would quietly untag it,
  /// so it is refused and leaves everything as it is.
  @Test func undoDoesNotCutLooseAnOperationMadeSince() throws {
    let stack = try TestSupport.makeStack()
    let fixture = PlanningFixture(try TestSupport.seedReferences(stack))
    let repository = PlanningRepository(writer: stack.writer)
    let undo = try repository.apply(fixture.change)
    var tagged = try TestSupport.makeEntry(note: "gift")
    tagged.parts[0].eventId = fixture.event.id
    try TransactionRepository(writer: stack.writer).save(tagged)
    let before = try PlanningSnapshot(stack)

    #expect(throws: PlanningWriteError.referencedByOperations(fixture.event.id)) {
      try repository.revert(undo)
    }
    #expect(try PlanningSnapshot(stack) == before)
  }

  @Test func anOperationThatDoesNotAddUpWritesNothing() throws {
    let stack = try TestSupport.makeStack()
    let fixture = PlanningFixture(try TestSupport.seedReferences(stack))
    var change = fixture.change
    change.created[0].parts[0].amountE4 = AmountE4(whole: 1)
    let before = try PlanningSnapshot(stack)

    #expect(throws: DatabaseError.unbalancedParts) {
      _ = try PlanningRepository(writer: stack.writer).apply(change)
    }
    #expect(try PlanningSnapshot(stack) == before)
  }

  /// An operation the fixture does not know about, for a link to be moved to.
  private func seedOperation(_ stack: DatabaseStack) throws -> UUID {
    let entry = try TestSupport.makeEntry(kind: .income, note: "second part")
    try TransactionRepository(writer: stack.writer).save(entry)
    return entry.id
  }
}

// MARK: - Export

@Suite("The planning tables reach the export")
struct PlanningExportTests {
  @Test func everyPlanningTableIsWrittenWithItsRows() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let export = ExportRepository(writer: stack.writer)
    let tables = Dictionary(
      uniqueKeysWithValues: try export.tables().map { ($0.name, $0.data) })
    func rows(_ name: String) throws -> [[String: String]] {
      try CSVReader.dictionaries(from: try #require(tables[name]))
    }

    let payment = try #require(try rows("scheduled_payments").first)
    #expect(payment["id"] == fixture.payment.id.uuidString)
    #expect(payment["amount"] == "499")
    #expect(payment["reimbursement_amount"] == "250")
    #expect(payment["next_date"] == "2026-10-12")

    let price = try #require(try rows("subscription_prices").first)
    #expect(price["payment_id"] == fixture.payment.id.uuidString)
    #expect(price["amount"] == "599")

    let expected = try #require(try rows("expected_income").first)
    #expect(expected["kind"] == "recurring")
    #expect(expected["total"] == "140000")
    #expect(expected["parts_expected"] == "2")

    let budget = try #require(try rows("budgets").first)
    #expect(budget["amount"] == "1000")
    #expect(budget["rollover"] == "true")
    #expect(budget["start_month"] == "2026-09")

    let reconciliation = try #require(try rows("reconciliations").first)
    #expect(reconciliation["actual_total_rub"] == "123456.789")
    #expect(reconciliation["difference"] == "-1.2345")
    #expect(reconciliation["reconciled_at"] == "2026-09-17T06:00:00Z")
    #expect(
      ReconciliationBreakdown.amounts(fromJSON: reconciliation["breakdown"])
        == fixture.reconciliation.breakdown)

    let counts = try export.rowCounts()
    for name in [
      "scheduled_payments", "subscription_prices", "expected_income", "budgets",
      "reconciliations",
    ] {
      #expect(counts[name] == 1, "\(name)")
      #expect(try rows(name).count == 1, "\(name)")
    }
    // The links travel in the archive's database only.
    #expect(tables["expected_income_links"] == nil)
  }
}
