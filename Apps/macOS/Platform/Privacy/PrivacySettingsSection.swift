import SwiftUI

/// Settings → «Основные» → «Конфиденциальность»: hiding the amounts, and the lock with its idle
/// time. Both are switches of this Mac (`AmountPrivacy`, `PrivacyLock`), never data of the books.
struct PrivacySettingsSection: View {
  @Dependency(\.environment) private var environment
  /// The lock the section shows: the app's own, unless a test hands one that answers as it says.
  var lockShown: PrivacyLock?

  var body: some View {
    @Bindable var amounts = environment.amounts
    @Bindable var lock = lockShown ?? environment.lock
    Section {
      Toggle(isOn: $amounts.hidesAmounts) {
        Text(verbatim: environment.language("settings.privacy.hideAmounts", table: "Settings"))
      }
      .accessibilityIdentifier("settings.privacy.hideAmounts")

      Toggle(
        isOn: Binding(
          get: { lock.isEnabled },
          set: { on in
            if on {
              let reason = environment.language("privacy.enable.reason")
              Task { await lock.enable(reason: reason) }
            } else {
              lock.disable()
            }
          })
      ) {
        Text(verbatim: environment.language("settings.privacy.lock", table: "Settings"))
      }
      .disabled(!lock.applies || lock.isAuthenticating)
      .accessibilityIdentifier("settings.privacy.lock")

      Picker(selection: $lock.idleMinutes) {
        ForEach(PrivacyLock.idleChoices, id: \.self) { minutes in
          Text(
            verbatim: environment.language("settings.privacy.idle.\(minutes)", table: "Settings")
          )
          .tag(minutes)
        }
      } label: {
        Text(verbatim: environment.language("settings.privacy.idle", table: "Settings"))
      }
      .disabled(!lock.isEnabled)

      if !lock.isEnabled, let refusal = lock.lastRefusal,
        let key = Self.refusalKey(refusal)
      {
        Label {
          Text(verbatim: environment.language(key, table: "Settings"))
        } icon: {
          Image(systemName: "exclamationmark.octagon")
        }
        .foregroundStyle(.red)
      }
    } header: {
      Text(verbatim: environment.language("settings.privacy", table: "Settings"))
    } footer: {
      Text(
        verbatim: environment.language(
          lock.applies ? "settings.privacy.hint" : "settings.privacy.notInDataSet",
          table: "Settings")
      )
      .foregroundStyle(.secondary)
    }
  }

  /// Why the lock stayed off; nothing after a cancel.
  static func refusalKey(_ refusal: LockAuthentication) -> String? {
    switch refusal {
    case .failed: "settings.privacy.lockRefused"
    case .unavailable: "settings.privacy.lockUnavailable"
    case .cancelled, .passed: nil
    }
  }
}
