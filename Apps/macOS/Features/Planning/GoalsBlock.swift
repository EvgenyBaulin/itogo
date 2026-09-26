import AppCore
import AppDatabase
import SwiftUI

// The blocks of the Planning section below the payments. Content, never glass; states in
// words and symbols, never colour alone.

/// Goals: progress, what is needed a month and whether it is realistic; «Contribute» and
/// «Withdraw». A goal put in the archive is listed when asked, with «Вернуть».
struct GoalsBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Binding var sheet: PlanningSheet?
  @State private var showsArchive = false

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
            // In the goal's own currency: a dollar goal is saved in dollars.
            Text(
              verbatim: String(
                format: t("planning.spentOf"), locale: environment.language.locale,
                environment.money.rounded(status.saved, currency: status.currency),
                environment.money.rounded(status.goal.targetE4, currency: status.currency))
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if status.withoutRate > 0 {
              Label {
                Text(
                  verbatim: environment.format(
                    "goals.withoutRate", table: "Planning", counts: status.withoutRate))
              } icon: {
                Image(systemName: "hourglass")
              }
              .font(.caption)
              .foregroundStyle(.secondary)
            }
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
        archive(snapshot.dataset.goals.filter(\.archived))
      }
    }
  }

  /// The goals in the archive, behind «Показывать архив» while there are any. «Вернуть» brings
  /// one back as it was — one step of ⌘Z, as its archiving was.
  @ViewBuilder
  private func archive(_ archived: [Goal]) -> some View {
    if !archived.isEmpty {
      Toggle(isOn: $showsArchive) {
        Text(
          verbatim: environment.format(
            "goals.showArchive", table: "Settings", counts: archived.count))
      }
      .toggleStyle(.checkbox)
      .controlSize(.small)
      if showsArchive {
        ForEach(archived) { goal in
          HStack(spacing: 6) {
            Image(systemName: "archivebox")
              .foregroundStyle(.secondary)
              .accessibilityLabel(Text(verbatim: s("goals.inArchive")))
            Text(verbatim: goal.name)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Spacer(minLength: 6)
            Button(s("goals.restore")) { restore(goal) }
              .buttonStyle(.bordered)
              .controlSize(.small)
          }
        }
      }
    }
  }

  private func restore(_ goal: Goal) {
    guard let dependencies else { return }
    Self.restore(goal.id, with: PlanningActions(dependencies), references: environment.references)
  }

  /// «Вернуть» of the goal `id`: read again from the database — the snapshot the block shows
  /// may be older than a change made since — and written back live, one step of ⌘Z. False when
  /// there is no such goal any more or the write was refused.
  @discardableResult
  static func restore(
    _ id: UUID, with actions: PlanningActions, references: ReferenceRepository?
  ) -> Bool {
    guard
      var goal = (try? references?.goals(includeArchived: true))?.first(where: { $0.id == id })
    else { return false }
    guard goal.archived else { return true }
    goal.archived = false
    return actions.save(goal)
  }

  /// «Нужно 18 300 ₽ в месяц · успеваете по плану», «при плане — к марту 2027».
  private func realism(_ status: GoalStatus) -> String {
    var pieces: [String] = []
    if let needed = status.neededMonthly {
      pieces.append(
        environment.format(
          "goals.needed", table: "Planning",
          environment.money.rounded(needed, currency: status.currency)))
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
  /// The words of the archive, shared with Settings.
  private func s(_ key: String) -> String { environment.language(key, table: "Settings") }
}
