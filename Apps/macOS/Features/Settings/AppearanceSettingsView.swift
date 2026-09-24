import SwiftUI

/// Settings → Appearance: light, dark or the system's, and the one accent colour of the app.
///
/// No restart hint here, unlike the language next door: both halves of the theme apply at
/// once — `NSApp.appearance` for the alerts and the panels, the SwiftUI environment for
/// everything else.
struct AppearanceSettingsView: View {
  @Dependency(\.environment) private var environment

  var body: some View {
    @Bindable var theme = environment.theme
    Form {
      Section {
        Picker(selection: $theme.scheme) {
          ForEach(AppTheme.Scheme.allCases, id: \.self) { scheme in
            Text(verbatim: environment.language(scheme.settingsKey, table: "Settings"))
              .tag(scheme)
          }
        } label: {
          Text(verbatim: environment.language("settings.appearance.scheme", table: "Settings"))
        }
        .pickerStyle(.inline)
      } footer: {
        Text(verbatim: environment.language("settings.appearance.hint", table: "Settings"))
          .foregroundStyle(.secondary)
      }

      Section {
        Picker(selection: $theme.accent) {
          ForEach(AppTheme.Accent.allCases, id: \.self) { accent in
            // The swatch never speaks alone: the name of the colour stands beside it, which
            // is what keeps the row readable with a colour filter and with «Увеличить
            // контраст».
            Label {
              Text(verbatim: environment.language(accent.settingsKey, table: "Settings"))
            } icon: {
              Image(systemName: "circle.fill")
                .foregroundStyle(accent.color)
            }
            .labelStyle(.titleAndIcon)
            .tag(accent)
          }
        } label: {
          Text(verbatim: environment.language("settings.appearance.accent", table: "Settings"))
        }
        // The pop-up rather than a list of nine rows: the window of the settings is 420 pt
        // tall and the theme above already takes three. The closed button shows the chosen
        // colour with its name, so nothing is told by the swatch alone either way.
      } footer: {
        Text(verbatim: environment.language("settings.appearance.accentHint", table: "Settings"))
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
    .accessibilityIdentifier("settings.appearance")
  }
}
