import AppCore
import AppDatabase
import Foundation

/// The actions of the Planning section, the reconciliation and the reminders. Each one asks
/// the rules of the core what to write, turns the drafts into operations with the rate of
/// their day, and hands everything to the store as one `PlanningChange`: one write, one step
/// of ⌘Z. Nothing here counts money by itself.
@MainActor
struct PlanningActions {
  let environment: AppEnvironment
  let store: TransactionsStore
  let snapshot: DataSnapshot?

  init(_ deps: AppDependencies) {
    environment = deps.environment
    store = deps.store
    snapshot = deps.compute.snapshot
  }

  var tree: CategoryTree? { snapshot?.ledger.tree }
  private var rubPerUnit: [CurrencyCode: Decimal] { snapshot?.context.rubPerUnit ?? [:] }

  /// A draft of the core made into an operation: the rate of its day from the cache (the
  /// pipeline refines a provisional one later), the rubles of every part, and the link to
  /// what made it.
  func operation(_ draft: TransactionDraft, link: OperationLink?) throws -> TransactionEntry {
    var draft = draft
    environment.applyRate(to: &draft)
    let convert = environment.rublesConverter(for: draft)
    var entry = try draft.materialize(rublesConverter: convert)
    entry.transaction.externalId = link?.externalId
    return entry
  }

  /// One write of planning, and the names the entry line learns from it. Debts go through
  /// here too (`DebtActions`).
  @discardableResult
  func apply(_ change: PlanningChange) -> Bool {
    guard store.apply(change) else { return false }
    // New goals, debts and categories are names the entry line should know at once.
    if !change.upsert.goals.isEmpty || !change.upsert.debts.isEmpty
      || !change.upsert.categories.isEmpty
    {
      environment.refreshVocabulary()
    }
    return true
  }

