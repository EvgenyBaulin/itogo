import AppCore
import AppKit
import Foundation
import LocalAuthentication
import Observation

/// What an attempt to prove the owner is at the Mac came to.
enum LockAuthentication: Sendable, Equatable {
  case passed
  /// Touch ID or the password was refused.
  case failed
  /// The owner, or the system, closed the request: nothing to say about it.
  case cancelled
  /// This Mac can prove nothing — no Touch ID and no login password.
  case unavailable
}

/// Proves the owner is at the Mac. The app asks the system (`DeviceOwnerAuthenticator`); a test
/// hands in an answer of its own, so no test ever waits for a finger.
protocol LockAuthenticator: Sendable {
  func authenticate(reason: String) async -> LockAuthentication
}

/// Touch ID, and the password of the Mac where there is no Touch ID or it is not accepted
/// (`.deviceOwnerAuthentication`). No entitlement and no key of the Info.plist is needed for it
/// on macOS.
struct DeviceOwnerAuthenticator: LockAuthenticator {
  func authenticate(reason: String) async -> LockAuthentication {
    let context = LAContext()
    var problem: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &problem) else {
      return .unavailable
    }
    do {
      let passed = try await context.evaluatePolicy(
        .deviceOwnerAuthentication, localizedReason: reason)
      return passed ? .passed : .failed
    } catch let error as LAError {
      switch error.code {
      case .userCancel, .systemCancel, .appCancel: return .cancelled
      case .passcodeNotSet, .biometryNotAvailable: return .unavailable
      default: return .failed
      }
    } catch {
      return .failed
    }
  }
}

/// «Блокировать Итого»: off until the owner turns it on; then every window is covered when the
/// app opens, after a few minutes without a key press or a click in it, and when the Mac goes to
/// sleep or locks its screen — until Touch ID or the password of the Mac says it is the owner.
///
/// Only what is shown is locked: the pipeline, the backups and the bank's rates go on behind the
/// cover. Turning the lock on asks for the proof first, so it is never switched on by somebody
/// who could not switch it off. The data sets of a build and the tests are never locked
/// (`applies`): synthetic books have nothing to hide, and a test must never wait for a finger.
///
/// Kept in `UserDefaults` of this Mac (`privacy.lock.enabled`, `privacy.lock.idleMinutes`),
/// never in the archive: another Mac may have no Touch ID.
@MainActor
@Observable
final class PrivacyLock {
  nonisolated static let enabledKey = "privacy.lock.enabled"
  nonisolated static let idleMinutesKey = "privacy.lock.idleMinutes"
  /// The idle times Settings offers, in minutes.
  static let idleChoices = [1, 5, 15, 60]
  static let defaultIdleMinutes = 5

  /// Why the windows were covered — a token for the journal.
  enum Reason: String {
    case launch, idle, sleep, screen, menu
  }

  /// Whether the lock can lock at all here: never in a data set or in the test host.
  let applies: Bool
  /// The owner turned the lock on (and proved it was the owner when doing so).
  private(set) var isEnabled: Bool
  /// How long the app may stay untouched before it locks; one of `idleChoices`.
  var idleMinutes: Int {
    didSet {
      let sane = Self.sanitized(idleMinutes)
      if sane != idleMinutes { idleMinutes = sane }
      defaults?.set(sane, forKey: Self.idleMinutesKey)
    }
  }
  /// The windows are covered.
  private(set) var isLocked: Bool
  /// A request for Touch ID or the password is on screen: a second one is not made.
  private(set) var isAuthenticating = false
  /// What the last attempt to unlock or to turn the lock on came to, when it did not pass; the
  /// cover and Settings say it in words. Cleared by the next attempt.
  private(set) var lastRefusal: LockAuthentication?

  @ObservationIgnored private let defaults: UserDefaults?
  @ObservationIgnored private let authenticator: any LockAuthenticator
  @ObservationIgnored private let now: () -> Date
  /// The last key press, click or scroll in the app. Not observed: it changes with every event,
  /// and nothing on screen shows it.
  @ObservationIgnored private(set) var lastActivity: Date
  @ObservationIgnored private var watch: PrivacyLockWatch?

  init(
    applies: Bool, defaults: UserDefaults?,
    authenticator: any LockAuthenticator = DeviceOwnerAuthenticator(),
    now: @escaping () -> Date = { Date() }
  ) {
    self.applies = applies
    self.defaults = defaults
    self.authenticator = authenticator
    self.now = now
    let enabled = applies && (defaults?.bool(forKey: Self.enabledKey) ?? false)
    isEnabled = enabled
    idleMinutes = Self.sanitized(
      defaults?.object(forKey: Self.idleMinutesKey) as? Int ?? Self.defaultIdleMinutes)
    // Locked from the first frame: the window is never drawn with the books open first.
    isLocked = enabled
    lastActivity = now()
    if enabled { Self.journal(locked: .launch) }
  }

  /// The nearest choice to a stored number of minutes: a number written by hand, or by a build
  /// that offered other choices, still gives one of the four.
  static func sanitized(_ minutes: Int) -> Int {
    idleChoices.min { abs($0 - minutes) < abs($1 - minutes) } ?? defaultIdleMinutes
  }

  /// A key press, a click or a scroll in any window of the app.
  func noteActivity() {
    lastActivity = now()
  }

