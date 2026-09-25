import AppCore
import SwiftUI

// The forms of the Planning section, one sheet at a time on the root of the section. A form
// is content: system `Form`, no glass of its own. «Save» writes one `PlanningChange` — one
// step of ⌘Z — and closes the sheet only over a write that landed.

// MARK: - A goal

struct GoalForm: View {
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

struct GoalMoveForm: View {
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
