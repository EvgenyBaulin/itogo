import AppCore
import XCTest

@testable import Itogo

/// A tile dragged to another place in Settings → Appearance moves on Overview too: the grid lays
/// out the tiles of the setting in their order, row by row.
@MainActor
final class OverviewTilesOrderTests: XCTestCase {
  func testADraggedTileMovesOnOverview() {
    let environment = AppEnvironment()
    let before = environment.overviewTiles
    defer { environment.overviewTiles = before }
    environment.overviewTiles = [.monthToDate, .topCategories, .spendingForecast, .limits]
    XCTAssertEqual(
      OverviewCard.rows(environment.overviewTiles, columns: 3),
      [[.monthToDate, .topCategories, .spendingForecast], [.limits]])

    XCTAssertTrue(OverviewTilesActions.drop(environment, .limits, onto: .monthToDate))
    XCTAssertEqual(
      OverviewCard.rows(environment.overviewTiles, columns: 3),
      [[.limits, .monthToDate, .topCategories], [.spendingForecast]],
      "the grid follows the order the drag left")

    let language = environment.language.choice
    defer { environment.language.choice = language }
    environment.language.choice = .russian
    XCTAssertEqual(
      OverviewTileText.name(of: .spendingForecast, environment), "Прогноз расхода до конца месяца")
  }
}
