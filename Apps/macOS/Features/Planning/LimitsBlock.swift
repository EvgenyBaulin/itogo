import AppCore
import SwiftUI

// The blocks of the Planning section below the payments. Content, never glass; states in
// words and symbols, never colour alone.

/// The limits of the month: a symbol and a word for the status, «spent / available», a thin
/// bar, the pace and the forecast; what is carried over from earlier months.
struct LimitsBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Binding var sheet: PlanningSheet?
  /// A limit asked to be deleted: the confirmation comes first.
  @State private var deleting: Budget?

  var body: some View {
    ComputedBlock(
      title: t("limits.title"), state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      VStack(alignment: .leading, spacing: 10) {
        let lines = snapshot.planning.limits
        if lines.isEmpty {
          Text(verbatim: t("limits.none")).foregroundStyle(.secondary)
        }
        ForEach(lines, id: \.budget.id) { line in
          VStack(alignment: .leading, spacing: 3) {
            LimitStatusLine(line: line, tree: snapshot.ledger.tree)
            LimitBar(line: line)
            Text(verbatim: detail(line))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .contextMenu {
            Button(environment.language("action.edit")) { sheet = .budget(line.budget) }
            Button(environment.language("action.delete")) { deleting = line.budget }
          }
        }
        Button(t("limits.add")) { sheet = .budget(nil) }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
    }
    .confirmationDialog(
      t("limits.deleteTitle"),
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible, presenting: deleting
    ) { budget in
      Button(environment.language("action.delete"), role: .destructive) {
        if let dependencies { PlanningActions(dependencies).delete(budget) }
      }
    }
  }

  private func detail(_ line: LimitLine) -> String {
    var pieces: [String] = []
    if let pace = line.paceBp {
      pieces.append(
        environment.format(
          "limits.pace", table: "Planning",
          environment.money.percent(basisPoints: pace, fractionDigits: 0)))
    }
    pieces.append(
      environment.format(
        "limits.forecast", table: "Planning", environment.money.rounded(line.forecast)))
    if !line.carry.isZero {
      pieces.append(
        environment.format(
          "limits.carry", table: "Planning", environment.money.rounded(line.carry)))
    }
    return pieces.joined(separator: " · ")
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// Spent against available: the part within the limit in the accent colour, what went over
/// it past the mark in the colour of the status — the status itself is said in words.
private struct LimitBar: View {
  let line: LimitLine

  var body: some View {
    let available = max(line.available.raw, 1)
    let within = min(max(line.spent.raw, 0), available)
    let over = max(line.spent.raw - available, 0)
    let whole = available + over
    Capsule()
      .fill(.quaternary)
      .overlay {
        ProportionalRow(weights: [
          Int(within * 1000 / whole), Int(over * 1000 / whole),
          Int((whole - within - over) * 1000 / whole),
        ]) {
          Capsule().fill(.tint)
          Capsule().fill(PlanningText.statusTint(line.status))
          Color.clear
        }
      }
      .frame(height: 4)
      .accessibilityHidden(true)
  }
}
