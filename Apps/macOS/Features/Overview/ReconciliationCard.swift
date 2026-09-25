import AppCore
import SwiftUI

/// The last reconciliation: its day, how long ago, the difference it found, and «Сверить…»,
/// which opens the reconciliation sheet of the main window.
struct ReconciliationCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: environment.language("overview.reconciliation", table: "Overview"),
      state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      VStack(alignment: .leading, spacing: 6) {
        if let last = snapshot.planning.lastReconciliation {
          Text(verbatim: environment.dates.longDay(last.date))
            .font(.title3)
          Text(
            verbatim: environment.language.format(
              "overview.reconciliationAgo", table: "Planning",
              max(0, last.date.days(to: snapshot.today)))
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          if let difference = last.differenceE4 {
            Text(
              verbatim: environment.format(
                "overview.reconciliationDifference", table: "Planning",
                environment.money.signedRounded(difference))
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
          }
        } else {
          Text(verbatim: environment.language("overview.reconciliationNone", table: "Overview"))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        // Content, not a floating control: a plain small button, never glass.
        Button(environment.language("reconcile.open", table: "Planning")) {
          environment.showsReconciliation = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
  }
}
