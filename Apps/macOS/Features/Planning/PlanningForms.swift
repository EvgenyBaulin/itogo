import AppCore
import SwiftUI

/// The forms of the Planning section, one sheet at a time on the root of the section. A form
/// is content: system `Form`, no glass of its own. «Save» writes one `PlanningChange` — one
/// step of ⌘Z — and closes the sheet only over a write that landed.
struct PlanningSheetView: View {
  let sheet: PlanningSheet

  var body: some View {
    switch sheet {
    case .payment, .newPayment:
      ScheduledPaymentForm(original: sheet.editedPayment, start: sheet.startingPayment)
    case .markAsPaid(let status): MarkAsPaidForm(status: status)
    case .budget(let budget): BudgetForm(original: budget)
    case .goal(let goal): GoalForm(original: goal)
    case .moveGoal(let status, let withdraw): GoalMoveForm(status: status, withdraw: withdraw)
    case .expected(let income): ExpectedIncomeForm(original: income)
    case .linkIncome(let status): LinkIncomeForm(status: status)
    }
  }
}

/// The dictionaries the forms offer, from the data on screen: archived values are left out.
@MainActor
struct PlanningChoices {
  let categories: [CoreKit.Category]
  let methods: [PaymentMethod]
  let people: [Person]
  let currencies: [CurrencyCode]
  let tree: CategoryTree?

  init(_ compute: ComputeStore, _ environment: AppEnvironment) {
    let dataset = compute.snapshot?.dataset
    categories = (dataset?.categories ?? []).filter { !$0.archived }
    methods = (dataset?.paymentMethods ?? []).filter { !$0.archived }
    people = (dataset?.people ?? []).filter { !$0.archived }
    let enabled = (try? environment.settings?.enabledCurrencies()) ?? []
    currencies = enabled.isEmpty ? [.rub] : enabled
    tree = compute.snapshot?.ledger.tree
  }

  /// Categories of this kind, parents followed by their children, without system ones.
  func options(_ kind: CategoryKind, acceptingLimits: Bool = false) -> [CoreKit.Category] {
    let own = categories.filter { $0.kind == kind && $0.systemRole == nil }
    let roots = own.filter { $0.parentId == nil }.sorted { ($0.sort, $0.name) < ($1.sort, $1.name) }
    return roots.flatMap { root in
      [root]
        + own.filter { $0.parentId == root.id }.sorted { ($0.sort, $0.name) < ($1.sort, $1.name) }
    }
    .filter { !acceptingLimits || (tree?.acceptsLimit($0.id) ?? true) }
  }

  func label(_ category: CoreKit.Category) -> String {
    category.parentId == nil ? category.name : "   \(category.name)"
  }
}

/// Buttons at the bottom of every form: «Cancel» and the main action, which is disabled
/// while the form cannot be saved.
struct FormButtons: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  let title: String
  let enabled: Bool
  /// Why the save did not happen, asked only when it did not: a form is never left open
  /// without a word (review of the app, 19.09).
  let failure: () -> String
  let save: () -> Bool
  @State private var failed: String?

  init(
    title: String, enabled: Bool, failure: (() -> String)? = nil, save: @escaping () -> Bool
  ) {
    self.title = title
    self.enabled = enabled
    self.failure = failure ?? { "" }
    self.save = save
  }

  var body: some View {
    VStack(alignment: .trailing, spacing: 6) {
      if let failed {
        Text(verbatim: failed)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(title) {
          if save() {
            dismiss()
          } else {
            let reason = failure()
            failed =
              reason.isEmpty ? environment.language("form.notSaved", table: "Planning") : reason
          }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!enabled)
      }
    }
    .padding(.top, 8)
  }
}

// MARK: - A scheduled payment

