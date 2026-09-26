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

  // MARK: - A payment paid by an ordinary operation

  /// The rent of 15 September, typed as an ordinary expense on the 14th, and the payment of
  /// the rent — as the pipeline would show them.
  private func rentPaidByHand() throws -> (
    payment: ScheduledPayment, operation: TransactionEntry, snapshot: DataSnapshot
  ) {
    let main = PaymentMethod(name: "Main", currency: .rub, isDefault: true)
    try references.save(main)
    let rent = CoreKit.Category(kind: .expense, name: "Rent", quality: .neutral)
    try references.save(rent)
    let payment = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 30_000), categoryId: rent.id,
      paymentMethodId: main.id, day: 15, nextDate: DateOnly(year: 2026, month: 9, day: 15))
    var rows = PlanningRows.empty
    rows.scheduled = [payment]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 14))
        .addingTimeInterval(10 * 3600),
      amount: AmountE4(whole: 30_000), note: "rent", paymentMethodId: main.id)
    draft.parts = [PartDraft(categoryId: rent.id, amount: AmountE4(whole: 30_000))]
    let operation = try draft.materialize()
    try transactions.save(operation)
    let snapshot = try showStored()
    return (payment, operation, snapshot)
  }

  /// What the database holds now, shown as the pipeline would show it.
  @discardableResult
  private func showStored(version: Int = 1) throws -> DataSnapshot {
    let snapshot = DataSnapshot.build(
      dataset: Dataset(
        entries: try transactions.entries(from: .distantPast, to: .distantFuture),
        categories: try references.categories(),
        paymentMethods: try references.paymentMethods(), planning: try planning.book()),
      calendar: .utc, today: today, context: SnapshotContext(), version: DataVersion(load: version))
    compute.applyLight(snapshot)
    return snapshot
  }

  /// «оплачено операцией»: the rent typed by hand pays the due of the 15th. «Привязать» keys
  /// it to that due for good and moves the payment to October — one step of ⌘Z, which puts
  /// both back.
  func testLinkingAMatchedOperationKeysItAndMovesThePaymentOnInOneUndo() throws {
    let (payment, operation, snapshot) = try rentPaidByHand()
    let status = try XCTUnwrap(snapshot.planning.scheduled.first)
    XCTAssertEqual(status.matchedDues, [DateOnly(year: 2026, month: 9, day: 15): operation.id])

    XCTAssertTrue(
      PlanningActions(deps).bind(
        operation.id, to: payment, due: DateOnly(year: 2026, month: 9, day: 15)))
    XCTAssertEqual(
      try transactions.entry(id: operation.id)?.transaction.externalId,
      OperationLink.scheduled(paymentId: payment.id, due: DateOnly(year: 2026, month: 9, day: 15))
        .externalId)
    XCTAssertEqual(
      try planning.scheduled().first?.nextDate, DateOnly(year: 2026, month: 10, day: 15))

    store.undo()
    XCTAssertNil(try transactions.entry(id: operation.id)?.transaction.externalId)
    XCTAssertEqual(
      try planning.scheduled().first?.nextDate, DateOnly(year: 2026, month: 9, day: 15))
  }

  /// «Это другое»: the operation is not the rent; the due waits for its payment again. One
  /// step of ⌘Z brings the match back.
  func testSomethingElseStopsTheMatchAndOneUndoBringsItBack() throws {
    let (payment, operation, _) = try rentPaidByHand()
    let due = DateOnly(year: 2026, month: 9, day: 15)
    XCTAssertTrue(PlanningActions(deps).reject(operation.id, for: payment, due: due))

    let key = ScheduledMatching.rejectionKey(operation: operation.id, payment: payment.id, due: due)
    XCTAssertEqual(try planning.book().settings.scheduledMatchRejections, [key])
    let shown = try showStored(version: 2)
    XCTAssertEqual(shown.planning.scheduled.first?.matchedDues, [:])
    XCTAssertEqual(shown.planning.scheduled.first?.nextUnpaid, due, "the due waits again")

    store.undo()
    XCTAssertEqual(try planning.book().settings.scheduledMatchRejections, [])
  }

  /// The row shows, pays and skips the first due nothing paid: the one the operation paid is
  /// behind it.
  func testTheRowPaysTheFirstUnpaidDue() throws {
    let (_, _, snapshot) = try rentPaidByHand()
    let status = try XCTUnwrap(snapshot.planning.scheduled.first)
    XCTAssertEqual(status.nextDue, DateOnly(year: 2026, month: 9, day: 15))
    XCTAssertEqual(status.nextUnpaid, DateOnly(year: 2026, month: 10, day: 15))
    XCTAssertEqual(ScheduledRow.paying(status).nextDue, DateOnly(year: 2026, month: 10, day: 15))
    // A reminder of the due the operation paid pays nothing; the next one does.
    let matches = snapshot.planning.matches
    XCTAssertTrue(ScheduledRow.canPay(status, matches: matches))
    XCTAssertFalse(
      RemindersSheet.waits(status, for: DateOnly(year: 2026, month: 9, day: 15), matches: matches))
    XCTAssertTrue(
      RemindersSheet.waits(
        status, for: DateOnly(year: 2026, month: 10, day: 15), matches: matches))
  }

  /// A one-off repair an ordinary expense paid already: nothing is left to pay, so neither the
  /// row nor the reminder offers «Провести» or «Пропустить» — pressed, «Провести» would write
  /// the repair a second time. «Привязать» under the row closes it.
  func testAPaymentWhoseEveryDueIsPaidCannotBePaidAgain() throws {
    let main = PaymentMethod(name: "Main", currency: .rub, isDefault: true)
    try references.save(main)
    let repair = CoreKit.Category(kind: .expense, name: "Repair", quality: .neutral)
    try references.save(repair)
    let due = DateOnly(year: 2026, month: 9, day: 20)
    let payment = ScheduledPayment(
      name: "Repair", amountE4: AmountE4(whole: 50_000), categoryId: repair.id,
      paymentMethodId: main.id, day: 20, nextDate: due, endDate: due)
    var rows = PlanningRows.empty
    rows.scheduled = [payment]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18))
        .addingTimeInterval(10 * 3600),
      amount: AmountE4(whole: 50_000), note: "repair", paymentMethodId: main.id)
    draft.parts = [PartDraft(categoryId: repair.id, amount: AmountE4(whole: 50_000))]
    let operation = try draft.materialize()
    try transactions.save(operation)

    let snapshot = try showStored()
    let status = try XCTUnwrap(snapshot.planning.scheduled.first)
    XCTAssertEqual(status.matchedDues, [due: operation.id])
    XCTAssertEqual(status.nextUnpaid, due, "the row shows the last due, paid")
    XCTAssertFalse(ScheduledRow.canPay(status, matches: snapshot.planning.matches))
    XCTAssertFalse(RemindersSheet.waits(status, for: due, matches: snapshot.planning.matches))
  }

  /// «Провести» on the October rent while September's was paid by the rent typed by hand: the
  /// payment moves past both, and that operation is keyed to September's due date in the same
  /// write — unkeyed, it would drop out of September's funding once `next_date` is past it.
  /// One ⌘Z takes all of it back; «Пропустить» keys it the same way.
  func testPayingALaterDueKeysTheOperationThatPaidTheEarlierOne() throws {
    let (payment, operation, _) = try rentPaidByHand()
    let september = DateOnly(year: 2026, month: 9, day: 15)
    let october = DateOnly(year: 2026, month: 10, day: 15)
    let key = OperationLink.scheduled(paymentId: payment.id, due: september).externalId

    XCTAssertTrue(
      PlanningActions(deps).markAsPaid(
        payment, due: october, amount: AmountE4(whole: 30_000),
        on: CalendarContext.utc.startOfDay(today).addingTimeInterval(12 * 3600),
        paymentMethodId: payment.paymentMethodId, updatePrice: false))
    XCTAssertEqual(try transactions.entry(id: operation.id)?.transaction.externalId, key)
    XCTAssertEqual(
      try planning.scheduled().first?.nextDate, DateOnly(year: 2026, month: 11, day: 15))
    let shown = try showStored(version: 2)
    XCTAssertEqual(
      shown.planning.funding.map(\.paid), [AmountE4(whole: 30_000)],
      "September's rent dropped out of September's funding")

    store.undo()
    XCTAssertNil(try transactions.entry(id: operation.id)?.transaction.externalId)
    XCTAssertEqual(try planning.scheduled().first?.nextDate, september)
    XCTAssertEqual(
      try transactions.entries(from: .distantPast, to: .distantFuture).map(\.id),
      [operation.id], "one ⌘Z left the October payment")

    try showStored(version: 3)
    XCTAssertTrue(PlanningActions(deps).skip(payment, due: october))
    XCTAssertEqual(try transactions.entry(id: operation.id)?.transaction.externalId, key)
    store.undo()
    XCTAssertNil(try transactions.entry(id: operation.id)?.transaction.externalId)
  }

  /// The forecast step leaves the rent typed by hand out of the daily average: the plan
  /// counts it already, and in both it would be forecast twice.
  func testTheForecastLeavesAMatchedOperationOutOfTheAverage() throws {
    let (_, operation, snapshot) = try rentPaidByHand()
    XCTAssertEqual(snapshot.planning.matches.operationIds, [operation.id])
    let matched = ComputeSources.forecast(of: snapshot, today: today)
    let twice = MonthForecast.remainder(ledger: snapshot.ledger, today: today)
    let without = MonthForecast.remainder(
      ledger: Ledger(
        dataset: snapshot.dataset.removing([operation.id]), calendar: .utc),
      today: today)
    XCTAssertEqual(matched, without)
    XCTAssertNotEqual(matched, twice)
  }
}

