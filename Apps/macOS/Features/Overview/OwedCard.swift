import AppCore
import SwiftUI

/// Parts I paid for somebody else that have not come back. When nobody owes anything the
/// card stays and says so — the grid does not rearrange itself — and offers no button, as
/// there is nothing to close.
struct OwedCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let actions: OperationActions

  var body: some View {
    ComputedBlock(
      title: environment.language("owed.title", table: "Entry"), state: compute.states.owed,
      fillsHeight: true, retry: { compute.retry(ComputeStep.owed) }
    ) { owed in
      if owed.count > 0 {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: environment.money.rounded(owed.amount))
              .font(.title2.monospacedDigit())
            Text(
              verbatim: environment.language.format(
                "owed.count", table: "Entry", owed.count)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          // Content, not a floating control: a plain small button, never glass.
          Button(environment.language("reimbursement.title", table: "Entry")) {
            actions.recordingReimbursement = true
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      } else {
        Text(verbatim: environment.language("overview.owedNobody", table: "Overview"))
          .foregroundStyle(.secondary)
      }
    }
  }
}
