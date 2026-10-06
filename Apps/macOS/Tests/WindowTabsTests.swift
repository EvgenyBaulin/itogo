import AppKit
import SwiftUI
import XCTest

@testable import Itogo

/// Analytics, Transactions and Reports open as tabs of the main window, not as windows of their
/// own: in full screen a window of its own took a Space of its own, and the owner was carried
/// away from the main window to see it.
@MainActor
final class WindowTabsTests: XCTestCase {
  typealias Host = WindowTabs.Host<Int>

  private func host(
    _ key: Int, visible: Bool = true, isKey: Bool = false, fullScreen: Bool = false
  ) -> Host {
    Host(key: key, isVisible: visible, isKey: isKey, isFullScreen: fullScreen)
  }

  func testTheWindowJoinsTheMainWindow() {
    XCTAssertEqual(WindowTabs.decide(tabbedWith: [], mains: [host(1)]), .join(1))
  }

  func testWithoutAMainWindowItOpensAlone() {
    XCTAssertEqual(WindowTabs.decide(tabbedWith: [], mains: [Host]()), .alone)
    XCTAssertEqual(
      WindowTabs.decide(tabbedWith: [], mains: [host(1, visible: false)]), .alone,
      "a main window closed or in the Dock is not a window to open in")
  }

  func testAMainWindowInFullScreenTakesTheTabInItsSpace() {
    XCTAssertEqual(WindowTabs.decide(tabbedWith: [], mains: [host(1, fullScreen: true)]), .join(1))
  }

  func testAWindowAlreadyAmongTheTabsStaysWhereItIs() {
    XCTAssertEqual(WindowTabs.decide(tabbedWith: [1, 7], mains: [host(1)]), .alreadyTabbed)
  }

  func testTheKeyMainWindowWinsOverTheFrontmostOne() {
    XCTAssertEqual(
      WindowTabs.decide(tabbedWith: [], mains: [host(1), host(2, isKey: true)]), .join(2))
    XCTAssertEqual(
      WindowTabs.decide(tabbedWith: [], mains: [host(1, visible: false), host(2), host(3)]),
      .join(2), "front to back, the first one that is on screen")
  }

  func testAWindowInFullScreenOfItsOwnIsLeftThere() {
    XCTAssertEqual(
      WindowTabs.decide(tabbedWith: [], mains: [host(1)], isFullScreen: true), .alone)
  }

  // MARK: - Real windows

  private var windows: [NSWindow] = []
  /// The windows the test host had on screen, put away for the test and shown again after it.
  private var putAway: [NSWindow] = []

  /// The test host may have a main window of its own on screen; a test of its own windows
  /// puts it away first, or the tab would go there.
  private func clearTheScreen() {
    putAway = NSApp.windows.filter(\.isVisible)
    for window in putAway { window.orderOut(nil) }
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    for window in putAway { window.orderFront(nil) }
    putAway = []
    try await Task.sleep(for: .milliseconds(100))
  }

  private func window<Content: View>(_ content: Content) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 760, height: 520),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: none — the content is a plain colour with the tab marker, it reads nothing.
    window.contentViewController = NSHostingController(rootView: content)
    windows.append(window)
    return window
  }

  /// A secondary window shown beside the main one becomes its tab by itself, and the Settings
  /// kind of window — anything without a marker — never does.
  func testASecondaryWindowShownBesideTheMainOneBecomesItsTab() throws {
    try TestEnvironment.requireScreen(width: 800)
    clearTheScreen()
    let main = window(Color.clear.windowTab(.main))
    main.orderFront(nil)
    let other = window(Color.clear)
    other.orderFront(nil)
    let secondary = window(Color.clear.windowTab(.secondary(scene: "analytics.test")))
    secondary.orderFront(nil)

    let deadline = Date().addingTimeInterval(5)
    while secondary.tabbedWindows?.contains(main) != true, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    XCTAssertTrue(
      secondary.tabbedWindows?.contains(main) == true, "the secondary window opened on its own")
    XCTAssertEqual(main.tabGroup?.selectedWindow, secondary, "the new tab is not the one shown")
    XCTAssertNil(other.tabbedWindows, "a window without a marker became a tab")

    // Opened again, it stays one tab of the group, not a second one.
    XCTAssertEqual(WindowTabs.join(secondary), .alreadyTabbed)
    XCTAssertEqual(main.tabbedWindows?.count, 2)
  }

  func testWithoutAMainWindowTheSecondaryOneOpensOnItsOwn() throws {
    try TestEnvironment.requireScreen(width: 800)
    clearTheScreen()
    let secondary = window(Color.clear.windowTab(.secondary(scene: "reports.test")))
    secondary.orderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    XCTAssertEqual(WindowTabs.join(secondary), .alone)
    XCTAssertNil(secondary.tabbedWindows)
  }
}
