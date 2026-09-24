import AppCore
import AppDatabase
import XCTest

@testable import Itogo

/// What a reconciliation writes, against a real database.
///
/// The counted total is the truth; the difference between it and what the books expected is
/// an operation of the day of the reconciliation — an expense when money is missing, income
/// when there is more than expected — in a category of its own, «Сверка».
@MainActor
final class ReconciliationFlowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["ITOGO_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-reconcile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("ITOGO_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    compute = ComputeStore(calendar: .system, rebuildsInline: true)
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("ITOGO_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("ITOGO_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private var deps: AppDependencies {
    AppDependencies(environment: environment, store: store, compute: compute)
  }

  private var actions: PlanningActions { PlanningActions(deps) }

  /// The name the categories are made with, in whatever language the run is in.
  private var reconciliationName: String {
    environment.language("categories.reconciliation", table: "Settings")
  }

  func testTheFirstReconciliationIsTheStartingPointAndWritesNothing() throws {
    XCTAssertTrue(
      actions.reconcile(
        actual: AmountE4(whole: 50_000), breakdown: [], expectation: nil,
        recordDifference: false))

    let book = try XCTUnwrap(environment.planning).book()
    XCTAssertEqual(book.reconciliations.count, 1)
    XCTAssertNil(book.reconciliations.first?.transactionId, "a starting point wrote an operation")
    let written = try XCTUnwrap(environment.transactions)
      .entries(from: .distantPast, to: .distantFuture)
    XCTAssertTrue(written.isEmpty)
  }

  func testMoneyMissingIsAnExpenseInItsOwnCategoryOnTheDayOfTheReconciliation() throws {
    let where_ = try XCTUnwrap(actions.reconciliationCategories())
    let categories = try XCTUnwrap(environment.references).categories()
    let expense = try XCTUnwrap(categories.first { $0.id == where_.expense })
    XCTAssertEqual(expense.name, reconciliationName)
    XCTAssertEqual(expense.kind, .expense)
    XCTAssertNil(expense.parentId, "the category of a reconciliation is not a subcategory")
    XCTAssertNil(expense.systemRole, "it is an ordinary category the owner may rename")

    let when = Date()
    let expectation = ReconciliationExpectation(
      previous: Reconciliation(
        date: environment.calendar.day(of: when), actualTotalRubE4: AmountE4(whole: 50_000)),
      from: when.addingTimeInterval(-3600), to: when, lines: [],
      expected: AmountE4(whole: 50_000))
    XCTAssertTrue(
      actions.reconcile(
        actual: AmountE4(whole: 48_500), breakdown: [], expectation: expectation,
        recordDifference: true, now: when))

    let written = try XCTUnwrap(environment.transactions)
      .entries(from: .distantPast, to: .distantFuture)
    XCTAssertEqual(written.count, 1)
    let entry = try XCTUnwrap(written.first)
    XCTAssertEqual(entry.transaction.kind, .expense)
    XCTAssertEqual(entry.transaction.amountE4, AmountE4(whole: 1_500))
    XCTAssertEqual(
      environment.calendar.day(of: entry.transaction.occurredAt),
      environment.calendar.day(of: when),
      "the difference is dated the day of the reconciliation")
    XCTAssertEqual(entry.parts.map(\.categoryId), [where_.expense])
  }

  func testMoreMoneyThanExpectedIsIncomeInTheSameCategoryOfItsKind() throws {
    let where_ = try XCTUnwrap(actions.reconciliationCategories())
    let when = Date()
    let expectation = ReconciliationExpectation(
      previous: Reconciliation(
        date: environment.calendar.day(of: when), actualTotalRubE4: AmountE4(whole: 10_000)),
      from: when.addingTimeInterval(-3600), to: when, lines: [],
      expected: AmountE4(whole: 10_000))
    XCTAssertTrue(
      actions.reconcile(
        actual: AmountE4(whole: 10_700), breakdown: [], expectation: expectation,
        recordDifference: true, now: when))

    let entry = try XCTUnwrap(
      try XCTUnwrap(environment.transactions)
        .entries(from: .distantPast, to: .distantFuture).first)
    XCTAssertEqual(entry.transaction.kind, .income)
    XCTAssertEqual(entry.transaction.amountE4, AmountE4(whole: 700))
    XCTAssertEqual(entry.parts.map(\.categoryId), [where_.income])
    let income = try XCTUnwrap(
      try XCTUnwrap(environment.references).categories().first { $0.id == where_.income })
    XCTAssertEqual(income.kind, .income)
    XCTAssertEqual(income.name, reconciliationName)
  }

  /// «Записать разницу» that cannot write the difference is a failure the sheet shows, not a
  /// reconciliation saved without it: the owner asked for the operation, and a sheet that
  /// closed as if it were there would leave the books short by the difference.
  func testADifferenceThatCannotBeWrittenSavesNothing() async throws {
    // A database that refuses to make «Сверка», in either language.
    await environment.close()
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: RefusingTheReconciliationCategory())
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    let when = Date()
    let expectation = ReconciliationExpectation(
      previous: Reconciliation(
        date: environment.calendar.day(of: when), actualTotalRubE4: AmountE4(whole: 50_000)),
      from: when.addingTimeInterval(-3600), to: when, lines: [],
      expected: AmountE4(whole: 50_000))

    XCTAssertFalse(
      actions.reconcile(
        actual: AmountE4(whole: 48_500), breakdown: [], expectation: expectation,
        recordDifference: true, now: when),
      "the difference was not written, and the reconciliation said it was saved")
    XCTAssertEqual(
      try XCTUnwrap(environment.planning).book().reconciliations.count, 0,
      "saved without the difference that was asked for")
    XCTAssertTrue(
      try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
        .isEmpty)
  }

  /// And the sheet says why, in both languages.
  func testTheReasonOfAnUnwrittenDifferenceIsTranslated() {
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let text = environment.language("reconcile.notRecorded", table: "Planning")
      XCTAssertNotEqual(text, "reconcile.notRecorded", "\(choice)")
    }
    environment.language.choice = .russian
  }

  /// The sheet counts the expectation for a moment, and the reconciliation saved against it is
  /// stamped with that moment: the next window starts where this one ended. Stamped with the
  /// later instant of saving, an operation dated in between — the coffee entered through
  /// «Найти пропущенные…» while the sheet stood open — fell into neither window and was paid
  /// for twice: once itself, and once as the difference.
  func testTheNextWindowStartsWhereTheExpectationOfThisOneEnded() throws {
    let opened = Date()
    XCTAssertTrue(
      actions.reconcile(
        actual: AmountE4(whole: 50_000), breakdown: [], expectation: nil,
        recordDifference: false, now: opened.addingTimeInterval(-120)))
    let shown = try XCTUnwrap(expectation(at: opened))
    XCTAssertEqual(shown.expected, AmountE4(whole: 50_000))

    try spend(250, at: opened.addingTimeInterval(60))
    XCTAssertTrue(
      actions.reconcile(
        actual: AmountE4(whole: 49_750), breakdown: [], expectation: shown,
        recordDifference: true, now: opened.addingTimeInterval(120)))

    let book = try XCTUnwrap(environment.planning).book()
    let saved = try XCTUnwrap(ReconciliationRules.latest(book.reconciliations))
    // The database keeps an instant to the millisecond.
    XCTAssertEqual(
      try XCTUnwrap(saved.reconciledAt).timeIntervalSince(shown.to), 0, accuracy: 0.001,
      "stamped later than its expectation counted")
    let next = try XCTUnwrap(expectation(at: opened.addingTimeInterval(180)))
    XCTAssertEqual(
      next.lines.first { $0.term == .myExpenses }?.amount, AmountE4(whole: 250),
      "the coffee fell between two windows")
  }

  /// What the sheet counts, from what is in the database now.
  private func expectation(at now: Date) throws -> ReconciliationExpectation? {
    let entries = try XCTUnwrap(environment.transactions)
      .entries(from: .distantPast, to: .distantFuture)
    let book = try XCTUnwrap(environment.planning).book()
    let ledger = Ledger(
      dataset: Dataset(
        entries: entries, categories: try XCTUnwrap(environment.references).categories(),
        planning: book),
      calendar: .system)
    return ReconciliationRules.expectation(
      ledger: ledger, book: book, now: now, calendar: .system)
  }

  /// An expense of `rubles` in the first expense category there is, made at `when`.
  private func spend(_ rubles: Int, at when: Date) throws {
    let category = try XCTUnwrap(
      try XCTUnwrap(environment.references).categories().first {
        $0.kind == .expense && $0.systemRole == nil
      })
    let id = UUID()
    let amount = AmountE4(whole: Int64(rubles))
    try XCTUnwrap(environment.transactions).save(
      TransactionEntry(
        transaction: Transaction(
          id: id, kind: .expense, occurredAt: when, amountE4: amount, amountRubE4: amount,
          createdAt: when, updatedAt: when),
        parts: [
          TransactionPart(
            transactionId: id, categoryId: category.id, quality: .neutral,
            qualitySource: .category, amountE4: amount, amountRubE4: amount)
        ]))
  }

  func testTheCategoryIsMadeOnceAndFoundAgainEvenAfterItIsRenamed() throws {
    let first = try XCTUnwrap(actions.reconciliationCategories())
    let references = try XCTUnwrap(environment.references)
    var expense = try XCTUnwrap(references.categories().first { $0.id == first.expense })
    expense.name = "Расхождения"
    try references.save(expense)

    let again = try XCTUnwrap(actions.reconciliationCategories())
    XCTAssertEqual(again.expense, first.expense, "a renamed category was made a second time")
    XCTAssertEqual(again.income, first.income)
    XCTAssertEqual(
      try references.categories().filter { $0.name == "Расхождения" }.count, 1,
      "the renamed category was duplicated")
  }

  /// A reconciliation the store refuses leaves the sheet open — the counted money is still in
  /// it — and says that nothing was saved, instead of a button that did nothing.
  func testARefusedReconciliationSaysItWasNotSaved() throws {
    let detached = AppDependencies(
      environment: environment, store: TransactionsStore(), compute: compute)
    let failure = ReconcileSheet.save(
      actual: AmountE4(whole: 1_000), breakdown: [], expectation: nil, record: false,
      dependencies: detached)

    XCTAssertEqual(failure, "reconcile.notSaved", "a refused reconciliation said nothing")
    XCTAssertEqual(try XCTUnwrap(environment.planning).book().reconciliations, [])
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      XCTAssertNotEqual(language("reconcile.notSaved", table: "Planning"), "reconcile.notSaved")
    }

    XCTAssertNil(
      ReconcileSheet.save(
        actual: AmountE4(whole: 1_000), breakdown: [], expectation: nil, record: false,
        dependencies: deps))
    XCTAssertEqual(try XCTUnwrap(environment.planning).book().reconciliations.count, 1)
  }

  /// × on a reminder puts it off, a preference of the reminders rather than a change of the
  /// books: it takes no step of ⌘Z. With one, the ⌘Z the owner meant for the operation he
  /// had just written brought the reminder back instead.
  func testPuttingOffAReminderTakesNoStepOfUndo() throws {
    let reminder = Reminder(
      id: "reconcile:none", kind: .reconciliation, due: nil, subjectId: nil, urgency: .today)
    XCTAssertTrue(actions.dismiss(reminder))

    XCTAssertEqual(
      try environment.settings?.string(PlanningSettings.dismissedRemindersKey), "reconcile:none")
    XCTAssertFalse(store.canUndo, "putting a reminder off became a step of ⌘Z")
  }

  /// «Сверка» is an ordinary category, so the owner can put it in the archive — and the next
  /// reconciliation must bring it back rather than quietly make a second one beside it.
  func testAnArchivedCategoryIsBroughtBackRatherThanDuplicated() throws {
    let first = try XCTUnwrap(actions.reconciliationCategories())
    let references = try XCTUnwrap(environment.references)
    var expense = try XCTUnwrap(references.categories().first { $0.id == first.expense })
    expense.archived = true
    try references.save(expense)

    let again = try XCTUnwrap(actions.reconciliationCategories())
    XCTAssertEqual(again.expense, first.expense, "a second «Сверка» was made beside the first")
    XCTAssertEqual(again.income, first.income)
    XCTAssertFalse(
      try XCTUnwrap(references.categories(includeArchived: true).first { $0.id == first.expense })
        .archived,
      "the category the app writes into was left in the archive")
    XCTAssertEqual(
      try references.categories(includeArchived: true)
        .filter { $0.name == reconciliationName && $0.kind == .expense }.count, 1)
  }

  /// «Бэкапы, экспорт, архив, сверка: начало, результат, размер файла, число записей».
  /// A reconciliation says in the journal that it began, that it was saved and how many
  /// operations it wrote — and never one of its amounts.
  func testAReconciliationIsInTheJournalWithoutItsAmounts() throws {
    let logs = directory.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Logbook.shared.close() }
    let when = Date()
    let expectation = ReconciliationExpectation(
      previous: Reconciliation(
        date: environment.calendar.day(of: when),
        actualTotalRubE4: try AmountE4(decimal: Decimal(string: "50123.45")!)),
      from: when.addingTimeInterval(-3600), to: when, lines: [],
      expected: try AmountE4(decimal: Decimal(string: "50123.45")!))
    let cash = try AmountE4(decimal: Decimal(string: "17293.17")!)
    let card = try AmountE4(decimal: Decimal(string: "31224.76")!)
    let breakdown = [
      ReconciliationAmount(currency: .rub, amountE4: cash, rubPerUnit: nil, rubE4: cash),
      ReconciliationAmount(currency: .rub, amountE4: card, rubPerUnit: nil, rubE4: card),
    ]
    XCTAssertTrue(
      actions.reconcile(
        actual: try AmountE4(decimal: Decimal(string: "48517.93")!), breakdown: breakdown,
        expectation: expectation, recordDifference: true, now: when))

    let lines = Logbook.shared.lines()
    XCTAssertTrue(
      lines.contains {
        $0.contains(" reconcile.started ")
          && $0.hasSuffix(" breakdown=2 expectation=yes record=yes")
      },
      "the journal does not say a reconciliation began: \(lines)")
    XCTAssertTrue(
      lines.contains { $0.contains(" reconcile.saved ") && $0.hasSuffix(" operations=1") },
      "the journal does not say the reconciliation was saved: \(lines)")
    let secrets = ["48 517,93", "50 123,45", "1 605,52", "17 293,17", "31 224,76"]
    XCTAssertEqual(LogPrivacy.offences(inLines: lines, forbidding: secrets), [])
  }
}

