import AppCore
import SwiftUI

// The forms of the Planning section, one sheet at a time on the root of the section. A form
// is content: system `Form`, no glass of its own. «Save» writes one `PlanningChange` — one
// step of ⌘Z — and closes the sheet only over a write that landed.

// MARK: - A limit

struct BudgetForm: View {
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
        Toggle(isOn: $budget.rollover) {
          Text(verbatim: t("form.limit.rollover"))
          // The carry is counted with the amount the limit has now: a new amount, or the carry
          // switched on, starts it again this month (`LimitRules.saving`).
          Text(verbatim: t("form.limit.rolloverHint"))
        }
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
    .frame(width: 460, height: 390)
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
