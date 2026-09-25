import AppCore
import SwiftUI

// The forms of the Planning section, one sheet at a time on the root of the section. A form
// is content: system `Form`, no glass of its own. «Save» writes one `PlanningChange` — one
// step of ⌘Z — and closes the sheet only over a write that landed.

// MARK: - A scheduled payment

struct ScheduledPaymentForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  /// The payment edited — saved over it, with a price edit — or nil for a new one.
  let original: ScheduledPayment?
  /// What the form starts with: `original`, or a new payment filled in from a candidate.
  let start: ScheduledPayment?
  /// The payment and the choices of its schedule: «How often» as a preset, «Once», or
  /// «Other…» with the unit and interval shown for editing; the last-day switch; the end and
  /// the trial.
  @State private var draft = ScheduledPaymentDraft(
    opening: ScheduledPayment(name: "", amountE4: .zero))
  @State private var loaded = false

  var body: some View {
    let choices = PlanningChoices(compute, environment)
    VStack(alignment: .leading) {
      Text(verbatim: t(original == nil ? "form.payment.new" : "form.payment.edit"))
        .font(.headline)
      Form {
        TextField(t("form.name"), text: $draft.payment.name)
        Picker(t("form.kind"), selection: $draft.payment.kind) {
          Text(verbatim: t("form.kind.bill")).tag(ScheduledKind.bill)
          Text(verbatim: t("form.kind.subscription")).tag(ScheduledKind.subscription)
        }
        .pickerStyle(.segmented)
        LabeledContent(t("form.amount")) {
          HStack {
            AmountField(amount: $draft.payment.amountE4, locale: environment.language.locale)
            Picker(selection: $draft.payment.currency) {
              ForEach(choices.currencies, id: \.self) { Text(verbatim: $0.code).tag($0) }
            } label: {
              EmptyView()
            }
            .labelsHidden()
            .fixedSize()
          }
        }
        Picker(t("form.category"), selection: $draft.payment.categoryId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(choices.options(.expense)) {
            Text(verbatim: choices.label($0)).tag(Optional($0.id))
          }
        }
        Picker(t("form.method"), selection: $draft.payment.paymentMethodId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(choices.methods) { Text(verbatim: $0.name).tag(Optional($0.id)) }
        }
        Picker(t("form.freq"), selection: presetBinding) {
          ForEach(FrequencyPreset.allCases, id: \.self) { preset in
            if preset == .once || preset == .other { Divider() }
            Text(verbatim: t(preset.key)).tag(preset)
          }
        }
        if draft.preset == .other {
          Picker(t("form.unit"), selection: unitBinding) {
            ForEach(Frequency.allCases, id: \.self) {
              Text(verbatim: t("form.unit.\($0.rawValue)")).tag($0)
            }
          }
          .pickerStyle(.segmented)
          Stepper(value: $draft.payment.interval, in: FrequencyPreset.intervals) {
            Text(
              verbatim: FrequencyPreset.everyText(
                draft.payment.freq, interval: draft.payment.interval,
                language: environment.language))
          }
        }
        DatePicker(
          t(draft.preset == .once ? "form.date" : "form.nextDate"),
          selection: nextDateBinding, displayedComponents: .date
        )
        if draft.offersLastDay {
          Toggle(t("form.lastDay"), isOn: lastDayBinding)
        }
        if draft.offersEnd {
          Toggle(
            t("form.hasEnd"),
            isOn: Binding(
              get: { draft.hasEnd }, set: { draft.setHasEnd($0, today: environment.today) }))
          if draft.hasEnd {
            DatePicker(
              t("form.endDate"),
              selection: day($draft.payment.endDate, fallback: environment.today),
              displayedComponents: .date)
          }
        }
        Section {
          Picker(t("form.forWhom"), selection: $draft.payment.forWhom) {
            ForEach(ForWhom.allCases, id: \.self) {
              Text(verbatim: environment.label(for: $0)).tag($0)
            }
          }
          Toggle(t("form.reimbursable"), isOn: $draft.payment.reimbursable)
          if draft.payment.reimbursable {
            Picker(t("form.debtor"), selection: $draft.payment.debtorPersonId) {
              Text(verbatim: "—").tag(UUID?.none)
              ForEach(choices.people) { Text(verbatim: $0.name).tag(Optional($0.id)) }
            }
            LabeledContent(t("form.returns")) {
              AmountField(
                amount: Binding(
                  get: { draft.payment.reimbursementAmountE4 ?? draft.payment.amountE4 },
                  set: { draft.payment.reimbursementAmountE4 = $0 }),
                locale: environment.language.locale)
            }
          }
        }
        if draft.payment.kind == .subscription {
          Section {
            Toggle(
              t("form.hasTrial"),
              isOn: Binding(
                get: { draft.hasTrial }, set: { draft.setHasTrial($0, today: environment.today) }))
            if draft.hasTrial {
              DatePicker(
                t("form.trialEnd"),
                selection: day($draft.payment.trialEnd, fallback: environment.today),
                displayedComponents: .date)
            }
            TextField(
              t("form.cancelURL"),
              text: Binding(
                get: { draft.payment.cancelURL ?? "" },
                set: { draft.payment.cancelURL = $0.isEmpty ? nil : $0 }))
          }
        }
        Stepper(
          value: Binding(
            get: { draft.payment.remindDaysBefore ?? 3 },
            set: { draft.payment.remindDaysBefore = $0 }),
          in: 0...30
        ) {
          Text(
            verbatim: environment.language.format(
              "form.remind", table: "Planning", draft.payment.remindDaysBefore ?? 3))
        }
        if let issue = issue(choices) {
          Text(verbatim: t(issue.key)).font(.caption).foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      FormButtons(title: environment.language("action.save"), enabled: issue(choices) == nil) {
        guard let dependencies else { return false }
        return PlanningActions(dependencies).save(
          draft.saved(original: original, today: environment.today), previous: original)
      }
    }
    .padding(20)
    .frame(width: 520, height: 640)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      var opened =
        start ?? ScheduledPayment(name: "", amountE4: .zero, nextDate: environment.today)
      if opened.remindDaysBefore == nil { opened.remindDaysBefore = 3 }
      draft = ScheduledPaymentDraft(opening: opened)
    }
  }

  private var presetBinding: Binding<FrequencyPreset> {
    Binding(get: { draft.preset }, set: { draft.choose($0, today: environment.today) })
  }

  private var unitBinding: Binding<Frequency> {
    Binding(get: { draft.payment.freq }, set: { draft.setUnit($0, today: environment.today) })
  }

  private var lastDayBinding: Binding<Bool> {
    Binding(get: { draft.lastDay }, set: { draft.setLastDay($0, today: environment.today) })
  }

  private var nextDateBinding: Binding<Date> {
    Binding(
      get: { environment.calendar.startOfDay(draft.payment.nextDate ?? environment.today) },
      set: { draft.setNextDate(environment.calendar.day(of: $0), today: environment.today) })
  }

  private func issue(_ choices: PlanningChoices) -> ScheduledIssue? {
    guard let tree = choices.tree else { return nil }
    return draft.issue(original: original, tree: tree, today: environment.today)
  }

  private func day(_ value: Binding<DateOnly?>, fallback: DateOnly) -> Binding<Date> {
    Binding(
      get: { environment.calendar.startOfDay(value.wrappedValue ?? fallback) },
      set: { value.wrappedValue = environment.calendar.day(of: $0) })
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

// MARK: - Mark as paid

struct MarkAsPaidForm: View {
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