/// Events and their budgets set right in Planning, against a database: each save is one step
/// of ⌘Z, and a name in the archive comes back rather than a second event beside it.
@MainActor
final class EventBudgetFlowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!

  override func setUp() async throws {
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
  }

  private var actions: PlanningActions {
    PlanningActions(AppDependencies(environment: environment, store: store, compute: compute))
  }

  private func events() throws -> [Event] {
    try XCTUnwrap(environment.references).events(includeArchived: true)
  }

  func testAnEventAndItsBudgetAreOneStepOfUndoEach() throws {
    let day = DateOnly(year: 2026, month: 12, day: 31)
    let party = Event(
      name: "  New Year ", startDate: day, endDate: day, budgetE4: AmountE4(whole: 20_000))
    XCTAssertTrue(actions.save(party))
    XCTAssertEqual(try events().map(\.name), ["New Year"])
    XCTAssertEqual(try events().first?.budgetE4, AmountE4(whole: 20_000))

    var edited = try XCTUnwrap(try events().first)
    edited.budgetE4 = AmountE4(whole: 25_000)
    XCTAssertTrue(actions.save(edited))
    XCTAssertEqual(try events().first?.budgetE4, AmountE4(whole: 25_000))

    store.undo()
    XCTAssertEqual(try events().first?.budgetE4, AmountE4(whole: 20_000), "one ⌘Z, one edit")
    store.undo()
    XCTAssertEqual(try events(), [], "one ⌘Z took the new event back")
  }

  func testANameInTheArchiveComesBackAndATwinIsRefused() throws {
    let day = DateOnly(year: 2026, month: 10, day: 3)
    let trip = Event(name: "Trip", startDate: day, endDate: day.adding(days: 3), archived: true)
    try XCTUnwrap(environment.references).save(trip)

    let again = Event(
      name: "trip", startDate: day.adding(days: 1), endDate: day.adding(days: 5),
      budgetE4: AmountE4(whole: 50_000))
    XCTAssertTrue(actions.save(again))
    let stored = try events()
    XCTAssertEqual(stored.count, 1, "a second event beside the archived one")
    XCTAssertEqual(stored.first?.id, trip.id)
    XCTAssertEqual(stored.first?.archived, false)
    XCTAssertEqual(stored.first?.budgetE4, AmountE4(whole: 50_000))

    let twin = Event(name: "TRIP", startDate: day.adding(days: 2), endDate: day.adding(days: 2))
    XCTAssertEqual(PlanningActions.issue(of: twin, among: stored), .sameNameAndDays)
    XCTAssertFalse(actions.save(twin))
    XCTAssertEqual(
      PlanningActions.issue(of: Event(name: "", startDate: day, endDate: day), among: []),
      .emptyName)
    let nextYear = Event(
      name: "Trip", startDate: day.adding(days: 365), endDate: day.adding(days: 366))
    XCTAssertNil(PlanningActions.issue(of: nextYear, among: stored))
  }

  /// An event with a budget five months ahead is past the 120 days of «upcoming», but the
  /// free sum keeps its budget back until a day up to a year away: the block lists it, to see
  /// and to change.
  func testAnEventWithABudgetFarAheadIsInTheBlock() {
    let today = DateOnly(year: 2026, month: 9, day: 26)
    let holiday = Event(
      name: "Holiday", startDate: today.adding(days: 156), endDate: today.adding(days: 169),
      budgetE4: AmountE4(whole: 200_000))
    let party = Event(
      name: "Party", startDate: today.adding(days: 10), endDate: today.adding(days: 10))
    let far = Event(
      name: "Far", startDate: today.adding(days: 200), endDate: today.adding(days: 200))
    let snapshot = DataSnapshot.build(
      dataset: Dataset(events: [holiday, party, far]), calendar: .utc, today: today,
      context: SnapshotContext(), version: DataVersion(load: 1))
    let shown = EventsBlock.shown(
      snapshot.planning.events, budgeted: snapshot.planning.budgetedEvents)
    XCTAssertEqual(
      shown.map(\.event.name), ["Party", "Holiday"],
      "the budget kept back is not in the block, or an event without one came in")
  }

  func testTheWordsOfTheEventFormAreTranslated() {
    let keys = [
      "events.add", "events.edit", "events.form.new", "events.form.edit", "events.form.budget",
      "events.form.budgetHint", "events.issue.emptyName", "events.issue.sameNameAndDays",
      "free.noReconciliation", "free.grey", "free.perDay", "free.stillExpected",
      "free.excludedTitle", "planning.free.goalSavings", "planning.free.events",
      "scheduled.paidByOperation", "scheduled.bind", "scheduled.notThis", "funding.withoutRate",
    ]
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for key in keys {
        XCTAssertNotEqual(environment.language(key, table: "Planning"), key, "\(choice) \(key)")
      }
    }
    environment.language.choice = .russian
  }
}

