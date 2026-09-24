import AppCore
import AppKit
import SwiftUI

/// Copies of the database: where they go, what is there and how to come back from one.
/// The live database is never placed in iCloud — only copies are mirrored there.
struct BackupSettingsView: View {
  @Dependency(\.environment) private var environment
  @State private var copies: [URL] = []
  @State private var mirror: URL?
  @State private var pendingRestore: URL?
  /// What went wrong with the last copy, as a key of the Settings catalog.
  @State private var failure: String?
  /// Why the last restore stopped, as a key of the Settings catalog.
  @State private var restoreFailure: String?
  /// Why the folder just chosen was not taken, as a key of the Settings catalog.
  @State private var folderFailure: String?

  var body: some View {
    Form {
      Section {
        LabeledContent {
          HStack(spacing: 8) {
            Text(verbatim: mirror?.lastPathComponent ?? "—")
              .foregroundStyle(.secondary)
            Button(environment.language("settings.backups.choose", table: "Settings")) {
              chooseFolder()
            }
            .disabled(AppPaths.dataSet != nil)
          }
        } label: {
          Text(verbatim: environment.language("settings.backups.folder", table: "Settings"))
        }
      } footer: {
        if AppPaths.dataSet != nil {
          Text(verbatim: environment.language(Self.dataSetMirrorsNowhereKey, table: "Settings"))
            .foregroundStyle(.secondary)
        }
      }

      if !problems.isEmpty {
        Section {
          ForEach(problems, id: \.self) { key in
            Label {
              Text(verbatim: environment.language(key, table: "Settings"))
            } icon: {
              Image(systemName: "exclamationmark.triangle")
            }
            .foregroundStyle(.orange)
          }
        }
      }

      Section {
        if copies.isEmpty {
          Text(verbatim: environment.language("backups.empty", table: "Settings"))
            .foregroundStyle(.secondary)
        } else {
          let listing = Self.listing(of: copies)
          ForEach(listing.recent, id: \.self, content: row)
          if !listing.older.isEmpty {
            DisclosureGroup(
              environment.format("backups.older", table: "Settings", listing.older.count)
            ) {
              ForEach(listing.older, id: \.self, content: row)
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .padding()
    .onAppear(perform: reload)
    .alert(
      environment.language("backups.restoreConfirm", table: "Settings"),
      isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })
    ) {
      Button(environment.language("action.cancel"), role: .cancel) { pendingRestore = nil }
      Button(environment.language("backups.restore", table: "Settings"), role: .destructive) {
        restore()
      }
    }
    .alert(
      environment.language(restoreFailure ?? "backups.restore.failed", table: "Settings"),
      isPresented: Binding(get: { restoreFailure != nil }, set: { if !$0 { restoreFailure = nil } })
    ) {
      Button(environment.language("action.ok")) { restoreFailure = nil }
    }
  }

  /// One copy of the list, with the way back from it.
  private func row(_ url: URL) -> some View {
    HStack {
      Text(verbatim: url.lastPathComponent)
        .font(.callout.monospaced())
      Spacer()
      Button(environment.language("backups.restore", table: "Settings")) {
        pendingRestore = url
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
    }
  }

  /// How many of the newest copies are in view; the rest are one click away.
  static let recentCount = 20

  /// The copies the tab lists, newest first: the newest in view, and every other copy that is
  /// kept — the rest of the newest fifty, the daily copies of ninety days — under a disclosure.
  /// A copy kept on disk and listed nowhere could not be restored from Settings.
  static func listing(of copies: [URL]) -> (recent: [URL], older: [URL]) {
    (Array(copies.prefix(recentCount)), Array(copies.dropFirst(recentCount)))
  }

  /// Said when the folder for copies was chosen once and no longer opens.
  static let mirrorUnavailableKey = "backups.failure.mirrorUnavailable"

  /// What is wrong, as keys of the Settings catalog: the folder first — nothing reaches it until
  /// it is chosen again — then the last copy.
  private var problems: [String] {
    var keys: [String] = []
    if let folderFailure { keys.append(folderFailure) }
    if environment.mirrorFolderUnavailable { keys.append(Self.mirrorUnavailableKey) }
    if let failure { keys.append(failure) }
    return keys
  }

  private func reload() {
    mirror = Self.shownFolder(in: environment)
    guard let backups = environment.backups else { return }
    Task {
      let found = (try? await backups.backups()) ?? []
      let problem = await backups.lastFailure
      await MainActor.run {
        copies = found
        failure = problem?.messageKey
      }
    }
  }

  /// The folder the copies go to: the one the environment opened access to at the launch or at
  /// the choice. A folder chosen once whose bookmark no longer opens is not it, and a data set
  /// mirrors nowhere — neither is named, and the first says why below. Access is never opened
  /// here: every opening has to be balanced, and the tab appears any number of times.
  static func shownFolder(in environment: AppEnvironment) -> URL? {
    environment.mirrorFolder
  }

  private func chooseFolder() {
    guard let url = Self.askForFolder() else { return }
    folderFailure = Self.choose(url, in: environment)
    mirror = Self.shownFolder(in: environment)
  }

  /// The panel that asks for the folder of the copies: the sandbox gets access to the folder
  /// the owner actually picked. Nil when the owner stepped back.
  static func askForFolder() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    return panel.runModal() == .OK ? panel.url : nil
  }

  /// «Выбрать папку…» of the question the main window asks after an import
  /// (`AppEnvironment.asksForMirrorFolder`): the same panel and the same rule as the tab, and
  /// what went wrong said in an alert, since no tab is there to show it.
  static func chooseAfterImport(in environment: AppEnvironment) {
    guard let url = askForFolder(), let problem = choose(url, in: environment) else { return }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = environment.language(problem, table: "Settings")
    alert.runModal()
  }

  /// Said in a data-set launch, where copies are mirrored nowhere.
  static let dataSetMirrorsNowhereKey = "backups.dataSet.noMirror"

  /// Said when the folder just chosen could not be remembered, so it was not taken.
  static let folderNotRememberedKey = "backups.failure.folderNotRemembered"

  /// The folder the owner chose becomes the folder of the copies only once its bookmark is
  /// saved: the bookmark is what finds it after a restart. Taken without one, it was mirrored
  /// into until the quit and then forgotten — or, worse, the next launch went back to the folder
  /// chosen before — while the tab showed the new one. Now the folder in use stays in use, and
  /// the key of what went wrong comes back for the tab to say.
  ///
  /// A data-set launch takes no folder at all: its copies stay in its own folder, and the one
  /// key the bookmark is kept under is the owner's too (`AppEnvironment.open`).
  static func choose(
    _ url: URL, in environment: AppEnvironment, dataSet: AppPaths.DataSet? = AppPaths.dataSet
  ) -> String? {
    guard dataSet == nil else { return dataSetMirrorsNowhereKey }
    do {
      try environment.backupFolder.save(url)
    } catch {
      AppLog.error(
        "backup.bookmarkFailed", .backup, "the folder chosen for copies could not be remembered",
        [LogPair("error", .error(error))])
      return folderNotRememberedKey
    }
    environment.useMirrorFolder(url)
    return nil
  }

  /// A copy of the current state is written first, so restoring is itself undoable; without
  /// that copy nothing is replaced, and the owner is told why (`BackupRestoreFlow`).
  ///
  /// The chosen copy is staged next to the database and swapped in at the next launch:
  /// replacing a file that is open would race with the write-ahead log.
  private func restore() {
    guard let url = pendingRestore, let backups = environment.backups else { return }
    pendingRestore = nil
    Task {
      do {
        if case .failed = environment.state {
          // The database did not open: nothing is open to be replaced from under, so nothing
          // to relaunch for. The file that did not open is set aside whole, and the start is
          // made again (`DatabaseRecovery`).
          try await DatabaseRecovery.stage(url, replacing: environment)
          await AppLaunch.retryStarted()
        } else {
          try await BackupRestoreFlow.stage(
            copy: url, backups: backups, target: AppPaths.pendingReplacementURL)
          AppRestart.relaunch()
        }
      } catch {
        restoreFailure = (error as? BackupRestoreFlow.Failure ?? .notStaged).messageKey
      }
    }
  }
}
