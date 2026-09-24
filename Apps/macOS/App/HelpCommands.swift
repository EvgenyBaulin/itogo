import AppCore
import AppKit
import SwiftUI

/// The Help menu: one item, and it is the one that matters when something has broken —
/// «Собрать отчёт о проблеме…».
///
/// It opens the report itself, gathered, on a sheet over the settings: the list of what goes
/// into the file is shown before the file is written. It used to open the settings alone — on
/// whatever tab they were left, with the report at the bottom of the General one, below the
/// fold.
struct HelpCommands: Commands {
  /// The same public action the gear of the toolbar uses. It replaced
  /// `NSApp.sendAction(Selector(("showSettingsWindow:")))` — a private selector Apple renamed
  /// once already, between macOS 13 and 14.
  @Environment(\.openSettings) private var openSettings
  let environment: AppEnvironment

  var body: some Commands {
    CommandGroup(replacing: .help) {
      Button(environment.language("report.title", table: "Settings")) {
        Self.collectReport(environment) { openSettings() }
      }
      Button(environment.language("report.showJournal", table: "Settings")) {
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.logsDirectory])
      }
    }
  }

  /// What «Собрать отчёт о проблеме…» does: the settings open with the report over them.
  @MainActor
  static func collectReport(_ environment: AppEnvironment, openSettings: () -> Void) {
    environment.showsProblemReport = true
    openSettings()
  }
}
