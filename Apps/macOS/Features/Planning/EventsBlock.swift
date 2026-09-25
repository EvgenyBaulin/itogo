import AppCore
import SwiftUI

// The blocks of the Planning section below the payments. Content, never glass; states in
// words and symbols, never colour alone.

/// Events with budgets: spent, left, by category; the upcoming ones with what they cost
/// last time and how much to put aside a month.
struct EventsBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: t("events.title"), state: compute.states.data,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let events = snapshot.planning.events
      let shown = unique(events.active + events.withBudget + events.upcoming)
      VStack(alignment: .leading, spacing: 10) {
        if shown.isEmpty {
          Text(verbatim: t("events.none")).foregroundStyle(.secondary)
        }
        ForEach(shown, id: \.event.id) { plan in
          VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
              Text(verbatim: plan.event.name)
              Text(verbatim: PlanningText.eventWhen(plan, environment))
                .font(.caption).foregroundStyle(.secondary)
              Spacer(minLength: 6)
              if let budget = plan.budget {
                Text(
                  verbatim: String(
                    format: t("planning.spentOf"), locale: environment.language.locale,
                    environment.money.rounded(plan.spent), environment.money.rounded(budget))
                )
                .monospacedDigit()
              }
            }
            if plan.overBudget || plan.pacing {
              Label {
                Text(verbatim: t(plan.overBudget ? "events.over" : "events.pacing"))
              } icon: {
                Image(systemName: "exclamationmark.triangle")
              }
              .font(.caption)
            }
            if !plan.byCategory.isEmpty {
              Text(
                verbatim: plan.byCategory.prefix(4).map {
                  "\(PlanningText.categoryPath($0.categoryId, tree: snapshot.ledger.tree) ?? "—") \(environment.money.rounded($0.amount))"
                }.joined(separator: " · ")
              )
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            }
            if !plan.isActive, let last = plan.lastTimeTotal {
              Text(
                verbatim: environment.format(
                  "events.lastTime", table: "Planning", environment.money.rounded(last))
                  + (plan.monthlySaving.map {
                    " · "
                      + environment.format(
                        "events.monthly", table: "Planning", environment.money.rounded($0))
                  } ?? "")
              )
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }

  private func unique(_ plans: [EventPlan]) -> [EventPlan] {
    var seen: Set<UUID> = []
    return plans.filter { seen.insert($0.event.id).inserted }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
