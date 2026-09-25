import AppCore
import SwiftUI

// The blocks of the Planning section below the payments. Content, never glass; states in
// words and symbols, never colour alone.

/// Goals: progress, what is needed a month and whether it is realistic; «Contribute» and
/// «Withdraw».
struct GoalsBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Binding var sheet: PlanningSheet?

  var body: some View {
    ComputedBlock(
      title: t("goals.title"), state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      VStack(alignment: .leading, spacing: 12) {
        let goals = snapshot.planning.goals
        if goals.isEmpty {
          Text(verbatim: t("goals.none")).foregroundStyle(.secondary)
        }
        ForEach(goals) { status in
          VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
              Text(verbatim: status.goal.name).lineLimit(1)
              Spacer(minLength: 6)
              Text(
                verbatim: environment.money.percent(
                  basisPoints: status.progressBp, fractionDigits: 0)
              )
              .monospacedDigit()
              .foregroundStyle(.secondary)
            }
            Capsule()
              .fill(.quaternary)
              .overlay {
                ProportionalRow(
                  weights: [
                    min(status.progressBp, Shares.whole),
                    Shares.whole - min(status.progressBp, Shares.whole),
                  ]
                ) {
                  Capsule().fill(.tint)
                  Color.clear
                }
              }
              .frame(height: 4)
              .accessibilityHidden(true)
            Text(
              verbatim: String(
                format: t("planning.spentOf"), locale: environment.language.locale,
                environment.money.rounded(status.saved),
                environment.money.rounded(status.goal.targetE4))
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Text(verbatim: realism(status))
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
              Button(t("goals.contribute")) { sheet = .moveGoal(status, withdraw: false) }
                .buttonStyle(.bordered)
              Button(t("goals.withdraw")) { sheet = .moveGoal(status, withdraw: true) }
                .buttonStyle(.bordered)
                .disabled(status.saved.raw <= 0)
            }
            .controlSize(.small)
          }
          .contextMenu {
            Button(environment.language("action.edit")) { sheet = .goal(status.goal) }
            Button(t("goals.archive")) {
              if let dependencies { PlanningActions(dependencies).archive(status.goal) }
            }
          }
        }
        Button(t("goals.add")) { sheet = .goal(nil) }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
    }
  }

  /// «Нужно 18 300 ₽ в месяц · успеваете по плану», «при плане — к марту 2027».
  private func realism(_ status: GoalStatus) -> String {
    var pieces: [String] = []
    if let needed = status.neededMonthly {
      pieces.append(
        environment.format("goals.needed", table: "Planning", environment.money.rounded(needed)))
    }
    pieces.append(t("goals.realism.\(status.realism.rawValue)"))
    if status.realism == .behindPlan || status.realism == .noDate,
      let month = status.projectedCompletion
    {
      pieces.append(
        environment.format(
          "goals.projected", table: "Planning", environment.dates.monthTitle(month)))
    }
    return pieces.joined(separator: " · ")
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
