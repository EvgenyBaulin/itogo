import AppCore
import SwiftUI

/// The limits of the month: the ones over and the ones close to it first, each with its
/// symbol and word, then how many are within.
struct LimitsCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: t("overview.limits"), state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let lines = snapshot.planning.limits
      if lines.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text(verbatim: t("overview.limitsNone"))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button(t("overview.limitsOpen")) {
            NotificationCenter.default.post(name: .selectSection, object: 2)
          }
          .buttonStyle(.link)
        }
      } else {
        let attention = lines.filter { $0.status != .ok }
          .sorted { ($0.paceBp ?? 0) > ($1.paceBp ?? 0) }
        VStack(alignment: .leading, spacing: 6) {
          ForEach(attention.prefix(4), id: \.budget.id) { line in
            LimitStatusLine(line: line, tree: snapshot.ledger.tree)
          }
          let within = lines.count - attention.count
          if within > 0 {
            Label {
              Text(
                verbatim: environment.language.format(
                  "overview.limitsWithin", table: "Planning", within))
            } icon: {
              Image(systemName: PlanningText.statusSymbol(.ok))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// One limit: its status as a symbol and a word — never colour alone — its name and
/// «spent / available».
struct LimitStatusLine: View {
  @Dependency(\.environment) private var environment
  let line: LimitLine
  let tree: CategoryTree

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: PlanningText.statusSymbol(line.status))
        .foregroundStyle(PlanningText.statusTint(line.status))
        .accessibilityHidden(true)
      // The status in words too, never by colour and symbol alone.
      Text(
        verbatim: "\(PlanningText.statusWord(line.status, environment)): "
          + PlanningText.limitName(line.budget, tree: tree, environment)
      )
      .lineLimit(1)
      Spacer(minLength: 6)
      Text(
        verbatim:
          "\(environment.money.rounded(line.spent)) / \(environment.money.rounded(line.available))"
      )
      .monospacedDigit()
    }
    .font(.callout)
    .accessibilityElement(children: .combine)
  }
}
