import AppKit
import SwiftUI
import XCTest

@testable import Itogo

/// Analytics, Transactions and Reports beside the main window, with real windows: all three
/// become tabs of the one main window and leave its size as it was; a tab dragged out into a
/// window of its own comes back among the tabs when it is opened again (⌘⇧R).
@MainActor
final class WindowTabsReturnTests: XCTestCase {
  private var windows: [NSWindow] = []
  /// The windows the test host had on screen, put away for the test and shown again after it.
  private var putAway: [NSWindow] = []

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

  /// The test host may have a main window of its own on screen; it is put away first, or the
  /// tabs would go there.
  private func clearTheScreen() {
    putAway = NSApp.windows.filter(\.isVisible)
    for window in putAway { window.orderOut(nil) }
  }

  private func window<Content: View>(_ content: Content, width: CGFloat = 760) -> NSWindow {
    let window = NSWindow(
      contentRect: CGRect(x: 40, y: 40, width: width, height: 520),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    // dependencies: none — the content is a plain colour with the tab marker, it reads nothing.
    window.contentViewController = NSHostingController(rootView: content)
    windows.append(window)
    return window
  }

  private func waitUntil(_ condition: () -> Bool, seconds: TimeInterval = 5) {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition(), Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
  }

  /// ⌘⇧A, ⌘⇧T, ⌘⇧R one after another: three tabs beside the main window, in one group, and the
  /// main window keeps the size it had.
  func testThreeWindowsBecomeTabsOfTheMainWindowAndLeaveItsSize() throws {
    try TestEnvironment.requireScreen(width: 800)
    clearTheScreen()
    let main = window(Color.clear.windowTab(.main))
    main.orderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    let size = main.frame.size

    var tabs: [NSWindow] = []
    for scene in ["analytics.tabs", "transactions.tabs", "reports.tabs"] {
      // A secondary window opens at a size of its own, as the scenes do.
      let tab = window(Color.clear.windowTab(.secondary(scene: scene)), width: 900)
      tab.orderFront(nil)
      waitUntil { tab.tabbedWindows?.contains(main) == true }
      XCTAssertTrue(tab.tabbedWindows?.contains(main) == true, "\(scene) opened on its own")
      tabs.append(tab)
    }
    XCTAssertEqual(main.tabbedWindows?.count, 4, "the main window and three tabs")
    XCTAssertEqual(main.tabGroup?.selectedWindow, tabs.last, "the last opened is shown")
    // Every tab of a group shares one frame — the main window's.
    for tab in tabs {
      XCTAssertEqual(tab.frame.size, size, "a tab has a size of its own")
    }
    main.tabGroup?.selectedWindow = main
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    XCTAssertEqual(main.frame.size, size, "the main window changed its size")
  }

  /// «Отчёты» dragged out of the tabs is a window of its own; opened again it joins the main
  /// window's tabs and is the tab shown.
  func testATabDraggedOutComesBackWhenOpenedAgain() throws {
    try TestEnvironment.requireScreen(width: 800)
    clearTheScreen()
    let main = window(Color.clear.windowTab(.main))
    main.orderFront(nil)
    let reports = window(Color.clear.windowTab(.secondary(scene: "reports.dragged")))
    reports.orderFront(nil)
    waitUntil { reports.tabbedWindows?.contains(main) == true }
    XCTAssertTrue(reports.tabbedWindows?.contains(main) == true)

    // What a drag out of the tab bar does.
    main.tabGroup?.removeWindow(reports)
    reports.orderFront(nil)
    waitUntil { reports.tabbedWindows == nil }
    XCTAssertNil(reports.tabbedWindows, "the tab is a window of its own")
    XCTAssertTrue(reports.isVisible)

    // ⌘⇧R: `WindowTabs.open` joins a window open already but out of the tabs.
    XCTAssertEqual(WindowTabs.join(reports), .join(ObjectIdentifier(main)))
    waitUntil { reports.tabbedWindows?.contains(main) == true }
    XCTAssertTrue(reports.tabbedWindows?.contains(main) == true, "it came back among the tabs")
    XCTAssertEqual(main.tabGroup?.selectedWindow, reports)
  }
}
