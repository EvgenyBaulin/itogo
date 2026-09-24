import AppCore
import AppKit
import Foundation

#if canImport(Sparkle)
  import Sparkle
#endif

/// «Reload & Update» and «Reload».
///
/// Two builds, two answers, and the flags that tell them apart finally do something:
///
/// * **Direct** — check for an update; install it and restart if there is one, restart if
///   there is not. Sparkle does the checking, the downloading and the installing.
/// * **AppStore** — restart, and nothing else. The store distributes updates there, and
///   a store build may not carry an updater of its own. The menu item opens the app's page
///   instead.
///
/// The Direct half is written against `canImport(Sparkle)` as well as the configuration flag,
/// so the application builds, runs and is tested with or without the package being fetched.
@MainActor
enum UpdateService {
  /// What the menu item says and does, by the build it is in.
  enum Kind {
    /// Direct with Sparkle: check, install, restart.
    case updateAndRestart
    /// Direct without the package: the button is honest about restarting only.
    case restartOnly
    /// AppStore: restart, and the store page for updates.
    case restartAndStorePage
  }

  static var kind: Kind {
    #if APPSTORE
      return .restartAndStorePage
    #elseif canImport(Sparkle)
      return canVerifyUpdates ? .updateAndRestart : .restartOnly
    #else
      return .restartOnly
    #endif
  }

  /// The version of the updater inside this build, for the problem report («версии
  /// зависимостей»); `nil` in a build without one. Sparkle's framework carries its real
  /// version in its own `Info.plist`.
  static var sparkleVersion: String? {
    #if canImport(Sparkle) && !APPSTORE
      Bundle(for: SPUUpdater.self).object(forInfoDictionaryKey: "CFBundleShortVersionString")
        as? String
    #else
      nil
    #endif
  }

  /// The placeholder a build from the repository carries, until a release puts the owner's
  /// own key in its place (`scripts/make-release.sh`).
  static let placeholderKey = "SPARKLE_PUBLIC_KEY_NOT_SET"

  /// Whether this build can tell a real update from something else.
  ///
  /// An updater that cannot check a signature has no business checking for updates: it would
  /// ask GitHub for a feed every day, and refuse whatever came back. So a build without a
  /// real key says «Перезапустить» and means it.
  static var canVerifyUpdates: Bool {
    let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
    return !key.isEmpty && key != placeholderKey
  }

  /// Lets the updater keep its own schedule («автоматическая проверка и фоновая
  /// установка включены по умолчанию»). Called once per process from `AppLaunch`.
  ///
  /// Never in the test host: a test run must not reach the network, and the host is not a
  /// user. Never without a real key either — see `canVerifyUpdates`.
  @discardableResult
  static func startIfPossible(isTestHost: Bool = AppEnvironment.isTestHost) -> Bool {
    guard !isTestHost, kind == .updateAndRestart else { return false }
    #if canImport(Sparkle) && !APPSTORE
      _ = updater
      isRunning = true
      AppLog.info("update.started", .app, "the updater keeps its own schedule")
      return true
    #else
      return false
    #endif
  }

  /// The title of the menu item: «Обновить и перезапустить» where an update can arrive,
  /// «Перезапустить» where it cannot.
  static func title(_ environment: AppEnvironment) -> String {
    environment.language(kind == .updateAndRestart ? "action.reloadAndUpdate" : "action.reload")
  }

  /// The page of the app in the Mac App Store; only the store build shows it.
  static let storePageURL = URL(string: "macappstore://apps.apple.com/app/itogo")

  /// What the menu item does. The restart is the same one an import does, so the database is
  /// put down in order before anything else starts.
  static func reload() {
    AppLog.info(
      "update.asked", .app, "an update was asked for",
      [LogPair("kind", .token(String(describing: kind)))])
    #if !APPSTORE
      if checkAndInstall() { return }
    #endif
    AppRestart.relaunch()
  }

  /// Opens the store page. Nothing to do outside the store build.
  static func openStorePage() {
    guard kind == .restartAndStorePage, let storePageURL else { return }
    NSWorkspace.shared.open(storePageURL)
  }