/// The free-sum block: what it shows of the free sum, and the day it counts to.
@MainActor
final class FreeMoneyBlockTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 19)

  /// A free sum as the pipeline gives it, for a book with `accounts`.
  private func freeMoney(accounts: [PaymentMethod] = []) -> FreeMoney {
    DataSnapshot.build(
      dataset: Dataset(paymentMethods: accounts), calendar: .utc, today: today,
      context: SnapshotContext(), version: DataVersion(load: 1)
    ).planning.freeMoney
  }

  /// A free sum counted from 100,000 on the accounts.
  private func ready() -> FreeMoney {
    var free = freeMoney()
    free.state = .ready
    free.main = AmountE4(whole: 100_000)
    free.grey = AmountE4(whole: 90_000)
    return free
  }

  /// D is the end of the month unless another day is picked, and stays within today and a
  /// year ahead.
  func testTheDayIsTheEndOfTheMonthAndStaysWithinAYear() {
    XCTAssertEqual(
      FreeMoneyBlock.day(today: today, picked: nil), DateOnly(year: 2026, month: 9, day: 30))
    XCTAssertEqual(
      FreeMoneyBlock.day(today: today, picked: DateOnly(year: 2027, month: 3, day: 31)),
      DateOnly(year: 2027, month: 3, day: 31))
    XCTAssertEqual(
      FreeMoneyBlock.day(today: today, picked: DateOnly(year: 2028, month: 1, day: 1)),
      DateOnly(year: 2027, month: 9, day: 19))
    XCTAssertEqual(
      FreeMoneyBlock.day(today: today, picked: DateOnly(year: 2026, month: 9, day: 1)), today)
  }

  /// With no count there is no money to start from: the block shows only «Мало данных» and
  /// the way to the first count — no main figure, no grey line, no guide per day.
  func testWithoutACountTheBlockAsksForTheFirstOne() {
    let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
    let free = freeMoney(accounts: [card])
    XCTAssertEqual(free.state, .noReconciliation)
    XCTAssertEqual(FreeMoneyBlock.parts(of: free), [.firstCount])

    let parts = FreeMoneyBlock.parts(of: ready()).map(\.name)
    XCTAssertEqual(parts.first, "main")
    XCTAssertTrue(parts.contains("grey"))
    XCTAssertTrue(parts.contains("perDay"))
    XCTAssertFalse(parts.contains("firstCount"))
  }

  /// «из них отложено на цели» explains the main figure only while the grey line takes the
  /// goals' money away, and only when there is some.
  func testTheGoalsMoneyInsideIsShownOnlyWhileTheGreyLineTakesItAway() {
    var free = ready()
    free.plan.subtractsGoalSavings = true
    free.plan.goalSavings = AmountE4(whole: 10_000)
    XCTAssertTrue(
      FreeMoneyBlock.parts(of: free).contains(.goalSavingsInside(AmountE4(whole: 10_000))))
    free.plan.subtractsGoalSavings = false
    XCTAssertFalse(FreeMoneyBlock.parts(of: free).map(\.name).contains("goalSavingsInside"))
    free.plan.subtractsGoalSavings = true
    free.plan.goalSavings = .zero
    XCTAssertFalse(FreeMoneyBlock.parts(of: free).map(\.name).contains("goalSavingsInside"))
  }

  /// The groups left out of the summary are shown apart, with their own totals, whether or
  /// not the summary was counted.
  func testTheGroupsLeftOutOfTheSummaryAreShownApart() {
    let business = FreeMoney.ExcludedGroup(
      group: AccountGroup(name: "Business", inSummary: false), totalRub: AmountE4(whole: 5_000))
    var free = ready()
    free.excluded = [business]
    XCTAssertEqual(FreeMoneyBlock.parts(of: free).last, .excluded([business]))
    free.state = .noReconciliation
    XCTAssertEqual(FreeMoneyBlock.parts(of: free), [.firstCount, .excluded([business])])
  }
}
