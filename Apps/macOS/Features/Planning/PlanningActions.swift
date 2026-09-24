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

  /// «Mark as paid». `rate` is one typed by hand, for a currency the cache has no rate for.
  @discardableResult
  func markAsPaid(
    _ payment: ScheduledPayment, due: DateOnly, amount: AmountE4, on day: Date,
    paymentMethodId: UUID?, updatePrice: Bool, rate: Decimal? = nil
  ) -> Bool {
    do {
      let plan = try ScheduledRules.markAsPaid(
        payment, due: due, amount: amount, occurredAt: day, paidAt: rate, rubPerUnit: rubPerUnit,
        updatePrice: updatePrice, prices: snapshot?.dataset.planning.prices ?? [],
        categories: tree ?? CategoryTree(), history: qualityHistory())
      // The card of this one payment; the payment keeps its own (review of the app, 19.09).
      var draft = plan.draft
      draft.paymentMethodId = paymentMethodId
      // A rate by hand is the rate of the day it was typed for, like one in the entry line.
      if draft.rateSource == .manual { draft.rateDate = environment.calendar.day(of: day) }
      let entry = try operation(draft, link: .scheduled(paymentId: payment.id, due: due))
      var rows = PlanningRows.empty
      rows.scheduled = [plan.payment]
      if let price = plan.newPrice { rows.prices = [price] }
      return apply(PlanningChange(created: [entry], upsert: rows))
    } catch {
      return false
    }
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
    return apply(PlanningChange(upsert: rows))
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

  /// Saves the reconciliation, and with `recordDifference` the difference as an operation in
  /// «Сверка» — both in one write and one step of ⌘Z.
  ///
  /// One thing is deliberately outside that write: the «Сверка» categories themselves. They
  /// are made the first time a difference is recorded, through the reference book, so ⌘Z of
  /// the reconciliation takes the operation back and leaves the two categories standing. That
  /// is the intent — they are the owner's categories now, to rename or to delete — and it is
  /// why deleting them is safe: the next difference makes them again.
  ///
  /// A reconciliation measured against an expectation is stamped with the moment that
  /// expectation was counted for (`expectation.to`), not with `now`: the next window starts
  /// where this one ended. Stamped with the later instant of saving, an operation dated in
  /// between — entered through «Найти пропущенные…» while the sheet stood open — fell into
  /// neither window, and its money was written a second time as the difference. `now` is the
  /// moment of the starting point, which has no expectation.
  @discardableResult
  func reconcile(
    actual: AmountE4, breakdown: [ReconciliationAmount], expectation: ReconciliationExpectation?,
    recordDifference: Bool, now: Date = Date()
  ) -> Bool {
    // The journal gets the shape of it, never an amount: how many amounts were counted,
    // whether there was an expectation, whether the difference was asked for
    // («сверка: начало, результат, … число записей»).
    let shape = [
      LogPair("breakdown", .count(breakdown.count)),
      LogPair("expectation", .flag(expectation != nil)),
      LogPair("record", .flag(recordDifference)),
    ]
    AppLog.info("reconcile.started", .db, "a reconciliation is being saved", shape)
    let id = UUID()
    let at = expectation?.to ?? now
    var reconciliation = Reconciliation(
      id: id, date: environment.calendar.day(of: at), reconciledAt: at,
      actualTotalRubE4: actual, breakdown: breakdown)
    var created: [TransactionEntry] = []
    if let expectation {
      let difference = actual - expectation.expected
      reconciliation.expectedTotalRubE4 = expectation.expected
      reconciliation.differenceE4 = difference
      // A difference asked for and not written fails the whole reconciliation: saved without
      // it, the sheet would close as if the operation were there, and the books would stay
      // short by the difference with nothing on screen to say so.
      if recordDifference, !difference.isZero {
        guard let where_ = reconciliationCategories(),
          let draft = ReconciliationRules.differenceDraft(
            difference: difference, occurredAt: at, expenseCategoryId: where_.expense,
            incomeCategoryId: where_.income, categories: tree ?? CategoryTree()),
          let entry = try? operation(draft, link: .reconciliation(id))
        else {
          AppLog.error(
            "reconcile.failed", .db, "the difference could not be written; nothing was saved",
            shape)
          return false
        }
        reconciliation.transactionId = entry.id
        created = [entry]
      }
    }
    var rows = PlanningRows.empty
    rows.reconciliations = [reconciliation]
    guard apply(PlanningChange(created: created, upsert: rows)) else {
      AppLog.error("reconcile.failed", .db, "the reconciliation was not saved", shape)
      return false
    }
    AppLog.info(
      "reconcile.saved", .db, "the reconciliation was saved",
      [LogPair("reconciliation", .id(id)), LogPair("operations", .count(created.count))])
    return true
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