/// What the sheet lets be saved as the counted total. The field starts empty, which reads as
/// zero, and Return presses «Записать разницу»: an untouched sheet would write the whole
/// expected balance off as an expense (review of the settings and planning UI, 24.09).
@MainActor
final class ReconcileSheetInputTests: XCTestCase {
  private let rates: [CurrencyCode: Decimal] = [.usd: Decimal(string: "90.5")!]

  func testAnUntouchedFieldIsNothingCountedYet() {
    XCTAssertNil(
      ReconcileSheet.counted(byCurrency: false, total: .zero, amounts: [:], rubPerUnit: rates))
    XCTAssertNil(
      ReconcileSheet.counted(byCurrency: true, total: .zero, amounts: [:], rubPerUnit: rates))
    XCTAssertNil(
      ReconcileSheet.counted(
        byCurrency: true, total: .zero, amounts: [.rub: .zero, .usd: .zero], rubPerUnit: rates))
  }

  /// The field evaluates «−100» as well as «100»; money on hand is never below zero.
  func testANegativeAmountIsNotMoneyOnHand() {
    XCTAssertNil(
      ReconcileSheet.counted(
        byCurrency: false, total: AmountE4(whole: -100), amounts: [:], rubPerUnit: rates))
    XCTAssertNil(
      ReconcileSheet.counted(
        byCurrency: true, total: .zero,
        amounts: [.rub: AmountE4(whole: 50_000), .usd: AmountE4(whole: -10)], rubPerUnit: rates))
  }

