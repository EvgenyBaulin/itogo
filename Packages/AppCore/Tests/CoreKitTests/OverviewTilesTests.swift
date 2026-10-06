import Foundation
import Testing

@testable import CoreKit

/// The tiles of Overview as the settings keep them: eighteen kinds to choose from, at most
/// twelve at once, the twelve of 1.2 in their order by default, and a stored line from anywhere —
/// another build, an archive of another Mac, a hand edit — that always reads as a choice the grid
/// can show.
@Suite("The tiles of Overview")
struct OverviewTilesTests {
  /// Eighteen kinds, in the order of the settings; the raw values are what is stored.
  @Test func eighteenKindsInTheOrderOfTheSettings() {
    #expect(
      OverviewTile.allCases.map(\.rawValue) == [
        "monthToDate", "topCategories", "qualities", "canSave", "spendingForecast",
        "incomeForecast", "balanceForecast", "limits", "upcoming", "expectedIncome", "owedToMe",
        "iOwe", "event", "lastCount", "lastRecord", "lastCountAndRecord", "worthALook",
        "freeMoney",
      ])
  }

  /// By default exactly the twelve cards Overview had, in their order: nothing moves for an owner
  /// who never opens the setting.
  @Test func standardIsTheTwelveCardsOfOnePointTwo() {
    #expect(
      OverviewTiles.standard == [
        .monthToDate, .topCategories, .qualities, .canSave, .spendingForecast, .limits, .upcoming,
        .expectedIncome, .owedToMe, .event, .lastCount, .worthALook,
      ])
    #expect(OverviewTiles.maximum == 12)
    #expect(OverviewTiles.standard.count == OverviewTiles.maximum)
    #expect(OverviewTiles.isStandard(OverviewTiles.standard))
  }

  /// Every choice written reads back as itself.
  @Test func encodeDecodeRoundTrip() {
    let chosen: [OverviewTile] = [.freeMoney, .lastCountAndRecord, .iOwe, .monthToDate]
    #expect(OverviewTiles.decode(OverviewTiles.encode(chosen)) == chosen)
    #expect(OverviewTiles.encode(chosen) == "freeMoney,lastCountAndRecord,iOwe,monthToDate")
    #expect(
      OverviewTiles.decode(OverviewTiles.encode(OverviewTiles.standard))
        == OverviewTiles.standard)
  }

  /// A word no build knows is skipped, a tile named twice keeps its first place, and nothing at
  /// all — no key, an empty text, only unknown words — is the standard choice.
  @Test func unknownAndRepeatedTilesAreSkipped() {
    #expect(
      OverviewTiles.decode("iOwe, tilesOfTomorrow ,limits,iOwe,,") == [.iOwe, .limits])
    #expect(OverviewTiles.decode(nil) == OverviewTiles.standard)
    #expect(OverviewTiles.decode("") == OverviewTiles.standard)
    #expect(OverviewTiles.decode("tilesOfTomorrow") == OverviewTiles.standard)
  }

  /// A stored line of more than twelve tiles keeps the first twelve: the grid never shows more.
  @Test func moreThanTwelveKeepsTheFirstTwelve() {
    let all = OverviewTiles.encode(OverviewTile.allCases)
    #expect(OverviewTiles.decode(all) == Array(OverviewTile.allCases.prefix(12)))
  }

  /// A thirteenth tile is refused, not put in place of another; a tile already shown is not added
  /// twice; switched on, a tile goes to the end.
  @Test func aThirteenthTileIsRefused() {
    let full = OverviewTiles.standard
    #expect(!OverviewTiles.canAdd(.freeMoney, to: full))
    #expect(OverviewTiles.adding(.freeMoney, to: full) == nil)
    let eleven = Array(full.dropLast())
    #expect(OverviewTiles.adding(.freeMoney, to: eleven) == eleven + [.freeMoney])
    #expect(OverviewTiles.adding(.limits, to: eleven) == nil)
  }

  /// A tile is switched off where it stands; the last one stays, so Overview is never left empty.
  @Test func theLastTileStays() {
    #expect(
      OverviewTiles.removing(.qualities, from: [.monthToDate, .qualities, .limits])
        == [.monthToDate, .limits])
    #expect(OverviewTiles.removing(.limits, from: [.limits]) == nil)
    #expect(!OverviewTiles.canRemove(.limits, from: [.limits]))
    #expect(OverviewTiles.removing(.iOwe, from: [.limits, .event]) == nil)
  }

  /// A drag moves the rows as a list moves them; indices outside the choice are passed over.
  @Test func dragMovesTheRows() {
    let tiles: [OverviewTile] = [.monthToDate, .limits, .event, .freeMoney]
    #expect(
      OverviewTiles.moving(tiles, from: IndexSet(integer: 3), to: 0)
        == [.freeMoney, .monthToDate, .limits, .event])
    #expect(
      OverviewTiles.moving(tiles, from: IndexSet(integer: 0), to: 4)
        == [.limits, .event, .freeMoney, .monthToDate])
    #expect(
      OverviewTiles.moving(tiles, from: IndexSet(integer: 1), to: 3)
        == [.monthToDate, .event, .limits, .freeMoney])
    #expect(OverviewTiles.moving(tiles, from: IndexSet(integer: 9), to: 0) == tiles)
  }
}