  /// Asks Sparkle to check, and says whether it took over. `false` means «nothing here can
  /// update anything» and the caller simply restarts.
  private static func checkAndInstall() -> Bool {
    #if canImport(Sparkle) && !APPSTORE
      guard kind == .updateAndRestart else { return false }
      // Sparkle restarts the application itself when it installs something. When it finds
      // nothing, nobody would — so the answer below does it, and the button keeps its word.
      isRunning = true
      let sparkle = updater.updater
      switch Answers.ask.pressed(
        canCheck: sparkle.canCheckForUpdates, sessionInProgress: sparkle.sessionInProgress)
      {
      case .check:
        sparkle.checkForUpdates()
        return true
      case .wait:
        // Sparkle ignores a check asked for while it fetches something in the background;
        // the owner's check is made when that session ends (`Answers`).
        AppLog.info("update.waiting", .app, "a background session runs; the check waits for it")
        return true
      case .restart:
        return false
      }
    #else
      return false
    #endif
  }

  #if canImport(Sparkle) && !APPSTORE
    /// One updater for the process. Held here rather than in a view, because it outlives
    /// every window: a check begun in one window must not die when that window closes.
    ///
    /// `startingUpdater: true` lets Sparkle keep its own schedule by the settings in
    /// `Info.plist` — automatic checking on, nothing about this Mac sent. Nothing
    /// touches this until `startIfPossible()` or the menu item does, so a build that cannot
    /// verify an update never starts one.
    static let updater = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: answers, userDriverDelegate: nil)

    /// Whether something has touched `updater` — and so started it. Until then a setting is
    /// written where Sparkle will read it, and nothing is started to write it.
    private(set) static var isRunning = false

    private static let answers = Answers()

    /// What Sparkle tells us back.
    ///
    /// The one thing it has to know is whether the check was asked for by hand. «Обновить и
    /// перезапустить» promises a restart, so when there is nothing to install it restarts — but a
    /// check Sparkle made by its own schedule must never restart the application under the owner's
    /// hands. Which press waits for what is `UpdateAsk`: a press lives for the one cycle of the
    /// owner's own check, and whatever ends that cycle — nothing found, an update skipped or put
    /// off, a check that failed — puts it down, so the next day's scheduled check, which reports a
    /// skipped version as nothing new, never restarts the application mid-entry.
    final class Answers: NSObject, SPUUpdaterDelegate {
      @MainActor static var ask = UpdateAsk()

      /// What a restart is; a test hands in its own, so no test ever restarts the host.
      private let relaunch: @MainActor () -> Void

      init(relaunch: @escaping @MainActor () -> Void = { AppRestart.relaunch() }) {
        self.relaunch = relaunch
      }

      /// Sparkle says whether the check that found nothing was the owner's own
      /// (`SPUNoUpdateFoundUserInitiatedKey`); a scheduled one says «no».
      func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        let userInitiated =
          (error as NSError).userInfo[SPUNoUpdateFoundUserInitiatedKey] as? Bool ?? false
        MainActor.assumeIsolated {
          guard Self.ask.nothingFound(userInitiated: userInitiated) else { return }
          AppLog.info("update.none", .app, "nothing to install; restarting as the button says")
          relaunch()
        }
      }

      /// Every session ends here, found or not, failed or not. A press that waited for a
      /// background session makes its check now — Sparkle has marked its session over before
      /// it calls this, and allows a new one to begin from here.
      func updater(
        _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
      ) {
        MainActor.assumeIsolated {
          guard Self.ask.cycleEnded(userInitiated: updateCheck == .updates) else { return }
          AppLog.info("update.resumed", .app, "the background session ended; checking now")
          updater.checkForUpdates()
        }
      }

      /// A check that could not be made — no network, a feed that is not there yet — is not
      /// a reason to restart: Sparkle has already told the owner what went wrong, and
      /// throwing the windows away on top of that would be rude. The session's end, which
      /// comes right after, puts the press down. «Nothing new» comes this way too, and is not
      /// a failure.
      func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        MainActor.assumeIsolated {
          guard !Self.foundNothingNew(error) else { return }
          AppLog.warning(
            "update.failed", .app, "the update check did not finish",
            [LogPair("code", .count((error as NSError).code))])
        }
      }

      private static func foundNothingNew(_ error: (any Error)?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == SUSparkleErrorDomain
          && error.code == Int(SUError.noUpdateError.rawValue)
      }
    }
  #endif
}

