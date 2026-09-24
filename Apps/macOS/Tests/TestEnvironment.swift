import AppKit
import XCTest

/// What the Mac running the tests can show. The runners of CI are virtual Macs with a screen of
/// 1024 × 768 points and no assistive client, and two kinds of test cannot run there:
///
/// * a layout test whose window is wider than that screen: AppKit fits a window to the screen it
///   is ordered in on, and the test would measure the screen instead of the layout;
/// * a test that finds a menu or a button of SwiftUI the way VoiceOver finds it: SwiftUI builds
///   that tree only while something on the Mac asks for accessibility, and on a runner nothing
///   does (the controls of AppKit, an alert's buttons, still answer there).
///
/// Such a test skips there, saying why, and runs on the author's Mac, where `make test` runs it.
@MainActor
enum TestEnvironment {
  /// CI says so to the test host: `TEST_RUNNER_ITOGO_CI=1` in `.github/workflows/build.yml`.
  static var isCI: Bool { ProcessInfo.processInfo.environment["ITOGO_CI"] != nil }

  /// Skips the calling test on CI, where SwiftUI builds no accessibility tree.
  static func requireSwiftUIAccessibility() throws {
    try XCTSkipIf(
      isCI, "no assistive client on a CI runner: SwiftUI builds no accessibility tree there")
  }

  /// Skips the calling test when no screen of this Mac is as wide as the window it lays out.
  static func requireScreen(width: CGFloat) throws {
    let widest = NSScreen.screens.map(\.visibleFrame.width).max() ?? 0
    try XCTSkipIf(
      widest < width,
      "the screen is \(Int(widest)) points wide, and this layout needs a window of \(Int(width))")
  }
}
