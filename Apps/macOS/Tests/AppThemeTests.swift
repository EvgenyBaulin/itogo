import AppKit
import SwiftUI
import XCTest

@testable import Itogo

/// Light, dark or the system's, and the accent colour. The keys these tests
/// write are the owner's own: `AppDefaultsGuard` clears them before every test and puts the
/// owner's back afterwards, so nothing here has to tidy up by hand.
@MainActor
final class AppThemeTests: XCTestCase {
  func testSystemIsTheDefaultAndOverridesNothing() {
    let theme = AppTheme()

    XCTAssertEqual(theme.scheme, .system)
    XCTAssertEqual(theme.accent, .system)
    // «Светлая и тёмная тема — как в системе»: without a choice nothing is imposed.
    XCTAssertNil(theme.colorScheme)
    XCTAssertNil(AppTheme.Scheme.system.appearance)
    XCTAssertNil(theme.tint)
  }

  func testAChoiceSurvivesANewInstance() {
    let theme = AppTheme()
    theme.scheme = .dark
    theme.accent = .teal

    let again = AppTheme()
    XCTAssertEqual(again.scheme, .dark)
    XCTAssertEqual(again.accent, .teal)
    XCTAssertEqual(UserDefaults.standard.string(forKey: AppTheme.schemeKey), "dark")
    XCTAssertEqual(UserDefaults.standard.string(forKey: AppTheme.accentKey), "teal")
  }

  func testLightAndDarkMapOntoTheSystemAppearances() {
    XCTAssertEqual(AppTheme.Scheme.light.appearance?.name, .aqua)
    XCTAssertEqual(AppTheme.Scheme.dark.appearance?.name, .darkAqua)
    XCTAssertEqual(AppTheme.Scheme.light.colorScheme, .light)
    XCTAssertEqual(AppTheme.Scheme.dark.colorScheme, .dark)
  }

  /// Every accent is a system colour: the app owns no hexadecimal value of its own, so the
  /// colours follow the dark theme and «Увеличить контраст» by themselves.
  func testEveryAccentIsASystemColour() {
    let system: Set<Color> = [
      .accentColor, .orange, .blue, .teal, .green, .indigo, .purple, .pink, .gray,
    ]
    for accent in AppTheme.Accent.allCases {
      XCTAssertTrue(system.contains(accent.color), "\(accent.rawValue) is not a system colour")
      XCTAssertTrue(accent.settingsKey.hasPrefix("settings.appearance.accent."))
    }
    // The system accent is the one that leaves `.tint(_:)` alone.
    XCTAssertNil(AppTheme.Accent.system.tint)
    for accent in AppTheme.Accent.allCases where accent != .system {
      XCTAssertEqual(accent.tint, accent.color, accent.rawValue)
    }
  }

  /// Every choice has a caption, in both languages: a new option without a translation must
  /// fail here rather than show its raw value in the Settings.
  func testEveryChoiceHasACaptionInBothLanguages() {
    let language = AppLanguage()
    let keys =
      AppTheme.Scheme.allCases.map(\.settingsKey) + AppTheme.Accent.allCases.map(\.settingsKey)
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys {
        XCTAssertNotEqual(
          language(key, table: "Settings"), key, "\(key) is missing in \(choice.rawValue)")
      }
    }
  }

  /// The test host is the app itself: a run must not leave the owner's app
  /// painted in the theme of the last test.
  func testTheThemeIsNotAppliedToTheAppFromATest() {
    XCTAssertTrue(AppEnvironment.isTestHost)
    let before = NSApp?.appearance

    let theme = AppTheme()
    theme.scheme = .dark
    theme.applyAppearance()

    XCTAssertEqual(NSApp?.appearance, before)
  }

  /// The theme travels with the archive and with the problem report through the one funnel
  /// both of them read (`AppEnvironment.portableSettings`).
  func testTheThemeTravelsInThePortableSettings() {
    let environment = AppEnvironment()
    environment.theme.scheme = .dark
    environment.theme.accent = .indigo

    let values = environment.portableSettings()
    XCTAssertEqual(values["theme.scheme"], "dark")
    XCTAssertEqual(values["theme.accent"], "indigo")
    XCTAssertEqual(values["language"], environment.language.choice.rawValue)
  }
}
