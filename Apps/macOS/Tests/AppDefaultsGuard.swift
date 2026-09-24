import Foundation
import XCTest

@testable import Itogo

/// The principal class of the test bundle (`NSPrincipalClass`, project.yml): XCTest makes it
/// once, before the first test, and it registers the observers of the whole bundle.
@objc(ItogoTestBundlePrincipal)
final class TestBundlePrincipal: NSObject {
  override init() {
    super.init()
    XCTestObservationCenter.shared.addTestObserver(AppDefaultsGuard.shared)
    AppDefaultsGuard.isRegistered = true
  }
}

/// The owner's interface language and theme survive the tests.
///
/// The test host is the app itself, in the container of the Debug and Release builds: its
/// `UserDefaults.standard` is the owner's. A test that sets `AppLanguage.choice` writes
/// `app.language` and `AppleLanguages` there, and the tests used to remove only the first:
/// after `make test` the app opened in English, with the language of the last test left in
/// `AppleLanguages` (the live run of 19 September). A test that sets `AppTheme.scheme` or
/// `.accent` writes two more keys, and would leave the owner in the theme of the last test
/// — so the guard holds all four.
///
/// The guard takes the keys from the app's own domain before the first test — not through
/// `UserDefaults`, which would answer `AppleLanguages` from the system's global domain when
/// the app has none. Every test starts without any of them, in the language and theme of the
/// system as a fresh install would, whatever the owner chose; after every test, and once more
/// at the end of the bundle, the owner's values are put back and a key the owner did not have
/// is removed. A run stopped halfway leaves at most the keys of the test it was stopped in.
///
/// So a test that chooses a language or a theme leaves it as it is when it ends: no
/// `language.choice = .russian` on the last line, no `defer` to put one back. The guard is the
/// one mechanism, and a hand-made reset beside it only hides that.
///
/// `@unchecked Sendable`: everything it holds is immutable, and `UserDefaults` is documented
/// as safe to use from any thread, though the SDK does not mark it `Sendable`.
final class AppDefaultsGuard: NSObject, XCTestObservation, @unchecked Sendable {
  /// The two keys a choice of language writes (`AppLanguage.choice`).
  static let languageKey = "app.language"
  static let appleLanguagesKey = "AppleLanguages"
  /// The two keys a choice of theme writes (`AppTheme`).
  static let themeSchemeKey = AppTheme.schemeKey
  static let themeAccentKey = AppTheme.accentKey

  static let shared = AppDefaultsGuard(
    defaults: .standard, domain: Bundle.main.bundleIdentifier ?? "io.github.EvgenyBaulin.itogo")

  /// Set by the principal class: a test checks it, since a guard that never ran would fail
  /// silently.
  nonisolated(unsafe) static var isRegistered = false

  /// The values of every guarded key in one domain at one moment, a missing key as `nil`.
  struct Snapshot: Equatable, Sendable {
    var language: String?
    var appleLanguages: [String]?
    var themeScheme: String?
    var themeAccent: String?

    init(
      language: String? = nil, appleLanguages: [String]? = nil, themeScheme: String? = nil,
      themeAccent: String? = nil
    ) {
      self.language = language
      self.appleLanguages = appleLanguages
      self.themeScheme = themeScheme
      self.themeAccent = themeAccent
    }

    /// Only what `domain` itself holds: neither the global domain nor the arguments.
    init(of defaults: UserDefaults, domain: String) {
      let values = defaults.persistentDomain(forName: domain) ?? [:]
      language = values[AppDefaultsGuard.languageKey] as? String
      appleLanguages = values[AppDefaultsGuard.appleLanguagesKey] as? [String]
      themeScheme = values[AppDefaultsGuard.themeSchemeKey] as? String
      themeAccent = values[AppDefaultsGuard.themeAccentKey] as? String
    }

    /// Writes the values back; a key that was missing is removed.
    func restore(in defaults: UserDefaults) {
      Self.put(language, forKey: AppDefaultsGuard.languageKey, in: defaults)
      Self.put(appleLanguages, forKey: AppDefaultsGuard.appleLanguagesKey, in: defaults)
      Self.put(themeScheme, forKey: AppDefaultsGuard.themeSchemeKey, in: defaults)
      Self.put(themeAccent, forKey: AppDefaultsGuard.themeAccentKey, in: defaults)
    }

    private static func put(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
      if let value {
        defaults.set(value, forKey: key)
      } else {
        defaults.removeObject(forKey: key)
      }
    }
  }

  private let defaults: UserDefaults
  /// The owner's values, taken when the guard is made — before the first test.
  let owner: Snapshot

  init(defaults: UserDefaults, domain: String) {
    self.defaults = defaults
    owner = Snapshot(of: defaults, domain: domain)
    super.init()
  }

  func testCaseWillStart(_ testCase: XCTestCase) {
    Snapshot().restore(in: defaults)
  }

  func testCaseDidFinish(_ testCase: XCTestCase) {
    owner.restore(in: defaults)
  }

  func testBundleDidFinish(_ testBundle: Bundle) {
    owner.restore(in: defaults)
  }
}
