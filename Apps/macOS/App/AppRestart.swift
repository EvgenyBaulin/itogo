import AppCore
import AppKit
import Foundation

/// Relaunches the app in place. Used by the language switch and, in the Direct build,
/// by "Reload & Update" once Sparkle is wired up.
enum AppRestart {
  /// What a relaunch asks and does. The app's own answers stand here; a test hands in its
  /// own, because the real ones open a second app and quit the test host.
  @MainActor
  struct Steps {
    var stop: @MainActor () async -> Void = { await AppLaunch.stopStarted() }
    var open: @MainActor (URL) async throws -> Void = { url in try await openNewInstance(of: url) }
    var tell: @MainActor (Failure) -> Void = { AppRestart.tell($0) }
    var terminate: @MainActor () -> Void = { NSApplication.shared.terminate(nil) }
    var clock: AppQuit.Clock = AppQuit.timer
  }

  enum Failure: String, Equatable, Sendable {
    case stopOverran
    case openFailed
  }

  /// The database is put down before the new instance opens: the one that starts may move a
  /// restored or imported file into place (`AppPaths.applyPendingReplacement`), and it must
  /// not do that under an open database.
  @MainActor
  static func relaunch() {
    relaunch(using: Steps())
  }

  /// How long the database may take to be put down before the relaunch gives up. Longer
  /// than the two seconds of a quit (`AppQuit`): the owner asked for the app back, and a stop
  /// that waits for a long step of the pipeline is worth waiting for rather than losing the
  /// relaunch over.
  static let limit: TimeInterval = 10

  /// The relaunch under way: a second press waits with it rather than starting a second
  /// stop and opening a second instance.
  @MainActor private static var underWay: AppQuit?

  /// The stop first, within `limit`; then the new instance, then the quit. The old instance quits
  /// whatever happens — its database is closed by then and opens no more — but when the new one did
  /// not open, or the stop never ended, the owner is told before it does, rather than left with no
  /// app and no word. A stop past the limit opens nothing: a new instance beside a database still
  /// open could move a restored file from under it.
  @MainActor
  static func relaunch(using steps: Steps) {
    guard underWay == nil else { return }
    let relaunch = AppQuit(limit: limit, clock: steps.clock) { outcome in
      Task { @MainActor in
        switch outcome {
        case .stopped:
          do {
            try await steps.open(Bundle.main.bundleURL)
          } catch {
            AppLog.error(
              "app.relaunchFailed", .app, "the new instance of the application did not open",
              [
                LogPair("reason", .token(Failure.openFailed.rawValue)),
                LogPair("error", .error(error)),
              ])
            steps.tell(.openFailed)
          }
        case .overran:
          AppLog.error(
            "app.relaunchFailed", .app, "the application was not put down in time to relaunch",
            [
              LogPair("reason", .token(Failure.stopOverran.rawValue)),
              LogPair("limit", .milliseconds(Int(limit * 1000))),
            ])
          steps.tell(.stopOverran)
        }
        steps.terminate()
        underWay = nil
      }
    }
    underWay = relaunch
    relaunch.begin(steps.stop)
  }

  /// What the owner reads when the relaunch failed, in the language of the interface.
  @MainActor
  static func tell(_ failure: Failure) {
    let language = AppLanguage()
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = language("relaunch.failed.title")
    alert.informativeText = language(
      failure == .openFailed ? "relaunch.failed.open" : "relaunch.failed.stop")
    alert.addButton(withTitle: language("action.ok"))
    alert.runModal()
  }

  /// A second instance of the app at `url`.
  @MainActor
  private static func openNewInstance(of url: URL) async throws {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.createsNewApplicationInstance = true
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}