#if !APPSTORE
  /// What a press of «Обновить и перезапустить» still waits for, kept apart from Sparkle so the
  /// rules can be tested without starting it.
  ///
  /// Sparkle ignores `checkForUpdates()` while a session of its own fetches something in the
  /// background (`canCheckForUpdates` is false then), and it reports «nothing found» for its
  /// scheduled checks as well. So a press is remembered only for the check that is the owner's:
  /// made at once when Sparkle can, made when the background session ends when it cannot. Any
  /// other end of a session puts the press down — a check that failed, an update shown and
  /// dismissed — and no scheduled check a day later restarts the application under the
  /// owner's hands.
  struct UpdateAsk {
    /// What the press does now.
    enum Step: Equatable {
      /// Ask Sparkle for the owner's check.
      case check
      /// A background session runs: the check is made when it ends.
      case wait
      /// No updater is working at all: keep the half of the word that can be kept.
      case restart
    }

    private enum State { case idle, waiting, checking }
    private var state = State.idle

    mutating func pressed(canCheck: Bool, sessionInProgress: Bool) -> Step {
      if canCheck {
        state = .checking
        return .check
      }
      if sessionInProgress {
        state = .waiting
        return .wait
      }
      state = .idle
      return .restart
    }

    /// Sparkle found nothing to install. `true` — restart: it was the owner's own check.
    mutating func nothingFound(userInitiated: Bool) -> Bool {
      guard userInitiated, state == .checking else { return false }
      state = .idle
      return true
    }

    /// A session ended. `true` — make the owner's check now: his press waited for this one.
    mutating func cycleEnded(userInitiated: Bool) -> Bool {
      if state == .waiting, !userInitiated {
        state = .checking
        return true
      }
      state = .idle
      return false
    }
  }

  /// «Обновления: автоматические вкл/выкл (по умолчанию вкл)».
  ///
  /// One switch for the two things the specification turns on together — «автоматическая
  /// проверка и фоновая установка»: Sparkle's own schedule of checks and its installing in
  /// the background. The choice is kept where Sparkle keeps it, `SUEnableAutomaticChecks`
  /// and `SUAutomaticallyUpdate` in the app's defaults, which it reads before `Info.plist`: so
  /// it holds for an updater started later, and never needs one started to be written. A
  /// running updater is told through its own settings, so it plans its next check again.
  ///
  /// Not in the store build: nothing there updates the app but the store.
  @MainActor
  struct AutomaticUpdates {
    static let checksKey = "SUEnableAutomaticChecks"
    static let installsKey = "SUAutomaticallyUpdate"

    var defaults: UserDefaults = .standard
    /// What the bundle says when the owner has said nothing: `Info.plist` turns both on.
    var info: [String: Any] = Bundle.main.infoDictionary ?? [:]

    /// Whether the switch does anything in this build: only where an update can arrive at all
    /// (`UpdateService.canVerifyUpdates`). Elsewhere it is shown greyed, with the reason.
    static var isChangeable: Bool { UpdateService.kind == .updateAndRestart }

    var isOn: Bool {
      get {
        defaults.object(forKey: Self.checksKey) as? Bool
          ?? info[Self.checksKey] as? Bool ?? true
      }
      nonmutating set {
        if !tellTheRunningUpdater(newValue) {
          defaults.set(newValue, forKey: Self.checksKey)
          defaults.set(newValue, forKey: Self.installsKey)
        }
        AppLog.info(
          "update.automatic", .app, "automatic updates switched",
          [LogPair("on", .token(newValue ? "yes" : "no"))])
      }
    }

    /// Sets both through the updater when one is running over these very defaults: it writes
    /// the same two keys and plans its next check again. `false` — nothing is running, or the
    /// defaults are somebody else's (a test's) — and the caller writes the keys itself.
    private func tellTheRunningUpdater(_ isOn: Bool) -> Bool {
      #if canImport(Sparkle)
        guard defaults == .standard, UpdateService.isRunning else { return false }
        UpdateService.updater.updater.automaticallyChecksForUpdates = isOn
        UpdateService.updater.updater.automaticallyDownloadsUpdates = isOn
        return true
      #else
        return false
      #endif
    }
  }
#endif
