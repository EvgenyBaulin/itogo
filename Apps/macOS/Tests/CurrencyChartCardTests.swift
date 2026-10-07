import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import Itogo

/// The tile «График валюты»: chosen in Settings in place of another — never as a thirteenth —,
/// and the card keeps the pair and the period it was left at on this Mac. No rate is asked here:
/// the environment is not started, so the card has no rate service and never reaches the bank.
@MainActor
final class CurrencyChartCardTests: XCTestCase {
  private var stored: Any?
  private var window: NSWindow?

  override func setUp() async throws {
    stored = UserDefaults.standard.object(forKey: CurrencyChartCard.storageKey)
  }

  override func tearDown() async throws {
    window?.contentView = nil
    window?.close()
    window = nil
    if let stored {
      UserDefaults.standard.set(stored, forKey: CurrencyChartCard.storageKey)
    } else {
      UserDefaults.standard.removeObject(forKey: CurrencyChartCard.storageKey)
    }
  }

  private func show() -> NSWindow {
    let environment = AppEnvironment()
    XCTAssertNil(environment.rateService, "a card under test never reaches the bank")
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(), compute: ComputeStore(calendar: .utc))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 360, height: 240), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = NSHostingView(rootView: CurrencyChartCard().appDependencies(deps))
    window.orderFront(nil)
    self.window = window
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    return window
  }

  func testTheTileTakesThePlaceOfAnotherButNeverOfAThirteenth() {
    let environment = AppEnvironment()
    XCTAssertEqual(environment.overviewTiles.count, 12)
    XCTAssertFalse(environment.overviewTiles.contains(.currencyChart))
    XCTAssertFalse(OverviewTilesActions.toggle(environment, .currencyChart), "no thirteenth")
    XCTAssertTrue(OverviewTilesActions.toggle(environment, .qualities))
    XCTAssertTrue(OverviewTilesActions.toggle(environment, .currencyChart))
    XCTAssertEqual(environment.overviewTiles.last, .currencyChart)
    XCTAssertEqual(AppEnvironment().overviewTiles.last, .currencyChart, "kept for the next launch")
  }

  /// The pair and the period chosen before are read back when the card appears — the card does
  /// not write USD/RUB and a month over them while it restores.
  func testThePairAndThePeriodAreKept() {
    UserDefaults.standard.set("EUR/RUB|year", forKey: CurrencyChartCard.storageKey)
    _ = show()
    XCTAssertEqual(
      UserDefaults.standard.string(forKey: CurrencyChartCard.storageKey), "EUR/RUB|year")
  }

  /// Nothing chosen yet: USD/RUB over a month.
  func testTheFirstChoiceIsADollarOverAMonth() {
    UserDefaults.standard.removeObject(forKey: CurrencyChartCard.storageKey)
    _ = show()
    XCTAssertEqual(
      UserDefaults.standard.string(forKey: CurrencyChartCard.storageKey), "USD/RUB|month")
  }

  /// The card shows the pair kept and says so when there is no rate to draw.
  func testTheCardShowsTheKeptPair() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    UserDefaults.standard.set("EUR/RUB|week", forKey: CurrencyChartCard.storageKey)
    let window = show()
    let picker = try XCTUnwrap(
      WindowAccessibility.element(identified: "overview.currencyChart.pair", in: window))
    let shown = WindowAccessibility.attribute(picker, "accessibilityValue").map { "\($0)" } ?? ""
    XCTAssertTrue(shown.contains("EUR/RUB"), shown)
    let texts = WindowAccessibility.elements(in: window).map(WindowAccessibility.text(of:))
    let environment = AppEnvironment()
    let noRates = environment.language("currencyChart.noRates", table: "Overview")
    XCTAssertTrue(texts.contains(noRates), "\(texts)")
  }
}
