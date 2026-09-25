import AppCore
import SwiftUI

/// Templates are the chips under the entry line: what I enter often, and what I pinned
/// myself. They fill themselves from real usage, so this screen is mostly about pinning,
/// renaming and throwing away what turned out to be noise.
struct TemplatesSettingsView: View {
  @Dependency(\.environment) private var environment
  @State private var templates: [Template] = []
  /// A write the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      List {
        ForEach($templates, id: \.id) { $template in
          HStack(spacing: 10) {
            Button {
              template.pinned.toggle()
              save(template)
            } label: {
              Image(systemName: template.pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(environment.language("templates.pin", table: "Settings"))

            TextField(text: $template.text) { EmptyView() }
              .labelsHidden()
              .textFieldStyle(.plain)
              .onSubmit { save(template) }

            if let amount = template.amountE4 {
              Text(verbatim: environment.money.exact(amount, currency: template.currency ?? .rub))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            Text(
              verbatim: environment.format(
                "templates.used", table: "Settings", counts: template.useCount)
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Button(environment.language("action.delete", table: "Common")) {
              delete(template)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
          }
        }
      }
      .frame(minHeight: 240)

      Text(verbatim: environment.language("templates.hint", table: "Settings"))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding()
    .onAppear(perform: reload)
    .refusedWriteAlert($refused, environment)
  }

  private func reload() {
    templates = (try? environment.references?.templates()) ?? []
  }

  /// A refused save keeps the row as the owner left it.
  private func save(_ template: Template) {
    guard
      environment.attempt("templates.save", on: environment.references, { try $0.save(template) })
    else {
      refused = true
      return
    }
    reload()
    environment.scheduleBackup()
  }

  /// A template is not data about money: throwing one away loses nothing but the chip.
  private func delete(_ template: Template) {
    guard
      environment.attempt(
        "templates.delete", on: environment.references, { try $0.deleteTemplate(id: template.id) })
    else {
      refused = true
      return
    }
    reload()
    environment.scheduleBackup()
  }
}
