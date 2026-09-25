import AppCore
import SwiftUI

// MARK: - Free to spend

/// How much is free until a day of this month, the terms it is made of, and the daily guide
/// («свободная сумма до даты с расшифровкой и дневным ориентиром»).
struct FreeToSpendBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @State private var until: Date?
  /// A write the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false

  var body: some View {
    ComputedBlock(
      title: t("free.title"), state: compute.states.data,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let planning = snapshot.planning
      let day = chosenDay(snapshot)
      let free = planning.freeToSpend(
        until: day, reserve: planning.book.settings.reserveGoalPlan, ledger: snapshot.ledger)
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(verbatim: environment.money.rounded(free.free))
            .font(.title2.monospacedDigit())
          if free.free.isNegative {
            Label {
              Text(verbatim: t("free.overspent"))
            } icon: {
              Image(systemName: "exclamationmark.triangle")
            }
            .font(.caption)
          } else {
            Text(
              verbatim: environment.language.format(
                "free.daily", table: "Planning", environment.money.rounded(free.dailyGuide),
                free.days)
            )
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          DatePicker(
            selection: Binding(
              get: { until ?? environment.calendar.startOfDay(day) },
              set: { until = $0 }),
            in: environment.calendar.startOfDay(
              snapshot.today)...environment.calendar.startOfDay(
                snapshot.today.monthKey.lastDay),
            displayedComponents: .date
          ) {
            Text(verbatim: t("free.until"))
          }
          .fixedSize()
        }
        FormulaLines(
          lines: free.lines.map { (key: $0.key, plus: $0.sign == .plus, amount: $0.amount) })
        Toggle(
          isOn: Binding(
            get: { planning.book.settings.reserveGoalPlan },
            set: { reserve in
              // A setting, not an action; the observation of the database recounts the block.
              if !environment.attempt(
                "settings.planning", on: environment.settings,
                { try $0.set(PlanningSettings.reserveGoalPlanKey, to: reserve ? "1" : "0") })
              {
                refused = true
              }
            })
        ) {
          Text(verbatim: environment.language("settings.planning.reserve", table: "Settings"))
        }
        .toggleStyle(.checkbox)
        .font(.caption)
        if free.free.isNegative, planning.income.source != .expectations {
          // Without expected income the block knows only money already received: a salary
          // due at the end of the month is not here until it is expected.
          Text(verbatim: t("free.noExpectations"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(free.info, id: \.key) { line in
          Text(
            verbatim: "\(t(line.key)) \(environment.money.rounded(line.amount))"
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
        }
      }
    }
    .refusedWriteAlert($refused, environment)
  }

  private func chosenDay(_ snapshot: DataSnapshot) -> DateOnly {
    let end = snapshot.today.monthKey.lastDay
    guard let until else { return end }
    let day = environment.calendar.day(of: until)
    return min(max(day, snapshot.today), end)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