  /// Locks when the app has been left alone for `idleMinutes`. Called by a timer; returns
  /// whether it locked now.
  @discardableResult
  func checkIdle() -> Bool {
    guard isEnabled, !isLocked, !isAuthenticating else { return false }
    guard now().timeIntervalSince(lastActivity) >= TimeInterval(idleMinutes * 60) else {
      return false
    }
    lock(because: .idle)
    return true
  }

  /// Covers every window now.
  func lock(because reason: Reason) {
    guard isEnabled, !isLocked else { return }
    isLocked = true
    lastRefusal = nil
    Self.journal(locked: reason)
  }

  /// Asks for Touch ID or the password, and takes the cover away when it passes. `reason` is
  /// the end of the system's sentence: «“Итого” пытается <reason>».
  @discardableResult
  func unlock(reason: String) async -> Bool {
    guard isLocked, !isAuthenticating else { return !isLocked }
    isAuthenticating = true
    lastRefusal = nil
    let answer = await authenticator.authenticate(reason: reason)
    isAuthenticating = false
    guard answer == .passed else {
      lastRefusal = answer
      AppLog.info(
        "privacy.unlockFailed", .ui, "the windows stay covered",
        [LogPair("answer", .token(Self.token(answer)))])
      return false
    }
    isLocked = false
    lastActivity = now()
    AppLog.info("privacy.unlocked", .ui, "the windows were uncovered")
    return true
  }

  /// Turns the lock on, once the owner has proved who they are; refused, it stays off.
  @discardableResult
  func enable(reason: String) async -> Bool {
    guard applies, !isEnabled, !isAuthenticating else { return isEnabled }
    isAuthenticating = true
    lastRefusal = nil
    let answer = await authenticator.authenticate(reason: reason)
    isAuthenticating = false
    guard answer == .passed else {
      lastRefusal = answer
      AppLog.info(
        "privacy.enableRefused", .ui, "the lock stays off",
        [LogPair("answer", .token(Self.token(answer)))])
      return false
    }
    isEnabled = true
    lastActivity = now()
    defaults?.set(true, forKey: Self.enabledKey)
    AppLog.info("privacy.lockEnabled", .ui, "the lock was turned on")
    return true
  }

  /// Turns the lock off. Only reachable from Settings, which the cover hides while locked.
  func disable() {
    guard isEnabled else { return }
    isEnabled = false
    isLocked = false
    lastRefusal = nil
    defaults?.set(false, forKey: Self.enabledKey)
    AppLog.info("privacy.lockDisabled", .ui, "the lock was turned off")
  }

  /// Starts to watch the events of the app, the clock, the sleep of the Mac and the lock of its
  /// screen. Once; never where the lock does not apply.
  func startWatching() {
    guard applies, watch == nil, !AppEnvironment.isTestHost else { return }
    watch = PrivacyLockWatch(lock: self)
  }

  private static func journal(locked reason: Reason) {
    AppLog.info(
      "privacy.locked", .ui, "the windows were covered",
      [LogPair("reason", .token(reason.rawValue))])
  }

  private static func token(_ answer: LockAuthentication) -> String {
    switch answer {
    case .passed: "passed"
    case .failed: "failed"
    case .cancelled: "cancelled"
    case .unavailable: "unavailable"
    }
  }
}

/// The eyes and the clock of `PrivacyLock`: a key press, a click or a scroll in any window of the
/// app keeps it awake; a timer looks at the idle time twice a minute; the sleep of the Mac and the
/// lock of its screen lock at once. Lives as long as the app. The centers the system posts to are
/// handed in, so a test can post the sleep and the lock of the screen itself.
@MainActor
final class PrivacyLockWatch {
  /// What the system posts when the screen of the Mac is locked (⌃⌘Q, the lid, the screen saver).
  nonisolated static let screenLocked = Notification.Name("com.apple.screenIsLocked")
  /// What the system posts before the Mac sleeps and when its displays go dark.
  nonisolated static let sleeps = [
    NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
  ]

  private var monitor: Any?
  private var timer: Timer?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []

  init(
    lock: PrivacyLock, workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
    distributed: NotificationCenter = DistributedNotificationCenter.default(),
    watchesActivity: Bool = true
  ) {
    if watchesActivity {
      monitor = NSEvent.addLocalMonitorForEvents(
        matching: [
          .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved,
        ]
      ) { [weak lock] event in
        MainActor.assumeIsolated { lock?.noteActivity() }
        return event
      }
      timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak lock] _ in
        MainActor.assumeIsolated { _ = lock?.checkIdle() }
      }
    }
    for name in Self.sleeps {
      observe(workspace, name) { [weak lock] in lock?.lock(because: .sleep) }
    }
    observe(distributed, Self.screenLocked) { [weak lock] in lock?.lock(because: .screen) }
  }

  /// Stops watching: the observers, the monitor of events and the timer go.
  func stop() {
    for (center, token) in observers { center.removeObserver(token) }
    observers = []
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    timer?.invalidate()
    timer = nil
  }

  private func observe(
    _ center: NotificationCenter, _ name: Notification.Name,
    _ action: @escaping @MainActor () -> Void
  ) {
    let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { action() }
    }
    observers.append((center, token))
  }
}
