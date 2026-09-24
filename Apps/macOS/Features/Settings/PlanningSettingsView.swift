import AppCore
import AppDatabase
import SwiftUI

/// Settings of planning and reconciliation («Сверка: напоминание раз в N
/// дней (по умолчанию 14)», «Сбережения: целевая доля (по умолчанию 10%)»). The values live in
/// the `settings` table under `PlanningSettings` keys, so they travel with the archive and the
/// pipeline reads them with the rest of the data: a change here reaches the numbers through
/// the observation of the database, like any other write.
struct PlanningSettingsView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @State private var values = PlanningSettings()
  /// One setting for all seven anomaly rules. It lives beside the cashback category, under an
  /// `AnalyticsSettings` key, because the rules read it with the rest of the data.
  @State private var sensitivity = AnomalySensitivity.standard
  /// A write the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false

  var body: some View {
    Form {
      Section {
        Stepper(
          value: Binding(
            get: { values.reconcileEveryDays }, set: { save(\.reconcileEveryDays, $0) }),
          in: 1...90
        ) {
          Text(
            verbatim: environment.format(
              "settings.planning.reconcileEvery", table: "Settings", values.reconcileEveryDays))
        }
        Toggle(
          isOn: Binding(
            get: { values.reconcileIncludesGoalSavings },
            set: { save(\.reconcileIncludesGoalSavings, $0) })
        ) {
          Text(verbatim: t("settings.planning.includesGoals"))
        }
      } header: {
        Text(verbatim: t("settings.planning.reconciliation"))
      } footer: {
        Text(verbatim: t("settings.planning.includesGoalsHint"))
          .foregroundStyle(.secondary)
      }

      Section {
        Stepper(
          value: Binding(
            get: { values.savingsTargetBp / 100 }, set: { save(\.savingsTargetBp, $0 * 100) }),
          in: 0...90
        ) {
          Text(
            verbatim: environment.format(
              "settings.planning.savingsTarget", table: "Settings", values.savingsTargetBp / 100))
        }
        Toggle(
          isOn: Binding(get: { values.reserveGoalPlan }, set: { save(\.reserveGoalPlan, $0) })
        ) {
          Text(verbatim: t("settings.planning.reserve"))
        }
      } header: {
        Text(verbatim: t("settings.planning.savings"))
      } footer: {
        Text(verbatim: t("settings.planning.reserveHint"))
          .foregroundStyle(.secondary)
      }

      Section {
        Picker(
          selection: Binding(get: { sensitivity }, set: { save(sensitivity: $0) })
        ) {
          ForEach(AnomalySensitivity.allCases, id: \.self) { level in
            Text(verbatim: t("settings.anomalies.\(level.rawValue)")).tag(level)
          }
        } label: {
          Text(verbatim: t("settings.anomalies.sensitivity"))
        }
        .pickerStyle(.segmented)
      } header: {
        Text(verbatim: t("settings.anomalies"))
      } footer: {
        Text(verbatim: t("settings.anomalies.hint"))
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
    .task { load() }
    .refusedWriteAlert($refused, environment)
    // The reserve switch also lives on the Planning screen: after any write, read again, so
    // this tab never shows (or writes back) a value older than the database.
    .onChange(of: compute.generation) { load() }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  private func load() {
    guard let settings = environment.settings else { return }
    var stored: [String: String] = [:]
    for key in PlanningSettings.storageKeys {
      if let value = try? settings.string(key) { stored[key] = value }
    }
    // The storage layer's own reading: one format for the app, the pipeline and the archive.
    values = PlanningSettings(storedValues: stored)
    sensitivity =
      ((try? settings.string(AnalyticsSettings.anomalySensitivityKey)) ?? nil)
      .flatMap(AnomalySensitivity.init(rawValue:)) ?? .standard
  }

  /// A refused setting is read back, so the control shows what the database still has.
  private func save(sensitivity level: AnomalySensitivity) {
    sensitivity = level
    guard
      environment.attempt(
        "settings.planning", on: environment.settings,
        { try $0.set(AnalyticsSettings.anomalySensitivityKey, to: level.rawValue) })
    else {
      refused = true
      load()
      return
    }
  }

  private func save<Value>(_ keyPath: WritableKeyPath<PlanningSettings, Value>, _ value: Value) {
    let before = values.storedValues
    values[keyPath: keyPath] = value
    // A setting, not an action: no step of ⌘Z. The observation of the database carries it to
    // the numbers. Only the key that changed is written: the others may have been changed
    // elsewhere since this tab read them (the reserve switch, the dismissed reminders).
    let stored = values.storedValues
    let written = environment.attempt("settings.planning", on: environment.settings) { settings in
      for key in Self.changedKeys(before: before, after: stored) {
        if let text = stored[key] ?? nil { try settings.set(key, to: text) }
      }
    }
    if !written {
      refused = true
      load()
    }
  }

  /// The storage keys whose text differs between two readings.
  static func changedKeys(before: [String: String?], after: [String: String?]) -> [String] {
    after.keys.filter { before[$0] != after[$0] }.sorted()
  }
}