  /// A name as the forms save it: a space typed at either end is not part of it — the entry
  /// line matches names as written, and a goal's subcategory is named after the goal.
  static func trimmed(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// My own ratings by description (rule 2 of the qualities), read fresh.
  private func qualityHistory() -> ManualQualityHistory {
    ManualQualityHistory(entries: (try? environment.transactions?.entriesRatedByHand()) ?? [])
  }

  // MARK: Scheduled payments

  /// Where a failed action is told about: each place gets the advice it can act on.
  enum FailurePlace: String {
    /// The «Провести» form, which has a field for a rate by hand.
    case form
    /// A row of the reminders sheet, which pays without a form.
    case reminder
    /// The sheet of a debt payment, which has no rate field.
    case debt
  }

  /// Why an action that writes an operation in `currency` on `day` did not: no rate to count
  /// it in rubles, or anything else. A key of the Planning table.
  func failureKey(currency: CurrencyCode, on day: Date, at place: FailurePlace = .form) -> String {
    guard !environment.knowsRate(currency, on: day) else { return "form.notSaved" }
    return place == .form ? "form.rateMissing" : "form.rateMissing.\(place.rawValue)"
  }

  /// «Mark as paid» without a form: on the payment's account (the main one when it has none
  /// or it is archived), with «Списано со счёта» prefilled when that account does not hold the
  /// payment's currency — the form's `markAsPaid(…account:charged:…)` with nothing typed.
  /// `rate` is one typed by hand, for a currency the cache has no rate for.
  @discardableResult
  func markAsPaid(
    _ payment: ScheduledPayment, due: DateOnly, amount: AmountE4, on day: Date,
    paymentMethodId: UUID?, updatePrice: Bool, rate: Decimal? = nil
  ) -> Bool {
    markAsPaid(
      payment, due: due, amount: amount, on: day, account: paymentMethodId, charged: nil,
      updatePrice: updatePrice, rate: rate)
  }

  /// The moment «Провести» dates a payment of `due` with: an overdue one on its due day, at
  /// noon — it was debited then, and the month it belongs to must be right (review of the
  /// app, 19.09); one due today or ahead is dated now, as the entry line dates today's
  /// operations. Noon of today is hours ahead of the clock in the morning, and a
  /// reconciliation opened then counts nothing dated after its moment.
  static func paidAt(
    due: DateOnly, today: DateOnly, calendar: CalendarContext, now: Date = Date()
  ) -> Date {
    guard due < today else { return now }
    return calendar.startOfDay(due).addingTimeInterval(12 * 3600)
  }

  @discardableResult
  func skip(_ payment: ScheduledPayment, due: DateOnly) -> Bool {
    var rows = PlanningRows.empty
    rows.scheduled = [ScheduledRules.skip(payment, due: due)]
    return apply(
      PlanningChange(upsert: rows, rewritten: matchedOperations(of: payment, before: due)))
  }

  /// The ordinary operations that pay the due dates of `payment` from its `next_date` up to
  /// `due` by matching them, each keyed to its due date — as «Привязать» would — in the write
  /// that moves the payment past `due`. Once `next_date` is past them nothing matches them any
  /// more: unkeyed, what they paid would drop out of the month's funding, «проведено».
  func matchedOperations(
    of payment: ScheduledPayment, before due: DateOnly
  )
    -> [TransactionEntry]
  {
    guard let snapshot, let next = payment.nextDate else { return [] }
    let matches = snapshot.planning.matches
    return matches.matchedDues(of: payment.id).keys
      .filter { $0 >= next && $0 < due }
      .sorted()
      .compactMap { earlier in
        guard let operationId = matches.operation(for: payment.id, earlier),
          let entry = snapshot.ledger.entry(operationId)
        else { return nil }
        return ScheduledMatching.bind(entry, to: payment, due: earlier).operation
      }
  }

  /// «Привязать»: the ordinary operation that pays `due` of `payment` by matching it is keyed
  /// to that due date for good (`sched:<payment>:<due>`), as «Провести» would have written it;
  /// the payment moves past the due date when it was its next one (`ScheduledMatching.bind`).
  /// One write, one step of ⌘Z.
  @discardableResult
  func bind(_ operationId: UUID, to payment: ScheduledPayment, due: DateOnly) -> Bool {
    guard let snapshot, let entry = snapshot.ledger.entry(operationId) else { return false }
    let bound = ScheduledMatching.bind(
      entry, to: payment, due: due, matches: snapshot.planning.matches)
    var rows = PlanningRows.empty
    if bound.payment != payment { rows.scheduled = [bound.payment] }
    return apply(PlanningChange(upsert: rows, rewritten: [bound.operation]))
  }

  /// «Это другое»: the operation does not pay `due` of `payment`; the due date waits for its
  /// payment again. Kept in the settings of planning, the ones more than 400 days old let go,
  /// and — unlike a reminder put off — one step of ⌘Z: it changes what the plan counts.
  @discardableResult
  func reject(_ operationId: UUID, for payment: ScheduledPayment, due: DateOnly) -> Bool {
    // What is stored now, not the snapshot: two in a row must both stay.
    let key = PlanningSettings.scheduledMatchRejectionsKey
    let text = (try? environment.settings?.string(key)) ?? nil
    let stored = Set((text ?? "").split(whereSeparator: \.isNewline).map(String.init))
    let kept = ScheduledMatching.rejections(
      adding: ScheduledMatching.rejectionKey(operation: operationId, payment: payment.id, due: due),
      to: stored, today: environment.today)
    return apply(PlanningChange(settings: [key: kept.sorted().joined(separator: "\n")]))
  }

  /// A new or edited payment. One whose price changed today gets rows of its price history,
  /// so the history shows when it changed and the past keeps its price
  /// (`SubscriptionMath.priceEdit`).
  @discardableResult
  func save(_ payment: ScheduledPayment, previous: ScheduledPayment?) -> Bool {
    var rows = PlanningRows.empty
    var payment = payment
    payment.name = Self.trimmed(payment.name)
    if payment.nextDate == nil {
      payment.nextDate = Recurrence.firstOnOrAfter(
        environment.today, rule: RecurrenceRule(payment: payment))
    }
    rows.scheduled = [payment]
    var removed = PlanningRowIDs.empty
    if let previous {
      // The earliest day still priced: the last charge, or a due that is overdue.
      let lastCharge = snapshot?.planning.scheduled.first { $0.payment.id == payment.id }?
        .lastCharge?.due
      let since = [lastCharge, previous.nextDate].compactMap { $0 }.min()
      let edit = SubscriptionMath.priceEdit(
        previous: previous, updated: payment, prices: prices(of: payment),
        today: environment.today, since: since, charged: lastCharge)
      rows.prices = edit.rows
      removed.prices = edit.removed
    }
    return apply(PlanningChange(upsert: rows, delete: removed))
  }

  /// The price history of a payment as the database has it now: the screen may not have
  /// caught up with the last edit.
  private func prices(of payment: ScheduledPayment) -> [SubscriptionPrice] {
    let stored = try? environment.planning?.book().prices
    return (stored ?? snapshot?.dataset.planning.prices ?? []).filter { $0.paymentId == payment.id }
  }

  @discardableResult
  func delete(_ payment: ScheduledPayment) -> Bool {
    var ids = PlanningRowIDs.empty
    ids.scheduled = [payment.id]
    return apply(PlanningChange(delete: ids))
  }

  // MARK: Limits

  func issue(of budget: Budget) -> BudgetIssue? {
    guard let tree else { return nil }
    return LimitRules.validate(
      budget, tree: tree, existing: snapshot?.dataset.planning.budgets ?? [])
  }

  /// The same check for a form, which has the pipeline but not the whole set of dependencies.
  static func issue(of budget: Budget, compute: ComputeStore) -> BudgetIssue? {
    guard let snapshot = compute.snapshot else { return nil }
    return LimitRules.validate(
      budget, tree: snapshot.ledger.tree, existing: snapshot.dataset.planning.budgets)
  }

  @discardableResult
  func save(_ budget: Budget) -> Bool {
    guard issue(of: budget) == nil else { return false }
    // The row as the database has it now: the screen may not have caught up with the last edit.
    let stored =
      (try? environment.planning?.budgets()) ?? snapshot?.dataset.planning.budgets ?? []
    var rows = PlanningRows.empty
    rows.budgets = [
      LimitRules.saving(
        budget, over: stored.first { $0.id == budget.id }, in: environment.today.monthKey)
    ]
    return apply(PlanningChange(upsert: rows))
  }

  @discardableResult
  func delete(_ budget: Budget) -> Bool {
    var ids = PlanningRowIDs.empty
    ids.budgets = [budget.id]
    return apply(PlanningChange(delete: ids))
  }

  // MARK: Events

  /// Why an event cannot be saved: a key of the Planning table under `events.issue.`.
  enum EventIssue: String {
    case emptyName
    /// Another live event of that name covers some of the same days: the entry line could not
    /// tell them apart.
    case sameNameAndDays
  }

  static func issue(of event: Event, among events: [Event]) -> EventIssue? {
    guard !event.name.isEmpty else { return .emptyName }
    let clash = events.contains { other in
      other.id != event.id && !other.archived
        && other.name.compare(event.name, options: [.caseInsensitive]) == .orderedSame
        && other.startDate <= event.endDate && event.startDate <= other.endDate
    }
    return clash ? .sameNameAndDays : nil
  }

  /// A new or edited event with its budget, one write and one step of ⌘Z. A new one under the
  /// name of an event in the archive whose days meet its own brings that one back instead of
  /// making a second beside it.
  @discardableResult
  func save(_ event: Event) -> Bool {
    var event = event
    event.name = Self.trimmed(event.name)
    let known = (try? environment.references?.events(includeArchived: true)) ?? []
    guard Self.issue(of: event, among: known) == nil else { return false }
    if !known.contains(where: { $0.id == event.id }),
      let archived = known.first(where: { other in
        other.archived
          && other.name.compare(event.name, options: [.caseInsensitive]) == .orderedSame
          && other.startDate <= event.endDate && event.startDate <= other.endDate
      })
    {
      var revived = archived
      revived.archived = false
      revived.startDate = event.startDate
      revived.endDate = event.endDate
      revived.budgetE4 = event.budgetE4
      event = revived
    }
    var rows = PlanningRows.empty
    rows.events = [event]
    guard apply(PlanningChange(upsert: rows)) else { return false }
    environment.refreshVocabulary()
    return true
  }

  // MARK: Goals

  /// A goal gets its subcategory under Goals when it has none yet («у каждой цели своя
  /// подкатегория, она создаётся автоматически»); the category and the goal land together.
  private func withSubcategory(_ goal: Goal, rows: inout PlanningRows) -> Goal {
    // Once, never twice: a goal that has one keeps it even while the data on screen has not
    // caught up with the write that made it.
    // The goal as the database has it now: a second click before the screen caught up must
    // not make a second subcategory.
    var goal = goal
    if goal.subcategoryId == nil {
      goal.subcategoryId =
        (try? environment.references?.goals(includeArchived: true))?
        .first { $0.id == goal.id }?.subcategoryId
    }
    guard goal.subcategoryId == nil, let tree,
      let made = SystemSubcategories.goalSubcategory(for: goal, tree: tree)
    else {
      return goal
    }
    goal.subcategoryId = made.id
    rows.categories.append(made)
    return goal
  }

  /// The goal's own subcategory is named after it, so the name loses its spaces first.
  @discardableResult
  func save(_ goal: Goal) -> Bool {
    var goal = goal
    goal.name = Self.trimmed(goal.name)
    var rows = PlanningRows.empty
    rows.goals = [withSubcategory(goal, rows: &rows)]
    return apply(PlanningChange(upsert: rows))
  }

  @discardableResult
  func archive(_ goal: Goal) -> Bool {
    var goal = goal
    goal.archived = true
    var rows = PlanningRows.empty
    rows.goals = [goal]
    return apply(PlanningChange(upsert: rows))
  }

  /// «Contribute» — a good expense in the goal's subcategory; «Withdraw» — a refund in it,
  /// which lowers the progress.
  @discardableResult
  func move(
    _ goal: Goal, amount: AmountE4, on day: Date, paymentMethodId: UUID?, withdraw: Bool
  ) -> Bool {
    var rows = PlanningRows.empty
    let goal = withSubcategory(goal, rows: &rows)
    if !rows.categories.isEmpty { rows.goals = [goal] }
    guard let subcategoryId = goal.subcategoryId else { return false }
    let draft =
      withdraw
      ? GoalRules.withdrawalDraft(
        goal: goal, subcategoryId: subcategoryId, amount: amount, occurredAt: day,
        paymentMethodId: paymentMethodId)
      : GoalRules.contributionDraft(
        goal: goal, subcategoryId: subcategoryId, amount: amount, occurredAt: day,
        paymentMethodId: paymentMethodId)
    guard let entry = try? operation(draft, link: nil) else { return false }
    return apply(PlanningChange(created: [entry], upsert: rows))
  }

  // MARK: Expected income

  @discardableResult
  func save(_ income: ExpectedIncome) -> Bool {
    var income = income
    income.name = Self.trimmed(income.name)
    var rows = PlanningRows.empty
    rows.expected = [income]
    return apply(PlanningChange(upsert: rows))
  }

  @discardableResult
  func close(_ income: ExpectedIncome) -> Bool {
    var income = income
    income.closed = true
    return save(income)
  }

  @discardableResult
  func link(income transactionId: UUID, to expectation: ExpectedIncome) -> Bool {
    var rows = PlanningRows.empty
    rows.expectedLinks = [
      ExpectedIncomeLink(expectedIncomeId: expectation.id, transactionId: transactionId)
    ]
    return apply(PlanningChange(upsert: rows))
  }

  // MARK: Reconciliation

  /// Why saving the reconciliation sheet wrote nothing: a key of the Planning table.
  enum ReconcileFailure: String, Equatable {
    /// The write was refused; nothing was saved.
    case notSaved = "reconcile.notSaved"
    /// A difference asked for could not be written, so nothing was.
    case notRecorded = "reconcile.notRecorded"
    /// A difference in a currency without a rate today cannot be written in rubles.
    case rateMissing = "reconcile.rateMissing"
    /// No balance was counted.
    case nothingCounted = "reconcile.nothingCounted"
    /// A difference on an archived account or in a currency the account does not hold has no
    /// account to be written on.
    case notHeld = "reconcile.cannotRecord"
  }

  /// Saves the reconciliation sheet at `t0`: a counted balance for every account and currency
  /// in `counted`, and with `recordDifference` every difference as an operation in «Сверка» on
  /// its account, in its currency (`AccountReconciliation.record`) — all in one write and one
  /// step of ⌘Z. A balance counted for the first time is its starting point: nothing is
  /// compared and nothing else is written. Nil when it landed.
  ///
  /// `t0` is the moment the sheet counted the expected balances for, not the later instant of
  /// saving: an operation entered in between — through «Найти пропущенные…» while the sheet
  /// stood open — comes with new data and moves the sheet's moment, so it is either inside the
  /// expected balance or after the count, never written again as the difference.
  ///
  /// The «Сверка» categories themselves are outside that write: they are made the first time a
  /// difference is recorded, through the reference book, so ⌘Z takes the operations back and
  /// leaves the categories standing — the owner's categories now, to rename or to delete; the
  /// next difference makes them again.
  @discardableResult
  func reconcile(
    counted: [BalanceKey: AmountE4], rows: [ReconcileRow], recordDifference: Bool, at t0: Date
  ) -> ReconcileFailure? {
    // The journal gets the shape of it, never an amount: how many balances were counted and
    // compared, whether the differences were asked for.
    let compared = rows.filter { $0.expected != nil && counted[$0.key] != nil }.count
    let shape = [
      LogPair("balances", .count(counted.count)), LogPair("compared", .count(compared)),
      LogPair("record", .flag(recordDifference)),
    ]
    AppLog.info("reconcile.started", .db, "a reconciliation is being saved", shape)
    let differs = rows.contains { row in
      guard let expected = row.expected, let actual = counted[row.key] else { return false }
      return actual != expected
    }
    let writes = recordDifference && differs
    // The categories are looked up only when an operation is written: a count without a
    // difference to record makes nothing — nor one whose difference cannot be written.
    var categories: (expense: UUID, income: UUID)?
    if writes {
      guard ReconcileSheet.differencesNotHeld(rows: rows, counted: counted).isEmpty else {
        AppLog.error(
          "reconcile.failed", .db, "a difference has no account to be written on; nothing saved",
          shape)
        return .notHeld
      }
      guard
        ReconcileSheet.differencesWithoutRate(rows: rows, counted: counted, rubPerUnit: rubPerUnit)
          .isEmpty
      else {
        AppLog.error(
          "reconcile.failed", .db, "a difference has no rate today; nothing was saved", shape)
        return .rateMissing
      }
      categories = reconciliationCategories()
      guard categories != nil else {
        AppLog.error(
          "reconcile.failed", .db, "the difference could not be written; nothing was saved",
          shape)
        return .notRecorded
      }
    }
    let record = AccountReconciliation.record(
      counted: counted, rows: rows, writeDifference: writes, kind: .accounts, at: t0,
      calendar: environment.calendar, tree: tree ?? CategoryTree(),
      categories: categories ?? (UUID(), UUID()), rubPerUnit: rubPerUnit, makeId: { UUID() })
    guard !record.balances.isEmpty else { return .nothingCounted }
    // A difference asked for and not written fails the whole reconciliation: saved without
    // it, the sheet would close as if the operation were there.
    guard record.withoutRate.isEmpty else {
      AppLog.error(
        "reconcile.failed", .db, "a difference has no rate today; nothing was saved",
        shape + [LogPair("withoutRate", .count(record.withoutRate.count))])
      return .rateMissing
    }
    var written = PlanningRows.empty
    written.reconciliations = [record.reconciliation]
    written.reconciledBalances = record.balances
    guard apply(PlanningChange(created: record.differences, upsert: written)) else {
      AppLog.error("reconcile.failed", .db, "the reconciliation was not saved", shape)
      return writes ? .notRecorded : .notSaved
    }
    AppLog.info(
      "reconcile.saved", .db, "the reconciliation was saved",
      [
        LogPair("reconciliation", .id(record.reconciliation.id)),
        LogPair("balances", .count(record.balances.count)),
        LogPair("operations", .count(record.differences.count)),
      ])
    return nil
  }

  /// Where the difference of a reconciliation goes: «Сверка», a category of its own, one for
  /// expenses and one for income.
  ///
  /// What a reconciliation records is not a purchase the owner failed to place — it is the
  /// books catching up with the money, and it belongs in a line of its own rather than mixed
  /// into «Не помню». The two categories are ordinary ones: they are made the first time a
  /// difference is recorded, in the language the interface is in, and remembered by id in the
  /// settings, exactly as the cashback category is. Renamed by the owner, they keep working;
  /// deleted, they are made again.
  func reconciliationCategories() -> (expense: UUID, income: UUID)? {
    guard let references = environment.references, let settings = environment.settings else {
      return nil
    }
    // Archived rows included: «Сверка» is an ordinary category, so the owner can put it in
    // the archive — and a category the app still writes into must not stay there. Found
    // archived, it is brought back rather than made a second time.
    let existing = (try? references.categories(includeArchived: true)) ?? []
    func pick(_ key: String, _ kind: CategoryKind) -> UUID? {
      guard let text = (try? settings.string(key)) ?? nil, let id = UUID(uuidString: text),
        var found = existing.first(where: { $0.id == id }), found.kind == kind
      else { return nil }
      guard found.archived else { return found.id }
      found.archived = false
      guard (try? references.save(found)) != nil else { return nil }
      return found.id
    }
    func make(_ key: String, _ kind: CategoryKind) -> UUID? {
      let name = environment.language("categories.reconciliation", table: "Settings")
      let sort =
        (existing.filter { $0.kind == kind && $0.parentId == nil }.map(\.sort).max() ?? 0)
        + 1
      let category = CoreKit.Category(
        parentId: nil, kind: kind, name: name, sort: sort,
        quality: kind == .expense ? .neutral : nil)
      guard (try? references.save(category)) != nil,
        (try? settings.set(key, to: category.id.uuidString)) != nil
      else { return nil }
      return category.id
    }
    let expense =
      pick(PlanningSettings.reconcileExpenseCategoryKey, .expense)
      ?? make(PlanningSettings.reconcileExpenseCategoryKey, .expense)
    let income =
      pick(PlanningSettings.reconcileIncomeCategoryKey, .income)
      ?? make(PlanningSettings.reconcileIncomeCategoryKey, .income)
    guard let expense, let income else { return nil }
    environment.refreshVocabulary()
    environment.scheduleBackup()
    return (expense, income)
  }

  // MARK: Reminders

  /// Puts a reminder off until it changes: its id carries its date or price. Not undone by
  /// ⌘Z: the reminder is not a record of the books.
  @discardableResult
  func dismiss(_ reminder: Reminder) -> Bool {
    // What is stored now, not the snapshot: two × in a row must both stay.
    let text = (try? environment.settings?.string(PlanningSettings.dismissedRemindersKey)) ?? nil
    let stored = Set((text ?? "").split(whereSeparator: \.isNewline).map(String.init))
    // Forgotten are only the ids that no longer remind of anything (ReminderRules.dismissed).
    let active = snapshot.map { snapshot in
      Set(
        ReminderRules.all(
          book: snapshot.planning.book, debts: snapshot.ledger.dataset.debts,
          ledger: snapshot.ledger, today: environment.today
        ).map(\.id))
    }
    let kept = ReminderRules.dismissed(adding: reminder.id, to: stored, active: active)
    // A preference of the reminders, not a change of the books: written as a setting, with
    // no step of ⌘Z — one would take the ⌘Z the owner meant for the operation he had just
    // written and bring the reminder back instead. The observation of the database carries
    // it to the pipeline, as it does every setting.
    guard let settings = environment.settings else { return false }
    do {
      try settings.set(
        PlanningSettings.dismissedRemindersKey, to: kept.sorted().joined(separator: "\n"))
    } catch {
      AppLog.error(
        "reminder.dismissFailed", .db, "a reminder was not put off",
        [LogPair("error", .error(error))])
      return false
    }
    environment.scheduleBackup()
    return true
  }
}
