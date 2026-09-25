import AppCore
import AppKit
import SwiftUI

/// «Справка» → «Собрать отчёт о проблеме…» and the button in the settings.
///
/// The list of what goes into the file is shown before the file is written, because the whole
/// point of the file is that it can be handed to somebody else.
struct ProblemReportView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @State private var report: ProblemReport?
  @State private var crashReport: URL?
  @State private var failure: String?
  @State private var hasGathered = false
  /// Gathers as soon as it is shown, once: the report the offer after a crash opens
  /// (`ProblemReportSheet`). In the settings the owner presses the button.
  var gathersAtOnce = false

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  var body: some View {
    Section {
      if environment.lastSessionWasInterrupted {
        Label {
          Text(verbatim: t("report.interrupted"))
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.secondary)
      }

      if let report {
        contents(of: report.contents)
        HStack {
          Button(t("report.attachCrash")) { attachCrashReport() }
          Spacer()
          Button(t("report.save")) { save(report) }
            .buttonStyle(.borderedProminent)
        }
      } else {
        HStack {
          Button(t("report.title")) { gather() }
          Spacer()
          Button(t("report.showJournal")) { showJournal() }
        }
        .task {
          guard gathersAtOnce, !hasGathered else { return }
          gather()
        }
      }

      if let failure {
        Text(verbatim: failure).foregroundStyle(.secondary)
      }
    } header: {
      Text(verbatim: t("report.section"))
    } footer: {
      Text(verbatim: t("report.hint")).foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func contents(of contents: ProblemReport.Contents) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(verbatim: t("report.contents")).font(.headline)
      if contents.journalUnavailable {
        Text(verbatim: t("report.contents.journal.unavailable"))
      } else {
        Text(
          verbatim: environment.language.format(
            "report.contents.journal", table: "Settings",
            counts: contents.journalFiles, contents.journalDays))
      }
      Text(
        verbatim: environment.language.format(
          "report.contents.database", table: "Settings", counts: contents.tables, contents.rows))
      Text(
        verbatim: environment.language.format(
          "report.contents.settings", table: "Settings", counts: contents.settings))
      Text(verbatim: t(contents.integrityKey))
      if contents.crashReport { Text(verbatim: t("report.contents.crash")) }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
  }

  private func gather() {
    hasGathered = true
    Task { @MainActor in
      report = await ProblemReportService.gather(
        environment: environment, compute: compute, crashReport: crashReport)
    }
  }

  /// The application never reads the system logs itself: the owner picks the file, and the
  /// panel opens where those files are.
  private func attachCrashReport() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    panel.message = t("report.crashHint")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    crashReport = url
    gather()
  }

  private func save(_ report: ProblemReport) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Itogo-report-\(environment.today.iso).zip"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    failure = ProblemReportService.save(report, to: url, language: environment.language)
    if failure == nil { self.report = nil }
  }

  private func showJournal() {
    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.logsDirectory])
  }
}

/// The report on a sheet of its own, gathered as it opens: where «Собрать отчёт…» of the
/// offer after a crash leads (`ProblemReportOffer`), and «Справка» → «Собрать отчёт о
/// проблеме…» (`HelpCommands`).
struct ProblemReportSheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss
  /// Over the settings the sheet is lower, so it does not hang out of their window.
  var height: CGFloat = 440

  var body: some View {
    VStack(spacing: 0) {
      Form {
        ProblemReportView(gathersAtOnce: true)
      }
      .formStyle(.grouped)
      HStack {
        Spacer()
        Button(environment.language("action.close")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding([.horizontal, .bottom], 20)
    }
    .frame(width: 560, height: height)
  }
}

/// «Если при следующем старте отметка осталась, … приложение предлагает собрать отчёт».
/// The main window asks once after an interrupted session: «Собрать отчёт…» opens the report
/// itself, gathered — the section in the settings sits below the fold of a tab nobody opens
/// after a crash — and «Позже» lets it be. Either way the offer is spent; the label in the
/// settings and the Help menu stay.
struct ProblemReportOffer: ViewModifier {
  let deps: AppDependencies
  @State private var collects = false

  private var environment: AppEnvironment { deps.environment }
  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  func body(content: Content) -> some View {
    content
      .alert(
        t("report.offer.title"),
        // The alert goes only through its buttons, and each of them says what comes next:
        // the offer stays raised while the report it led to is open, so nothing else asks
        // over it.
        isPresented: Binding(
          get: { environment.offersProblemReport && !collects }, set: { _ in })
      ) {
        Button(t("report.offer.collect")) { collects = true }
        Button(t("report.offer.later"), role: .cancel) {
          environment.offersProblemReport = false
        }
      } message: {
        Text(verbatim: t("report.offer.message"))
      }
      // A sheet is laid out by a host of its own: the dependencies are handed over.
      .sheet(isPresented: $collects, onDismiss: { environment.offersProblemReport = false }) {
        ProblemReportSheet().appDependencies(deps)
      }
  }
}
