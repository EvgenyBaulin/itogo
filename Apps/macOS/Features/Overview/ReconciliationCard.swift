import AppCore
import SwiftUI

/// The last reconciliation: its day, how long ago, the differences it found as it found them —
/// each in its balance's own currency, never counted again at today's rates — and «Сверить…»,
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
              counts: max(0, last.date.days(to: snapshot.today)))
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          if let found = Self.found(
            by: last, balances: snapshot.dataset.planning.reconciledBalances,
            accounts: snapshot.dataset.paymentMethods, environment)
          {
            Text(verbatim: found)
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
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

  /// What the card says the reconciliation found, as it found it: «разница −1,200 ₽» of a
  /// reconciliation of one total; the differences of the balances of one of the accounts, each
  /// in its currency and to the whole unit — or «без расхождений», «точка отсчёта»; nil when
  /// there is nothing to say.
  static func found(
    by reconciliation: Reconciliation, balances: [ReconciledBalance],
    accounts: [PaymentMethod], _ environment: AppEnvironment
  ) -> String? {
    func difference(_ text: String) -> String {
      environment.format("overview.reconciliationDifference", table: "Planning", text)
    }
    guard reconciliation.kind != .total else {
      return reconciliation.differenceE4.map { difference(environment.money.signedRounded($0)) }
    }
    let balances = balances.filter { $0.reconciliationId == reconciliation.id }
    guard !balances.isEmpty else { return nil }
    let names = Dictionary(
      accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    // The Overview shows amounts to the ruble; the sheet's history keeps the kopecks.
    let text = ReconcileSheet.differencesText(
      balances, names: { names[$0] ?? "—" }, money: environment.money,
      language: environment.language, rounded: true)
    guard case .differences = ReconcileSheet.findings(balances) else { return text }
    return difference(text)
  }
}
