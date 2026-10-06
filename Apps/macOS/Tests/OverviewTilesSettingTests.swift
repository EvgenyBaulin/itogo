import AppCore
import AppDatabase
import XCTest

@testable import Itogo

/// Which tiles Overview shows, as the app keeps the choice: in `UserDefaults` beside the order of
/// the ↓ panel, read back by the next launch, carried by the archive and read from it as a choice
/// the grid can show. Settings switch tiles on and off — never a thirteenth, never the last one
/// off — and move them. The key is the owner's own: `AppDefaultsGuard` clears it before every
/// test and puts the owner's back afterwards.
@MainActor
final class OverviewTilesSettingTests: XCTestCase {
  private var directory: URL!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-overview-tiles-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private var stored: String? {
    UserDefaults.standard.string(forKey: AppEnvironment.overviewTilesKey)
  }

  /// Nothing chosen: the twelve cards of 1.2, and nothing written. A choice is written at once and
  /// a new launch reads it back.
  func testTheChoiceIsKeptAndReadBackByTheNextLaunch() {
    XCTAssertEqual(AppEnvironment.overviewTilesKey, "overview.tiles")
    let environment = AppEnvironment()
    XCTAssertEqual(environment.overviewTiles, OverviewTiles.standard)
    XCTAssertNil(stored)

    environment.overviewTiles = [.freeMoney, .monthToDate]
    XCTAssertEqual(stored, "freeMoney,monthToDate")
    XCTAssertEqual(AppEnvironment().overviewTiles, [.freeMoney, .monthToDate])
  }

  /// What another build wrote reads as a choice the grid can show.
  func testAStoredLineOfAnotherBuildReadsAsAChoice() {
    UserDefaults.standard.set("tilesOfTomorrow,iOwe,iOwe", forKey: AppEnvironment.overviewTilesKey)
    XCTAssertEqual(AppEnvironment().overviewTiles, [.iOwe])
    UserDefaults.standard.set("", forKey: AppEnvironment.overviewTilesKey)
    XCTAssertEqual(AppEnvironment().overviewTiles, OverviewTiles.standard)
  }

  /// A thirteenth tile is refused and the choice stays as it was; a tile below twelve goes to the
  /// end; the last tile cannot be switched off; «Сбросить» brings the twelve of 1.2 back.
  func testTheSettingsRefuseAThirteenthTileAndKeepTheLastOne() {
    let environment = AppEnvironment()
    XCTAssertFalse(OverviewTilesActions.canSwitch(environment, .freeMoney))
    XCTAssertFalse(OverviewTilesActions.toggle(environment, .freeMoney))
    XCTAssertEqual(environment.overviewTiles, OverviewTiles.standard)

    XCTAssertTrue(OverviewTilesActions.toggle(environment, .qualities))
    XCTAssertFalse(environment.overviewTiles.contains(.qualities))
    XCTAssertTrue(OverviewTilesActions.toggle(environment, .freeMoney))
    XCTAssertEqual(environment.overviewTiles.last, .freeMoney)
    XCTAssertEqual(environment.overviewTiles.count, 12)

    environment.overviewTiles = [.limits]
    XCTAssertFalse(OverviewTilesActions.canSwitch(environment, .limits))
    XCTAssertFalse(OverviewTilesActions.toggle(environment, .limits))
    XCTAssertEqual(environment.overviewTiles, [.limits])

    OverviewTilesActions.reset(environment)
    XCTAssertEqual(environment.overviewTiles, OverviewTiles.standard)
  }

  /// «Выше» and «Ниже» move a tile by one place; the first does not go up, the last not down.
  func testATileMovesByOnePlace() {
    let environment = AppEnvironment()
    environment.overviewTiles = [.monthToDate, .limits, .event]
    OverviewTilesActions.move(environment, .event, by: -1)
    XCTAssertEqual(environment.overviewTiles, [.monthToDate, .event, .limits])
    XCTAssertFalse(OverviewTilesActions.canMove(environment, .monthToDate, by: -1))
    XCTAssertFalse(OverviewTilesActions.canMove(environment, .limits, by: 1))
    OverviewTilesActions.move(environment, from: IndexSet(integer: 0), to: 3)
    XCTAssertEqual(environment.overviewTiles, [.event, .limits, .monthToDate])
  }

  /// The choice travels with the archive through the one funnel both the archive and the
  /// problem report read, and an archive's choice is kept as a choice the grid can show.
  func testTheChoiceTravelsWithTheArchive() throws {
    let environment = AppEnvironment()
    XCTAssertEqual(
      environment.portableSettings()[AppEnvironment.overviewTilesKey],
      OverviewTiles.encode(OverviewTiles.standard))
    environment.overviewTiles = [.iOwe, .lastRecord]
    XCTAssertEqual(
      environment.portableSettings()[AppEnvironment.overviewTilesKey], "iOwe,lastRecord")

    let stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")
    let archive = directory.appendingPathComponent("tiles.itogoarchive")
    _ = try service.exportArchive(
      to: archive, settings: [AppEnvironment.overviewTilesKey: "freeMoney,tilesOfTomorrow"])
    ArchiveImportFlow.applyPortableSettings(try service.openArchive(at: archive))
    XCTAssertEqual(stored, "freeMoney")
    XCTAssertEqual(AppEnvironment().overviewTiles, [.freeMoney])
  }

  /// The guard of the owner's defaults holds this key too.
  func testTheGuardHoldsTheTiles() throws {
    let suite = "itogo.tests.overview-tiles.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("iOwe", forKey: AppDefaultsGuard.overviewTilesKey)
    let guardian = AppDefaultsGuard(defaults: defaults, domain: suite)
    XCTAssertEqual(guardian.owner, AppDefaultsGuard.Snapshot(overviewTiles: "iOwe"))

    guardian.testCaseWillStart(self)
    XCTAssertNil(defaults.string(forKey: AppDefaultsGuard.overviewTilesKey))
    defaults.set("limits", forKey: AppDefaultsGuard.overviewTilesKey)
    guardian.testCaseDidFinish(self)
    XCTAssertEqual(defaults.string(forKey: AppDefaultsGuard.overviewTilesKey), "iOwe")
  }

  /// Every tile has a name in both languages: the settings list them by it, and the new tiles are
  /// titled by it.
  func testEveryTileIsNamedInBothLanguages() {
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      var names: Set<String> = []
      for tile in OverviewTile.allCases {
        let name = OverviewTileText.name(of: tile, environment)
        XCTAssertNotEqual(name, OverviewTileText.nameKey(of: tile), "\(tile), \(choice)")
        names.insert(name)
      }
      XCTAssertEqual(names.count, OverviewTile.allCases.count, "two tiles share a name")
      for key in OverviewTileText.keys {
        XCTAssertNotEqual(environment.language(key, table: "Overview"), key, "\(key), \(choice)")
      }
      for key in [
        "settings.tiles", "settings.tiles.hint", "settings.tiles.full", "settings.tiles.reset",
      ] {
        XCTAssertNotEqual(environment.language(key, table: "Settings"), key, "\(key), \(choice)")
      }
    }
    environment.language.choice = .russian
    XCTAssertEqual(OverviewTileText.name(of: .monthToDate, environment), "С начала месяца")
    XCTAssertEqual(OverviewTileText.name(of: .freeMoney, environment), "Свободные средства")
  }
}