private struct ScheduledPaymentForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  /// The payment edited — saved over it, with a price edit — or nil for a new one.
  let original: ScheduledPayment?
  /// What the form starts with: `original`, or a new payment filled in from a candidate.
  let start: ScheduledPayment?
  @State private var payment = ScheduledPayment(name: "", amountE4: .zero)
  @State private var loaded = false
  @State private var hasEnd = false
  @State private var hasTrial = false

  var body: some View {
    let choices = PlanningChoices(compute, environment)
    VStack(alignment: .leading) {
      Text(verbatim: t(original == nil ? "form.payment.new" : "form.payment.edit"))
        .font(.headline)
      Form {
        TextField(t("form.name"), text: $payment.name)
        Picker(t("form.kind"), selection: $payment.kind) {
          Text(verbatim: t("form.kind.bill")).tag(ScheduledKind.bill)
          Text(verbatim: t("form.kind.subscription")).tag(ScheduledKind.subscription)
        }
        .pickerStyle(.segmented)
        LabeledContent(t("form.amount")) {
          HStack {
            AmountField(amount: $payment.amountE4, locale: environment.language.locale)
            Picker(selection: $payment.currency) {
              ForEach(choices.currencies, id: \.self) { Text(verbatim: $0.code).tag($0) }
            } label: {
              EmptyView()
            }
            .labelsHidden()
            .fixedSize()
          }
        }
        Picker(t("form.category"), selection: $payment.categoryId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(choices.options(.expense)) {
            Text(verbatim: choices.label($0)).tag(Optional($0.id))
          }
        }
        Picker(t("form.method"), selection: $payment.paymentMethodId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(choices.methods) { Text(verbatim: $0.name).tag(Optional($0.id)) }
        }
        Picker(t("form.freq"), selection: $payment.freq) {
          ForEach(Frequency.allCases, id: \.self) {
            Text(verbatim: t("form.freq.\($0.rawValue)")).tag($0)
          }
        }
        Stepper(value: $payment.interval, in: 1...24) {
          Text(
            verbatim: environment.language.format(
              "form.interval", table: "Planning", payment.interval))
        }
        DatePicker(
          t("form.nextDate"),
          selection: day($payment.nextDate, fallback: environment.today), displayedComponents: .date
        )
        Toggle(t("form.hasEnd"), isOn: $hasEnd)
          .onChange(of: hasEnd) { _, on in
            if on, payment.endDate == nil { payment.endDate = environment.today }
          }
        if hasEnd {
          DatePicker(
            t("form.endDate"), selection: day($payment.endDate, fallback: environment.today),
            displayedComponents: .date)
        }
        Section {
          Picker(t("form.forWhom"), selection: $payment.forWhom) {
            ForEach(ForWhom.allCases, id: \.self) {
              Text(verbatim: environment.label(for: $0)).tag($0)
            }
          }
          Toggle(t("form.reimbursable"), isOn: $payment.reimbursable)
          if payment.reimbursable {
            Picker(t("form.debtor"), selection: $payment.debtorPersonId) {
              Text(verbatim: "—").tag(UUID?.none)
              ForEach(choices.people) { Text(verbatim: $0.name).tag(Optional($0.id)) }
            }
            LabeledContent(t("form.returns")) {
              AmountField(
                amount: Binding(
                  get: { payment.reimbursementAmountE4 ?? payment.amountE4 },
                  set: { payment.reimbursementAmountE4 = $0 }),
                locale: environment.language.locale)
            }
          }
        }
        if payment.kind == .subscription {
          Section {
            Toggle(t("form.hasTrial"), isOn: $hasTrial)
              .onChange(of: hasTrial) { _, on in
                if on, payment.trialEnd == nil { payment.trialEnd = environment.today }
              }
            if hasTrial {
              DatePicker(
                t("form.trialEnd"), selection: day($payment.trialEnd, fallback: environment.today),
                displayedComponents: .date)
            }
            TextField(
              t("form.cancelURL"),
              text: Binding(
                get: { payment.cancelURL ?? "" }, set: { payment.cancelURL = $0.isEmpty ? nil : $0 }
              ))
          }
        }
        Stepper(
          value: Binding(
            get: { payment.remindDaysBefore ?? 3 }, set: { payment.remindDaysBefore = $0 }),
          in: 0...30
        ) {
          Text(
            verbatim: environment.language.format(
              "form.remind", table: "Planning", payment.remindDaysBefore ?? 3))
        }
        if let issue = issue(choices) {
          Text(verbatim: t(issue.key)).font(.caption).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      FormButtons(title: environment.language("action.save"), enabled: issue(choices) == nil) {
        guard let dependencies else { return false }
        var saved = payment
        if !hasEnd { saved.endDate = nil }
        if !hasTrial { saved.trialEnd = nil }
        // The rule's day follows the due date and the frequency: a weekday for a weekly
        // payment, a day of the month, and the month too for a yearly one.
        if let next = saved.nextDate {
          let anchor = Recurrence.anchor(of: next, freq: saved.freq)
          saved.day = anchor.day
          saved.month = anchor.month
        }
        return PlanningActions(dependencies).save(saved, previous: original)
      }
    }
    .padding(20)
    .frame(width: 520, height: 640)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      payment = start ?? ScheduledPayment(name: "", amountE4: .zero, nextDate: environment.today)
      hasEnd = payment.endDate != nil
      hasTrial = payment.trialEnd != nil
      if payment.remindDaysBefore == nil { payment.remindDaysBefore = 3 }
    }
  }

  private func issue(_ choices: PlanningChoices) -> ScheduledIssue? {
    guard let tree = choices.tree else { return nil }
    return ScheduledRules.validate(payment, tree: tree)
  }

  private func day(_ value: Binding<DateOnly?>, fallback: DateOnly) -> Binding<Date> {
    Binding(
      get: { environment.calendar.startOfDay(value.wrappedValue ?? fallback) },
      set: { value.wrappedValue = environment.calendar.day(of: $0) })
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

// MARK: - Mark as paid

private struct MarkAsPaidForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let status: ScheduledStatus
  @State private var amount: AmountE4 = .zero
  @State private var date = Date()
  @State private var method: UUID?
  @State private var updatePrice = false
  /// Read as typed, like the rate field of the ↓ panel: a value field would take it only on
  /// Return, and «Провести» would save the one before.
  @State private var rateText = ""
  @State private var needsRate = false
  @State private var loaded = false

  var body: some View {
    let choices = PlanningChoices(compute, environment)
    let payment = status.payment
    VStack(alignment: .leading) {
      Text(verbatim: environment.format("form.markAsPaid.title", table: "Planning", payment.name))
        .font(.headline)
      Text(
        verbatim: environment.format(
          "form.markAsPaid.due", table: "Planning",
          environment.dates.longDay(status.nextDue))
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Form {
        LabeledContent(t("form.amount")) {
          HStack {
            AmountField(amount: $amount, locale: environment.language.locale)
            Text(verbatim: payment.currency.code).foregroundStyle(.secondary)
          }
        }
        DatePicker(t("form.date"), selection: $date)
        if needsRate {
          // No rate of the bank for this currency and day: one typed by hand, as in the
          // entry line.
          LabeledContent(
            environment.format("form.rate", table: "Planning", payment.currency.code)
          ) {
            TextField("", text: $rateText)
              .multilineTextAlignment(.trailing)
          }
        }
        Picker(t("form.method"), selection: $method) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(choices.methods) { Text(verbatim: $0.name).tag(Optional($0.id)) }
        }
        if payment.kind == .subscription, amount != status.amountNext {
          Toggle(t("form.updatePrice"), isOn: $updatePrice)
        }
        if payment.reimbursable {
          Text(
            verbatim: environment.format(
              "form.markAsPaid.forOther", table: "Planning",
              choices.people.first { $0.id == payment.debtorPersonId }?.name ?? "—",
              environment.money.exact(
                payment.reimbursementAmountE4 ?? amount,
                currency: payment.reimbursementCurrency ?? payment.currency))
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      FormButtons(
        title: t("scheduled.markAsPaid"),
        enabled: amount.raw > 0 && (!needsRate || rate != nil),
        failure: { failure(payment.currency) }
      ) {
        guard let dependencies else { return false }
        return PlanningActions(dependencies).markAsPaid(
          payment, due: status.nextDue, amount: amount, on: date, paymentMethodId: method,
          updatePrice: updatePrice, rate: needsRate ? rate : nil)
      }
    }
    .padding(20)
    .frame(width: 460, height: 420)
    // Read once per day chosen, not on every keystroke: it asks the cache of rates.
    .onChange(of: date, initial: true) {
      needsRate = !environment.knowsRate(status.payment.currency, on: date)
    }
    .onAppear {
      guard !loaded else { return }
      loaded = true
      amount = status.amountNext
      method = payment.paymentMethodId
      date = PlanningActions.paidAt(
        due: status.nextDue, today: environment.today, calendar: environment.calendar)
    }
  }

  /// The rate typed by hand: a positive number, with a comma or a point.
  private var rate: Decimal? {
    DecimalMath.parse(rateText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
  }

  private func failure(_ currency: CurrencyCode) -> String {
    // A rate typed by hand was there: whatever failed, it was not the rate.
    guard let dependencies, !(needsRate && rate != nil) else { return "" }
    return environment.format(
      PlanningActions(dependencies).failureKey(currency: currency, on: date), table: "Planning",
      currency.code)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

// MARK: - A limit

private struct BudgetForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let original: Budget?
  @State private var budget = Budget(scope: .category, amountE4: .zero)
  @State private var loaded = false

  var body: some View {
    let choices = PlanningChoices(compute, environment)
    VStack(alignment: .leading) {
      Text(verbatim: t(original == nil ? "form.limit.new" : "form.limit.edit")).font(.headline)
      Form {
        Picker(t("form.limit.scope"), selection: $budget.scope) {
          Text(verbatim: t("form.limit.scope.category")).tag(BudgetScope.category)
          Text(verbatim: t("limit.badTotal")).tag(BudgetScope.badTotal)
          Text(verbatim: t("form.limit.scope.forWhom")).tag(BudgetScope.forWhom)
        }
        .pickerStyle(.segmented)
        switch budget.scope {
        case .category:
          Picker(t("form.category"), selection: $budget.categoryId) {
            Text(verbatim: "—").tag(UUID?.none)
            ForEach(choices.options(.expense, acceptingLimits: true)) {
              Text(verbatim: choices.label($0)).tag(Optional($0.id))
            }
          }
        case .forWhom:
          Picker(t("form.forWhom"), selection: $budget.forWhom) {
            Text(verbatim: "—").tag(ForWhom?.none)
            ForEach(ForWhom.allCases, id: \.self) {
              Text(verbatim: environment.label(for: $0)).tag(Optional($0))
            }
          }
        case .badTotal:
          EmptyView()
        }
        LabeledContent(t("form.limit.amount")) {
          AmountField(amount: $budget.amountE4, locale: environment.language.locale)
        }
        Toggle(t("form.limit.rollover"), isOn: $budget.rollover)
        if let issue = PlanningActions.issue(of: normalized, compute: compute) {
          Text(verbatim: t("limit.issue.\(issue.rawValue)")).font(.caption).foregroundStyle(
            .secondary)
        }
      }
      .formStyle(.grouped)
      FormButtons(
        title: environment.language("action.save"),
        enabled: PlanningActions.issue(of: normalized, compute: compute) == nil
      ) {
        guard let dependencies else { return false }
        return PlanningActions(dependencies).save(normalized)
      }
    }
    .padding(20)
    .frame(width: 460, height: 360)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      budget = original ?? Budget(scope: .category, amountE4: .zero)
    }
  }

  /// Only the field of the chosen scope stays.
  private var normalized: Budget {
    var budget = budget
    if budget.scope != .category { budget.categoryId = nil }
    if budget.scope != .forWhom { budget.forWhom = nil }
    return budget
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

// MARK: - A goal

private struct GoalForm: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let original: Goal?
  @State private var goal = Goal(name: "", targetE4: .zero)
  @State private var hasDate = false
  @State private var loaded = false

  var body: some View {
    VStack(alignment: .leading) {
      Text(verbatim: t(original == nil ? "form.goal.new" : "form.goal.edit")).font(.headline)
      Form {
        TextField(t("form.name"), text: $goal.name)
        LabeledContent(t("form.goal.target")) {
          AmountField(amount: $goal.targetE4, locale: environment.language.locale)
        }
        Toggle(t("form.goal.hasDate"), isOn: $hasDate)
          .onChange(of: hasDate) { _, on in
            if on, goal.targetDate == nil { goal.targetDate = environment.today }
          }
        if hasDate {
          DatePicker(
            t("form.goal.date"),
            selection: Binding(
              get: { environment.calendar.startOfDay(goal.targetDate ?? environment.today) },
              set: { goal.targetDate = environment.calendar.day(of: $0) }),
            displayedComponents: .date)
        }
        LabeledContent(t("form.goal.plan")) {
          AmountField(
            amount: Binding(
              get: { goal.monthlyPlanE4 ?? .zero },
              set: { goal.monthlyPlanE4 = $0.isZero ? nil : $0 }),
            locale: environment.language.locale)
        }
      }
      .formStyle(.grouped)
      FormButtons(
        title: environment.language("action.save"),
        enabled: !goal.name.trimmingCharacters(in: .whitespaces).isEmpty && goal.targetE4.raw > 0
      ) {
        guard let dependencies else { return false }
        var saved = goal
        if !hasDate { saved.targetDate = nil }
        return PlanningActions(dependencies).save(saved)
      }
    }
    .padding(20)
    .frame(width: 460, height: 360)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      goal = original ?? Goal(name: "", targetE4: .zero)
      hasDate = goal.targetDate != nil
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

private struct GoalMoveForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let status: GoalStatus
  let withdraw: Bool
  @State private var amount: AmountE4 = .zero
  @State private var date = Date()
  @State private var method: UUID?

  var body: some View {
    let choices = PlanningChoices(compute, environment)
    VStack(alignment: .leading) {
      Text(
        verbatim: environment.format(
          withdraw ? "form.withdraw.title" : "form.contribute.title", table: "Planning",
          status.goal.name)
      )
      .font(.headline)
      Form {
        LabeledContent(t("form.amount")) {
          AmountField(amount: $amount, locale: environment.language.locale)
        }
        DatePicker(t("form.date"), selection: $date)
        Picker(t("form.method"), selection: $method) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(choices.methods) { Text(verbatim: $0.name).tag(Optional($0.id)) }
        }
        if !withdraw, let needed = status.neededMonthly {
          Text(
            verbatim: environment.format(
              "goals.needed", table: "Planning", environment.money.rounded(needed))
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      FormButtons(
        title: t(withdraw ? "goals.withdraw" : "goals.contribute"),
        enabled: amount.raw > 0 && (!withdraw || amount <= status.saved)
      ) {
        guard let dependencies else { return false }
        return PlanningActions(dependencies).move(
          status.goal, amount: amount, on: date, paymentMethodId: method, withdraw: withdraw)
      }
    }
    .padding(20)
    .frame(width: 420, height: 300)
    .onAppear {
      if !withdraw, let plan = status.goal.monthlyPlanE4 { amount = plan }
      method = choices.methods.first { $0.isDefault }?.id
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

// MARK: - Expected income

private struct ExpectedIncomeForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let original: ExpectedIncome?
  @State private var income = ExpectedIncome(name: "", totalE4: .zero)
  @State private var loaded = false

  var body: some View {
    let choices = PlanningChoices(compute, environment)
    VStack(alignment: .leading) {
      Text(verbatim: t(original == nil ? "form.expected.new" : "form.expected.edit")).font(
        .headline)
      Form {
        TextField(t("form.name"), text: $income.name)
        Picker(t("form.kind"), selection: $income.kind) {
          Text(verbatim: t("form.expected.oneOff")).tag(ExpectedIncomeKind.oneOff)
          Text(verbatim: t("form.expected.recurring")).tag(ExpectedIncomeKind.recurring)
        }
        .pickerStyle(.segmented)
        LabeledContent(t(income.kind == .oneOff ? "form.expected.total" : "form.expected.each")) {
          HStack {
            AmountField(amount: $income.totalE4, locale: environment.language.locale)
            Picker(selection: $income.currency) {
              ForEach(choices.currencies, id: \.self) { Text(verbatim: $0.code).tag($0) }
            } label: {
              EmptyView()
            }
            .labelsHidden()
            .fixedSize()
          }
        }
        Stepper(value: $income.partsExpected, in: 1...12) {
          Text(
            verbatim: environment.language.format(
              "form.expected.parts", table: "Planning", income.partsExpected))
        }
        DatePicker(
          t("form.expected.due"),
          selection: Binding(
            get: { environment.calendar.startOfDay(income.dueDate ?? environment.today) },
            set: { income.dueDate = environment.calendar.day(of: $0) }),
          displayedComponents: .date)
        if income.kind == .recurring {
          Picker(
            t("form.freq"),
            selection: Binding(get: { income.freq ?? .monthly }, set: { income.freq = $0 })
          ) {
            ForEach(Frequency.allCases, id: \.self) {
              Text(verbatim: t("form.freq.\($0.rawValue)")).tag($0)
            }
          }
        }
        Picker(t("form.category"), selection: $income.categoryId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(choices.options(.income)) {
            Text(verbatim: choices.label($0)).tag(Optional($0.id))
          }
        }
        Picker(t("form.person"), selection: $income.personId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(choices.people) { Text(verbatim: $0.name).tag(Optional($0.id)) }
        }
      }
      .formStyle(.grouped)
      HStack {
        if let original, !original.closed {
          Button(t("expected.close")) {
            if let dependencies, PlanningActions(dependencies).close(original) { dismiss() }
          }
        }
        FormButtons(
          title: environment.language("action.save"),
          enabled: !income.name.trimmingCharacters(in: .whitespaces).isEmpty
            && income.totalE4.raw > 0
        ) {
          guard let dependencies else { return false }
          return PlanningActions(dependencies).save(income.readyToSave(today: environment.today))
        }
      }
    }
    .padding(20)
    .frame(width: 480, height: 520)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      income = original ?? ExpectedIncome(name: "", totalE4: .zero, dueDate: environment.today)
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

extension ExpectedIncome {
  /// The row the form saves: a recurring income keeps its frequency and the day of it, a
  /// one-off one neither, and a due date left empty is today — the day the date field shows.
  func readyToSave(today: DateOnly) -> ExpectedIncome {
    var saved = self
    // The date first: the day of the schedule is read off it.
    if saved.dueDate == nil { saved.dueDate = today }
    if saved.kind == .recurring {
      saved.freq = saved.freq ?? .monthly
      saved.day = saved.dueDate.map {
        Recurrence.anchor(of: $0, freq: saved.freq ?? .monthly).day
      }
    } else {
      saved.freq = nil
      saved.day = nil
    }
    return saved
  }
}

/// Ties an income already received to what was expected: the income of the last 60 days not
/// tied to anything yet, the likeliest first (same category and person).
private struct LinkIncomeForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let status: ExpectedIncomeStatus

  var body: some View {
    let candidates = self.candidates
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: environment.format("form.link.title", table: "Planning", status.income.name))
        .font(.headline)
      if candidates.isEmpty {
        Text(verbatim: t("form.link.none")).foregroundStyle(.secondary)
      }
      List(candidates, id: \.id) { entry in
        HStack {
          Text(
            verbatim: environment.dates.longDay(
              environment.calendar.day(of: entry.transaction.occurredAt))
          )
          .monospacedDigit()
          .foregroundStyle(.secondary)
          Text(verbatim: entry.transaction.note ?? "—").lineLimit(1)
          Spacer()
          Text(
            verbatim: environment.money.exact(
              entry.transaction.amountE4, currency: entry.transaction.currency)
          )
          .monospacedDigit()
          Button(t("expected.link")) {
            guard let dependencies else { return }
            if PlanningActions(dependencies).link(income: entry.id, to: status.income) { dismiss() }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
      .frame(minHeight: 220)
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 520, height: 380)
  }

  private var candidates: [TransactionEntry] {
    guard let snapshot = compute.snapshot else { return [] }
    let linked = Set(snapshot.dataset.planning.expectedLinks.map(\.transactionId))
    let since = environment.calendar.adding(days: -60, to: snapshot.today)
    return snapshot.dataset.entries
      .filter {
        $0.transaction.kind == .income && !$0.transaction.isDeleted && !linked.contains($0.id)
          && environment.calendar.day(of: $0.transaction.occurredAt) >= since
      }
      .sorted { lhs, rhs in
        let left = likely(lhs)
        let right = likely(rhs)
        return left != right ? left : lhs.transaction.occurredAt > rhs.transaction.occurredAt
      }
  }

  private func likely(_ entry: TransactionEntry) -> Bool {
    entry.parts.contains {
      $0.categoryId == status.income.categoryId && status.income.categoryId != nil
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
