import XCTest

@testable import Itogo

/// Work handed to the next turn of the main queue never runs inside the callback that asked
/// for it.
@MainActor
final class MainQueueTests: XCTestCase {
  func testTheWorkWaitsForTheNextTurnOfTheMainQueue() {
    var done = 0
    MainQueue.afterCallback { done += 1 }
    XCTAssertEqual(done, 0, "the work ran inside the callback")
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    XCTAssertEqual(done, 1)
  }

  func testEveryPieceOfWorkRunsOnceAndInOrder() {
    var order: [Int] = []
    for index in 0..<3 { MainQueue.afterCallback { order.append(index) } }
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    XCTAssertEqual(order, [0, 1, 2])
  }
}
