import AppKit
import XCTest

@testable import Itogo

/// A relaunch — the language switch, «Обновить и перезапустить», a restore or an import —
/// puts the database down, opens a new instance and quits. The owner must
/// never be left with no app and no word about it, nor with an app that waits for good.
@MainActor
final class AppRestartTests: XCTestCase {
  /// Everything the relaunch did, in order.
  private var done: [String] = []
  private var clock = ManualClock()

  override func setUp() async throws {
    try await super.setUp()
    done = []
    clock = ManualClock()
  }

  /// The steps of a relaunch that only write down what they were asked to do.
  private func steps(quits: XCTestExpectation) -> AppRestart.Steps {
    var steps = AppRestart.Steps()
    steps.stop = { [unowned self] in done.append("stop") }
    steps.open = { [unowned self] _ in done.append("open") }
    steps.tell = { [unowned self] in done.append("tell \($0.rawValue)") }
    steps.terminate = { [unowned self] in
      done.append("terminate")
      quits.fulfill()
    }
    steps.clock = clock.clock
    return steps
  }

  func testTheNewInstanceOpensAfterTheStopAndThenTheOldOneQuits() async {
    let quits = expectation(description: "the old instance quits")
    AppRestart.relaunch(using: steps(quits: quits))

    await fulfillment(of: [quits], timeout: 5)
    XCTAssertEqual(done, ["stop", "open", "terminate"])
  }

  /// `openApplication` failed and the old instance quit all the same: the owner was left with
  /// no app and nothing said why. Its database is closed by then and cannot be opened again,
  /// so it still quits — but says so first.
  func testANewInstanceThatDidNotOpenIsSaidBeforeTheOldOneQuits() async {
    let quits = expectation(description: "the old instance quits")
    var steps = steps(quits: quits)
    steps.open = { [unowned self] _ in
      done.append("open")
      throw CocoaError(.fileReadNoSuchFile)
    }
    AppRestart.relaunch(using: steps)

    await fulfillment(of: [quits], timeout: 5)
    XCTAssertEqual(done, ["stop", "open", "tell openFailed", "terminate"])
  }

  /// A stop that never ends held the relaunch for good: no new instance, no quit, the windows
  /// of a closing app on screen. Past the limit the relaunch gives up, says so and quits —
  /// and never opens a second instance beside a database still open.
  func testAStopThatHangsDoesNotHoldTheRelaunchForever() async {
    let gate = Gate()
    let quits = expectation(description: "the old instance quits")
    var steps = steps(quits: quits)
    steps.stop = { [unowned self] in
      done.append("stop")
      await gate.wait()
      done.append("stopped")
    }
    AppRestart.relaunch(using: steps)
    await Task.yield()
    clock.fire()

    await fulfillment(of: [quits], timeout: 2)
    XCTAssertTrue(done.contains("tell stopOverran"), "\(done)")
    XCTAssertFalse(done.contains("open"), "a new instance opened beside an open database")

    // The stop that ends late opens nothing either.
    gate.open()
    for _ in 0..<5 { await Task.yield() }
    XCTAssertFalse(done.contains("open"), "\(done)")
    XCTAssertEqual(done.filter { $0 == "terminate" }.count, 1)
  }

  /// «Перезапустить» pressed twice: one stop, one new instance.
  func testASecondRelaunchWhileTheFirstIsUnderWayDoesNothing() async {
    let gate = Gate()
    let quits = expectation(description: "the old instance quits")
    var steps = steps(quits: quits)
    steps.stop = { [unowned self] in
      done.append("stop")
      await gate.wait()
    }
    AppRestart.relaunch(using: steps)
    AppRestart.relaunch(using: steps)
    await Task.yield()
    gate.open()

    await fulfillment(of: [quits], timeout: 5)
    for _ in 0..<5 { await Task.yield() }
    XCTAssertEqual(done, ["stop", "open", "terminate"])
  }
}
