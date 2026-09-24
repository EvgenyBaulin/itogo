import AppKit
import XCTest

@testable import Itogo

/// What the Mac running the tests can show decides which of them can run on it, and a test that
/// cannot run there says so instead of failing.
@MainActor
final class TestEnvironmentTests: XCTestCase {
  func testALayoutWiderThanAnyScreenSkips() {
    XCTAssertThrowsError(try TestEnvironment.requireScreen(width: 100_000)) { error in
      XCTAssertTrue(error is XCTSkip, "\(error)")
    }
  }

  func testALayoutThatFitsRuns() {
    XCTAssertNoThrow(try TestEnvironment.requireScreen(width: 320))
  }

  /// Only CI says it is CI, and it says so to the test host with `TEST_RUNNER_ITOGO_CI=1`.
  func testTheTreeOfSwiftUIIsAskedForEverywhereButOnCI() {
    let onCI = ProcessInfo.processInfo.environment["ITOGO_CI"] != nil
    XCTAssertEqual(TestEnvironment.isCI, onCI)
    if onCI {
      XCTAssertThrowsError(try TestEnvironment.requireSwiftUIAccessibility())
    } else {
      XCTAssertNoThrow(try TestEnvironment.requireSwiftUIAccessibility())
    }
  }
}
