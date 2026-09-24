import AppCore
import AppDatabase
import XCTest

@testable import Itogo

/// The actions of Planning end to end against a database (Планирование: «Mark
/// as paid» для подписки за другого; Цели: «Contribute» создаёт хороший расход в подкатегории
/// цели): each is one write, and one ⌘Z takes all of it back.
@MainActor
final class PlanningFlowTests: XCTestCase {
  private var store: TransactionsStore!
  private var transactions: TransactionRepository!
  private var references: ReferenceRepository!
  private var planning: PlanningRepository!
  private var compute: ComputeStore!
  private let today = DateOnly(year: 2026, month: 9, day: 19)

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    transactions = TransactionRepository(writer: stack.writer)
    references = ReferenceRepository(writer: stack.writer)
    planning = PlanningRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(transactions, references: references, planning: planning)
    compute = ComputeStore(calendar: .utc, rebuildsInline: true)
  }

  private var deps: AppDependencies {
    AppDependencies(environment: AppEnvironment(), store: store, compute: compute)
  }

  /// The data the actions read — the tree of categories — as the pipeline would show it.
  private func show(
    categories: [CoreKit.Category], goals: [Goal] = [], budgets: [Budget] = []
  ) {
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(
          categories: categories, goals: goals, planning: PlanningBook(budgets: budgets)),
        calendar: .utc, today: today, context: SnapshotContext(), version: DataVersion(load: 0)))
  }

  func testMarkAsPaidForSomebodyElseLeavesAPartWaitingAndOneUndoTakesItBack() throws {
    let anna = Person(name: "Anna", relation: .friend)
    try references.save(anna)
    let payment = ScheduledPayment(
      name: "Music", kind: .subscription, amountE4: AmountE4(whole: 199), forWhom: .friends,
      forPersonId: anna.id, reimbursable: true, debtorPersonId: anna.id,
      reimbursementAmountE4: AmountE4(whole: 199), day: 25, nextDate: today)
    var rows = PlanningRows.empty
    rows.scheduled = [payment]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))

    XCTAssertTrue(
      PlanningActions(deps).markAsPaid(
        payment, due: today, amount: AmountE4(whole: 199), on: Date(), paymentMethodId: nil,
        updatePrice: false))
    let written = try transactions.entries(from: .distantPast, to: .distantFuture)
    XCTAssertEqual(written.count, 1)
    let entry = try XCTUnwrap(written.first)
    XCTAssertEqual(
      entry.transaction.externalId,
      OperationLink.scheduled(paymentId: payment.id, due: today).externalId)
    let part = try XCTUnwrap(entry.parts.first { $0.reimbursable })
    XCTAssertEqual(part.debtorPersonId, anna.id)
    XCTAssertEqual(part.reimbursementStatus, .expected, "it waits in «Owed to me»")
    XCTAssertEqual(
      try planning.scheduled().first?.nextDate, DateOnly(year: 2026, month: 10, day: 25))

    store.undo()
    XCTAssertEqual(try transactions.entries(from: .distantPast, to: .distantFuture), [])
    XCTAssertEqual(try planning.scheduled().first?.nextDate, today, "the due date is back")
  }

  func testAContributionIsAGoodExpenseInTheGoalsOwnSubcategory() throws {
    let goalsRoot = CoreKit.Category(
      kind: .expense, name: "Goals", quality: .good, systemRole: .goals)
    try references.save(goalsRoot)
    let goal = Goal(name: "Trip", targetE4: AmountE4(whole: 100_000))
    var rows = PlanningRows.empty
    rows.goals = [goal]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    show(categories: [goalsRoot], goals: [goal])

    XCTAssertTrue(
      PlanningActions(deps).move(
        goal, amount: AmountE4(whole: 5_000), on: Date(), paymentMethodId: nil, withdraw: false))
    let subcategory = try XCTUnwrap(
      try references.categories().first { $0.parentId == goalsRoot.id }, "made for the goal")
    XCTAssertEqual(subcategory.name, "Trip")
    let entry = try XCTUnwrap(
      try transactions.entries(from: .distantPast, to: .distantFuture).first)
    XCTAssertEqual(entry.transaction.kind, .expense)
    XCTAssertEqual(entry.parts.first?.categoryId, subcategory.id)
    XCTAssertEqual(entry.parts.first?.goalId, goal.id)
    XCTAssertEqual(entry.parts.first?.quality, .good)

    store.undo()
    XCTAssertEqual(try transactions.entries(from: .distantPast, to: .distantFuture), [])
    XCTAssertNil(try references.categories().first { $0.parentId == goalsRoot.id })
  }

  /// A name typed with a space at its end is saved without it: the goal's own subcategory is
  /// named after the goal, and the entry line matches names as they are written.
  func testANameIsSavedWithoutTheSpacesAroundIt() throws {
    let goalsRoot = CoreKit.Category(
      kind: .expense, name: "Goals", quality: .good, systemRole: .goals)
    try references.save(goalsRoot)
    show(categories: [goalsRoot])
    let actions = PlanningActions(deps)

    XCTAssertTrue(actions.save(Goal(name: " Trip  ", targetE4: AmountE4(whole: 100_000))))
    XCTAssertEqual(try references.goals().map(\.name), ["Trip"])
    XCTAssertEqual(
      try references.categories().first { $0.parentId == goalsRoot.id }?.name, "Trip",
      "the goal's subcategory took the spaces along")

    XCTAssertTrue(
      actions.save(
        ScheduledPayment(
          name: "Music \n", kind: .subscription, amountE4: AmountE4(whole: 199), day: 25,
          nextDate: today), previous: nil))
    XCTAssertEqual(try planning.scheduled().map(\.name), ["Music"])

    XCTAssertTrue(actions.save(ExpectedIncome(name: "  Salary", totalE4: AmountE4(whole: 1_000))))
    XCTAssertEqual(try planning.expected().map(\.name), ["Salary"])
  }

  /// A payment due today and marked paid in the morning is dated now, not at noon: noon is
  /// hours ahead of the clock, and a reconciliation opened before it leaves the payment out
  /// (`occurredAt <= now`) — it would be counted only in the next one. An overdue payment
  /// keeps its due day, one made ahead is dated now.
  func testAPaymentDueTodayIsDatedNowAndAnOverdueOneOnItsDay() {
    let calendar = CalendarContext.utc
    let morning = calendar.startOfDay(today).addingTimeInterval(9 * 3600)
    func paidAt(_ due: DateOnly) -> Date {
      PlanningActions.paidAt(due: due, today: today, calendar: calendar, now: morning)
    }
    XCTAssertEqual(paidAt(today), morning, "dated at noon, three hours ahead of the clock")
    let overdue = today.adding(days: -3)
    XCTAssertEqual(paidAt(overdue), calendar.startOfDay(overdue).addingTimeInterval(12 * 3600))
    XCTAssertEqual(paidAt(today.adding(days: 5)), morning)
  }

  /// «Завести» from a subscription candidate opens a new payment, not an edit: the candidate
  /// is not in the database, so the form says «Новый платёж», and a price typed over the
  /// typical amount is the payment's price, not a change of it with a row of history.
  func testAPaymentFromACandidateIsANewOne() throws {
    let music = CoreKit.Category(kind: .expense, name: "Music")
    try references.save(music)
    let candidate = SubscriptionCandidate(
      key: "music", placeId: nil, categoryId: music.id, currency: .rub,
      typicalAmount: AmountE4(whole: 199), freq: .monthly, occurrences: 3, lastDay: today)
    let sheet = PlanningSheet.subscription(from: candidate, name: "Music")

    XCTAssertNil(sheet.editedPayment, "the form edits a payment the database does not have")
    var typed = try XCTUnwrap(sheet.startingPayment)
    XCTAssertEqual(typed.name, "Music")
    XCTAssertEqual(typed.kind, .subscription)
    XCTAssertEqual(typed.amountE4, AmountE4(whole: 199))
    XCTAssertEqual(typed.categoryId, music.id)
    XCTAssertEqual(typed.freq, .monthly)

    typed.amountE4 = AmountE4(whole: 249)
    XCTAssertTrue(PlanningActions(deps).save(typed, previous: sheet.editedPayment))
    let book = try planning.book()
    XCTAssertEqual(book.scheduled.map(\.amountE4), [AmountE4(whole: 249)])
    XCTAssertEqual(book.prices, [], "a new payment came with a history of its price")
  }

  /// «Отменить подписку» opens the page the owner typed, even without «https://»: «netflix.com»
  /// is how an address is usually written, and a URL without a scheme opens nothing. Only a
  /// web page or a letter is opened — never a file or another app from an imported book.
  func testTheCancelLinkOpensAnAddressTypedWithoutItsScheme() {
    func link(_ text: String?) -> String? {
      var payment = ScheduledPayment(name: "Music", kind: .subscription, amountE4: .zero)
      payment.cancelURL = text
      return payment.cancelLink?.absoluteString
    }
    XCTAssertEqual(link("netflix.com"), "https://netflix.com", "an address without a scheme")
    XCTAssertEqual(link(" netflix.com/account "), "https://netflix.com/account")
    XCTAssertEqual(link("https://example.com/cancel"), "https://example.com/cancel")
    XCTAssertEqual(link("HTTP://example.com"), "HTTP://example.com")
    XCTAssertEqual(link("mailto:help@example.com"), "mailto:help@example.com")
    XCTAssertNil(link(nil))
    XCTAssertNil(link("   "))
    XCTAssertNil(link("file:///Users/owner/secret"), "a file is not a page to cancel at")
    XCTAssertNil(link("itogo-other://open"))
  }

  func testALimitOnASystemCategoryIsRefused() throws {
    let unknown = CoreKit.Category(kind: .expense, name: "Unknown", systemRole: .unknown)
    show(categories: [unknown])
    let budget = Budget(scope: .category, categoryId: unknown.id, amountE4: AmountE4(whole: 1_000))
    XCTAssertEqual(PlanningActions(deps).issue(of: budget), .systemCategory)
    XCTAssertFalse(PlanningActions(deps).save(budget))
    XCTAssertEqual(try planning.budgets(), [])
  }

  /// An edit of a limit's amount, or rollover switched on, starts the carry again in the month
  /// of the edit: the months before were lived under the old amount, which the book does not
  /// keep. A save that changes nothing keeps the start.
  func testEditingALimitStartsItsRolloverAgainInTheMonthOfTheEdit() throws {
    let food = CoreKit.Category(kind: .expense, name: "Food")
    try references.save(food)
    let june = MonthKey(year: 2026, month: 6)
    let thisMonth = deps.environment.today.monthKey
    let limit = Budget(
      scope: .category, categoryId: food.id, amountE4: AmountE4(whole: 5_000), rollover: true,
      startMonth: june)
    let off = Budget(
      scope: .forWhom, forWhom: .friends, amountE4: AmountE4(whole: 3_000), startMonth: june)
    var rows = PlanningRows.empty
    rows.budgets = [limit, off]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    show(categories: [food], budgets: [limit, off])
    func stored(_ id: UUID) throws -> Budget? { try planning.budgets().first { $0.id == id } }

    XCTAssertTrue(PlanningActions(deps).save(limit))
    XCTAssertEqual(try stored(limit.id)?.startMonth, june, "nothing changed")

    var raised = limit
    raised.amountE4 = AmountE4(whole: 20_000)
    XCTAssertTrue(PlanningActions(deps).save(raised))
    XCTAssertEqual(try stored(limit.id)?.startMonth, thisMonth, "a new amount starts again")

    var turnedOn = off
    turnedOn.rollover = true
    XCTAssertTrue(PlanningActions(deps).save(turnedOn))
    XCTAssertEqual(try stored(off.id)?.startMonth, thisMonth, "nothing was carried before")
  }

  /// × keeps every reminder put off before it (review of the app, 19.09) and forgets only
  /// what reminds of nothing any more (ReminderRules.dismissed).
  func testPuttingOffASecondReminderKeepsTheFirstOff() {
    let first = ReminderRules.dismissed(adding: "pay:a:2026-09-17", to: [], active: nil)
    let second = ReminderRules.dismissed(adding: "pay:b:2026-09-22", to: first, active: nil)
    XCTAssertEqual(second, ["pay:a:2026-09-17", "pay:b:2026-09-22"])
    let pruned = ReminderRules.dismissed(
      adding: "reconcile:none", to: ["pay:c:2026-07-01", "pay:a:2026-09-17"],
      active: ["pay:a:2026-09-17", "reconcile:none"])
    XCTAssertEqual(pruned, ["pay:a:2026-09-17", "reconcile:none"])
  }

  /// A «Mark as paid» deleted in Transactions gives its due date back, and paying the date
  /// anew is one more step of ⌘Z above the deletion. So the deletion is never taken back while
  /// the new payment stands: ⌘Z takes the new payment first, then brings the old one back
  /// with its key — the date is paid once, never by two charges (the storage's fallback for a
  /// date paid twice, `restore`'s «OR IGNORE», is not reached from the app).
  func testADeletedPaymentComesBackOnlyAfterTheDatePaidAnewWasTakenBack() throws {
    let payment = ScheduledPayment(
      name: "Internet", amountE4: AmountE4(whole: 900), day: 19, nextDate: today)
    var rows = PlanningRows.empty
    rows.scheduled = [payment]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    let actions = PlanningActions(deps)
    let key = OperationLink.scheduled(paymentId: payment.id, due: today).externalId
    func pay() -> Bool {
      guard let current = try? planning.scheduled().first else { return false }
      return actions.markAsPaid(
        current, due: today, amount: AmountE4(whole: 900), on: Date(), paymentMethodId: nil,
        updatePrice: false)
    }
    func charges() throws -> [TransactionEntry] {
      try transactions.entries(from: .distantPast, to: .distantFuture)
    }

    XCTAssertTrue(pay())
    let first = try XCTUnwrap(try charges().first)
    XCTAssertTrue(store.delete(ids: [first.id]))
    XCTAssertEqual(try planning.scheduled().first?.nextDate, today, "the date is owed again")
    XCTAssertTrue(pay())
    let again = try XCTUnwrap(try charges().first)
    XCTAssertNotEqual(again.id, first.id)

    store.undo()
    XCTAssertEqual(try charges(), [], "the payment made anew goes first")
    store.undo()
    XCTAssertEqual(try charges().map(\.id), [first.id], "then the deleted one comes back")
    XCTAssertEqual(try charges().first?.transaction.externalId, key, "as the date's payment")
    XCTAssertEqual(
      try planning.scheduled().first?.nextDate, DateOnly(year: 2026, month: 10, day: 19))
  }

  /// Paying once with another card does not move the payment to that card for good.
  func testMarkAsPaidWithAnotherCardLeavesThePaymentsCardAlone() throws {
    let card = PaymentMethod(name: "Card 1234", kind: .card)
    let other = PaymentMethod(name: "Card 5678", kind: .card)
    try references.save(card)
    try references.save(other)
    let payment = ScheduledPayment(
      name: "Internet", amountE4: AmountE4(whole: 900), paymentMethodId: card.id, day: 17,
      nextDate: today)
    var rows = PlanningRows.empty
    rows.scheduled = [payment]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    XCTAssertTrue(
      PlanningActions(deps).markAsPaid(
        payment, due: today, amount: AmountE4(whole: 900), on: Date(), paymentMethodId: other.id,
        updatePrice: false))
    XCTAssertEqual(
      try transactions.entries(from: .distantPast, to: .distantFuture).first?.transaction
        .paymentMethodId, other.id)
    XCTAssertEqual(try planning.scheduled().first?.paymentMethodId, card.id)
  }

  /// The first edit of a subscription's price keeps the past at the old price (review of the
  /// app, 19.09): the payment's own amount was the price of every date before, and the edit
  /// replaces it.
  func testEditingASubscriptionsPriceKeepsTheOverdueDueAtTheOldPrice() throws {
    let day = AppEnvironment().today
    let overdue = day.adding(days: -28)
    let payment = ScheduledPayment(
      name: "Cloud", kind: .subscription, amountE4: AmountE4(whole: 249), day: overdue.day,
      nextDate: overdue)
    var rows = PlanningRows.empty
    rows.scheduled = [payment]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))

    var edited = payment
    edited.amountE4 = AmountE4(whole: 299)
    XCTAssertTrue(PlanningActions(deps).save(edited, previous: payment))

    let book = try planning.book()
    let saved = try XCTUnwrap(book.scheduled.first)
    XCTAssertEqual(
      SubscriptionMath.price(of: saved, on: overdue, prices: book.prices), AmountE4(whole: 249),
      "the overdue due was priced before the change")
    XCTAssertEqual(
      SubscriptionMath.price(of: saved, on: day, prices: book.prices), AmountE4(whole: 299))
  }

  /// A payment in a currency the cache has no rate for is not refused in silence (review of
  /// the app, 19.09): the form learns why, and a rate typed by hand pays it.
  func testMarkAsPaidWithoutARateSaysWhyAndTakesOneByHand() throws {
    let payment = ScheduledPayment(
      name: "Hosting", kind: .subscription, amountE4: AmountE4(whole: 10), currency: .usd,
      day: 17, nextDate: today)
    var rows = PlanningRows.empty
    rows.scheduled = [payment]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    let actions = PlanningActions(deps)

    XCTAssertFalse(
      actions.markAsPaid(
        payment, due: today, amount: AmountE4(whole: 10), on: Date(), paymentMethodId: nil,
        updatePrice: false))
    XCTAssertEqual(actions.failureKey(currency: .usd, on: Date()), "form.rateMissing")
    XCTAssertEqual(actions.failureKey(currency: .rub, on: Date()), "form.notSaved")
    // Each place gets the advice it can act on: the debt sheet has no rate field.
    XCTAssertEqual(
      actions.failureKey(currency: .usd, on: Date(), at: .debt), "form.rateMissing.debt")

    XCTAssertTrue(
      actions.markAsPaid(
        payment, due: today, amount: AmountE4(whole: 10), on: Date(), paymentMethodId: nil,
        updatePrice: false, rate: 90))
    let entry = try XCTUnwrap(
      try transactions.entries(from: .distantPast, to: .distantFuture).first)
    XCTAssertEqual(entry.transaction.rateSource, .manual)
    XCTAssertEqual(entry.transaction.amountRubE4, AmountE4(whole: 900))
  }

  /// The reconciliation shows the day of the rate it counts a currency at («в
  /// рублях по курсу ЦБ на сегодня»; review of the app, 19.09): on a Saturday that is Friday's.
  func testTheContextKeepsTheDayOfEachRate() {
    let debt = Debt(direction: .iOwe, type: .personal, name: "Loan", currency: .usd)
    let friday = DateOnly(year: 2026, month: 9, day: 18)
    let context = SnapshotContext(
      dataset: Dataset(debts: [debt]),
      rates: RateTable(rates: [Rate(date: friday, currency: .usd, rubPerUnit: 90)]),
      today: today)
    XCTAssertEqual(context.rubPerUnit[.usd], 90)
    XCTAssertEqual(context.rateDays[.usd], friday)
  }

  /// A weekly income shows the week that has come, not the last week of the month (third
  /// review, 19.09): on the 19th, with the 18th paid, the row says 10 000 of 10 000.
  func testAWeeklyIncomeShowsTheWeekThatHasCome() {
    func week(_ day: Int, received: Int64) -> ExpectedOccurrence {
      ExpectedOccurrence(
        due: DateOnly(year: 2026, month: 9, day: day), total: AmountE4(whole: 10_000),
        received: AmountE4(whole: received), remaining: AmountE4(whole: 10_000 - received),
        remainingRub: nil, partsReceived: received > 0 ? 1 : 0, transactionIds: [])
    }
    let weeks = [
      week(4, received: 10_000), week(11, received: 10_000), week(18, received: 10_000),
      week(25, received: 0),
    ]
    XCTAssertEqual(
      ExpectedIncomeBlock.shownOccurrence(weeks, today: today)?.due,
      DateOnly(year: 2026, month: 9, day: 18))
    // Before the first due of the month, the first one.
    XCTAssertEqual(
      ExpectedIncomeBlock.shownOccurrence(weeks, today: DateOnly(year: 2026, month: 9, day: 2))?
        .due, DateOnly(year: 2026, month: 9, day: 4))
  }

  /// The settings tab writes only the key it changed (review of the app, 19.09): a stale copy
  /// of the reserve switch, turned on the Planning screen since, is not written back.
  /// A recurring income opened with no due date shows today in its date field and is saved
  /// with today: the day of its schedule is today's day, not left empty beside it.
  func testARecurringIncomeWithoutADueDateIsSavedOnTheDayOfToday() {
    let today = DateOnly(year: 2026, month: 9, day: 24)
    var income = ExpectedIncome(name: "Зарплата", totalE4: AmountE4(whole: 100_000))
    income.kind = .recurring
    income.freq = .monthly

    let saved = income.readyToSave(today: today)
    XCTAssertEqual(saved.dueDate, today)
    XCTAssertEqual(saved.day, 24, "the day of the schedule was derived before the due date")

    income.freq = .weekly
    XCTAssertEqual(income.readyToSave(today: today).day, today.weekday)
  }

  /// A one-off income keeps neither a frequency nor a day.
  func testAOneOffIncomeKeepsNoSchedule() {
    var income = ExpectedIncome(name: "Премия", totalE4: AmountE4(whole: 50_000))
    income.kind = .oneOff
    income.freq = .monthly
    income.day = 5
    let saved = income.readyToSave(today: DateOnly(year: 2026, month: 9, day: 24))
    XCTAssertNil(saved.freq)
    XCTAssertNil(saved.day)
  }

  func testChangingOneSettingWritesOnlyItsKey() {
    var stale = PlanningSettings()
    stale.reserveGoalPlan = true
    var changed = stale
    changed.reconcileEveryDays = 21
    XCTAssertEqual(
      PlanningSettingsView.changedKeys(before: stale.storedValues, after: changed.storedValues),
      [PlanningSettings.reconcileEveryDaysKey])
  }

  /// A step whose undo the database refuses — an operation was filed since under the category
  /// the step created, and the schema keeps a category that parts point at — stays on the
  /// stack, goes to the journal and is said on screen. The next ⌘Z tries it again instead of
  /// quietly undoing the save before it.
  func testARefusedUndoKeepsItsStepAndSaysSo() async throws {
    let logs = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-undo-\(UUID().uuidString)", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer {
      Task { Logbook.shared.close() }
      try? FileManager.default.removeItem(at: logs)
    }

    var earlier = TransactionDraft(amount: AmountE4(whole: 100), note: "earlier")
    earlier.normalizeSinglePart()
    let saved = try earlier.materialize()
    XCTAssertTrue(store.save(saved))
    let trip = CoreKit.Category(kind: .expense, name: "Trip", quality: .good)
    var rows = PlanningRows.empty
    rows.categories = [trip]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    // Filed under the new category by a write that left no step of its own.
    var ticket = TransactionDraft(amount: AmountE4(whole: 50), note: "ticket")
    ticket.parts = [PartDraft(categoryId: trip.id, amount: AmountE4(whole: 50))]
    try transactions.save(try ticket.materialize())

    store.undo()
    XCTAssertTrue(store.canUndo, "the refused step is still there")
    XCTAssertTrue(try references.categories(includeArchived: true).contains { $0.id == trip.id })
    let failure = try XCTUnwrap(store.failure, "the screen is told")
    XCTAssertEqual(failure, StoreFailure(action: .undo, cause: .tiedToOtherRows))
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for text in [
        StoreFailureText.title(failure, language: language),
        StoreFailureText.message(failure, language: language),
      ] {
        XCTAssertFalse(text.hasPrefix("store.failure"), "\(text) in \(choice.rawValue)")
      }
    }
    store.forgetFailure()

    store.undo()
    XCTAssertNotNil(
      try transactions.entry(id: saved.id), "the second ⌘Z tried the same step, not the save")
    XCTAssertTrue(store.canUndo)
    XCTAssertNotNil(store.failure)

    var lines: [String] = []
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      lines = Logbook.shared.lines().filter { $0.contains("store.writeFailed") }
      if lines.count >= 2 { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertEqual(lines.count, 2, "every refused undo is in the journal")
    XCTAssertTrue(lines.allSatisfy { $0.contains("action=undo") }, lines.joined(separator: "\n"))
  }
}