  func testATypedAmountIsCountedInRubles() {
    XCTAssertEqual(
      ReconcileSheet.counted(
        byCurrency: false, total: AmountE4(whole: 312_450), amounts: [:], rubPerUnit: rates),
      AmountE4(whole: 312_450))
    XCTAssertEqual(
      ReconcileSheet.counted(
        byCurrency: true, total: .zero,
        amounts: [.rub: AmountE4(whole: 1_000), .usd: AmountE4(whole: 100)], rubPerUnit: rates),
      AmountE4(whole: 10_050))
  }

  /// And a currency without a rate is still not guessed.
  func testACurrencyWithoutARateIsNotCounted() {
    XCTAssertNil(
      ReconcileSheet.counted(
        byCurrency: true, total: .zero, amounts: [.usd: AmountE4(whole: 100)], rubPerUnit: [:]))
  }
}

/// The migrations of the bundle, and one more that makes the database refuse a category named
/// as the reconciliation's is, in either language.
private struct RefusingTheReconciliationCategory: SchemaSource {
  func migrations() throws -> [SchemaMigration] {
    try BundleSchemaSource(bundle: .main).migrations() + [
      SchemaMigration(
        name: "9999_test_refuse_reconciliation",
        sql: """
          CREATE TRIGGER refuse_reconciliation BEFORE INSERT ON categories
          WHEN NEW.name IN ('Сверка', 'Reconciliation')
          BEGIN SELECT RAISE(ABORT, 'refused by the test'); END;
          """)
    ]
  }
}
