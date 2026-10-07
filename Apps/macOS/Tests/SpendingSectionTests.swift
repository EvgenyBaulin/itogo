import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import Itogo

/// «Траты» in the sidebar, under «Обзор»: ⌘4 and ↓ in the empty line over Overview open it, its
/// search finds words, categories and places through the whole history, and an amount in another
/// currency shows grey «≈ … ₽» — before Enter in the line, beside the row once written, and the
/// exact rubles once the owner typed the rate.
@MainActor
final class SpendingSectionTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var windows: [NSWindow] = []
  private var directory: URL!
  private var logs: URL!
  private var dataDirectoryBefore: String?
  private let today = DateOnly(year: 2026, month: 10, day: 7)

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["ITOGO_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-spending-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("ITOGO_DATA_DIR", directory.path, 1)
    logs = directory.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    compute = ComputeStore(calendar: .system, rebuildsInline: true)
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    Logbook.shared.close()
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("ITOGO_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("ITOGO_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: Helpers

  private func settle(_ passes: Int = 10) {
    for _ in 0..<passes { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  }

  private let cafe = CoreKit.Category(kind: .expense, name: "Кафе", quality: .neutral)
  private let shop = CoreKit.Category(kind: .expense, name: "Продукты", quality: .neutral)
  private let place = Place(name: "Кофейня у дома")

  private func entry(
    _ note: String, daysAgo: Int, category: CoreKit.Category? = nil, placeId: UUID? = nil,
    on base: DateOnly? = nil
  ) throws -> TransactionEntry {
    let calendar = CalendarContext.system
    let day = calendar.adding(days: -daysAgo, to: base ?? calendar.day(of: Date()))
    var draft = TransactionDraft(
      occurredAt: calendar.startOfDay(day).addingTimeInterval(12 * 3600),
      amount: AmountE4(whole: 100), note: note)
    draft.placeId = placeId
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = (category ?? shop).id
    return try draft.materialize()
  }

  private func snapshot(
    _ entries: [TransactionEntry], context: SnapshotContext = SnapshotContext()
  ) -> DataSnapshot {
    DataSnapshot.build(
      dataset: Dataset(entries: entries, categories: [cafe, shop], places: [place]),
      calendar: .system, today: environment.today, context: context,
      version: DataVersion(load: 0))
  }

  private func mainWindow(actions: OperationActions = OperationActions()) -> NSWindow {
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let root = AppScenes.root(deps, window: .main, launches: false) { deps in
      MainWindow(deps: deps, actions: actions, opensDetails: false)
    }
    .environment(\.windowWidth, 980)
    let controller = NSHostingController(rootView: root)
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 980, height: 680),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.orderFront(nil)
    windows.append(window)
    settle(20)
    return window
  }

  private func shown(_ section: String) -> Bool {
    Logbook.shared.lines().contains {
      $0.contains(" section.shown ") && $0.hasSuffix(" window=main section=\(section)")
    }
  }

  private static func russian(_ key: String, table: String = "Common") -> String {
    Bundle.main.path(forResource: "ru", ofType: "lproj").flatMap(Bundle.init(path:))?
      .localizedString(forKey: key, value: nil, table: table) ?? key
  }

  // MARK: The sidebar

  /// «Траты» stands right under «Обзор»; Overview lists no operations under its cards any more —
  /// it floats no selection bar — and «Траты» does.
  func testSpendingStandsUnderOverviewAndOverviewKeepsTheCardsAlone() {
    XCTAssertEqual(MainWindow.Section.allCases, [.overview, .spending, .planning, .debts])
    XCTAssertEqual(Self.russian(MainWindow.Section.spending.titleKey), "Траты")
    XCTAssertEqual(MainWindow.Section.spending.shortcutIndex, 4)
    XCTAssertFalse(SidebarItem.section(.overview).listsOperations)
    XCTAssertTrue(SidebarItem.section(.spending).listsOperations)
    XCTAssertEqual(
      Self.russian("spending.search.prompt", table: "Overview"),
      "Поиск по словам, категории или месту")
  }

  /// ⌘4 is an item of the menu bar, and what it posts brings «Траты» on screen.
  func testCommandFourOpensSpending() throws {
    func items(_ menu: NSMenu?) -> [NSMenuItem] {
      (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
    }
    let four = items(NSApp.mainMenu).filter {
      $0.keyEquivalent == "4"
        && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
    }
    XCTAssertEqual(four.count, 1, "⌘4: \(four.map(\.title))")
    XCTAssertTrue(
      [Self.russian("section.spending"), "Spending"].contains(four.first?.title ?? ""),
      "⌘4 is «\(four.first?.title ?? "")»")

    compute.applyLight(snapshot([try entry("кофе", daysAgo: 0)]))
    _ = mainWindow()
    XCTAssertTrue(shown("overview"))
    NotificationCenter.default.post(name: .selectSection, object: 4)
    settle()
    XCTAssertTrue(shown("spending"), "⌘4 did not bring «Траты»")
  }

  /// ↓ in the empty line over Overview: «Траты» opens and its newest row is selected.
  func testDownInTheLineOverOverviewOpensSpendingOnTheNewestRow() throws {
    let newest = try entry("новая", daysAgo: 0)
    compute.applyLight(snapshot([try entry("старая", daysAgo: 3), newest]))
    let actions = OperationActions()
    _ = mainWindow(actions: actions)
    XCTAssertTrue(shown("overview"))
    NotificationCenter.default.post(name: .walkOperationsList, object: nil)
    settle(20)
    XCTAssertTrue(shown("spending"), "↓ over Overview did not open «Траты»")
    XCTAssertEqual(actions.selection, [newest.id], "the newest row is not the one selected")
  }

  // MARK: The search

  /// Every word somewhere in the description, the category or the place, case and «ё» aside.
  func testTheSearchReadsWordsCategoriesAndPlaces() throws {
    let names = SpendingSearch.Names(
      categories: [cafe.id: cafe.name, shop.id: shop.name], places: [place.id: place.name])
    let byNote = try entry("Кофе с собой", daysAgo: 0)
    let byCategory = try entry("латте", daysAgo: 0, category: cafe)
    let byPlace = try entry("булка", daysAgo: 0, placeId: place.id)
    let other = try entry("хлеб", daysAgo: 0)
    for found in [byNote, byPlace] {
      XCTAssertTrue(SpendingSearch.matches(found, query: "кофе", names: names))
    }
    XCTAssertTrue(SpendingSearch.matches(byCategory, query: "КАФЕ", names: names))
    XCTAssertFalse(SpendingSearch.matches(other, query: "кофе", names: names))
    XCTAssertTrue(SpendingSearch.matches(byPlace, query: "булка дома", names: names))
    XCTAssertFalse(SpendingSearch.matches(byPlace, query: "булка кафе", names: names))
    let yo = try entry("Ёлка", daysAgo: 0)
    XCTAssertTrue(SpendingSearch.matches(yo, query: "елка", names: names))
  }

  /// Without a search the list is the last two months; the search looks through everything —
  /// a coffee of four months ago is found — and cleared, the list is the two months again.
  func testTheSearchLooksThroughTheWholeHistory() throws {
    let old = try entry("кофе давний", daysAgo: 120)
    let recent = try entry("кофе", daysAgo: 1)
    let bread = try entry("хлеб", daysAgo: 2)
    let data = snapshot([old, recent, bread])
    func ids(_ search: String) -> Set<UUID> {
      Set(
        SpendingView.groups(of: data, search: search, calendar: .system).flatMap(\.selectableIds))
    }
    XCTAssertEqual(ids(""), [recent.id, bread.id])
    XCTAssertEqual(ids("кофе"), [old.id, recent.id])
    XCTAssertEqual(ids("  "), [recent.id, bread.id], "a cleared search is no search")
  }

  // MARK: «≈»

  private func context(usd: Decimal, on day: DateOnly) -> SnapshotContext {
    var context = SnapshotContext()
    context.rubPerUnit[.usd] = usd
    context.rateDays[.usd] = day
    return context
  }

  /// «кофе 5 usd» before Enter: «≈ 475.00 ₽» at the bank's last rate, with its day when it is
  /// not today's.
  func testTheLineShowsTheApproximateRublesBeforeEnter() {
    compute.applyLight(snapshot([], context: context(usd: 95, on: environment.today)))
    let rubles = environment.money.exact(AmountE4(whole: 475), currency: .rub)
    XCTAssertEqual(
      ApproximateText.of(
        amount: AmountE4(whole: 5), currency: .usd, environment: environment, compute: compute),
      "≈ " + rubles)

    let earlier = environment.calendar.adding(days: -2, to: environment.today)
    compute.applyLight(snapshot([], context: context(usd: 95, on: earlier)))
    let text = ApproximateText.of(
      amount: AmountE4(whole: 5), currency: .usd, environment: environment, compute: compute)
    XCTAssertEqual(
      text,
      "≈ " + rubles + " · "
        + environment.language.format(
          "approximate.rateOf", table: "Transactions", environment.dates.dayAndMonth(earlier)))
    XCTAssertNil(
      ApproximateText.of(
        amount: AmountE4(whole: 500), currency: .rub, environment: environment, compute: compute),
      "rubles need no «≈»")
  }

  /// The row of a dollar expense at the bank's rate: grey «≈ … ₽», «курс от …» when the rate is
  /// of another day; the rate typed by hand: the exact «= 500.00 ₽», no «≈».
  func testTheRowShowsApproximateRublesUntilTheRateIsTyped() throws {
    compute.applyLight(snapshot([]))
    var dollars = Transaction(
      kind: .expense, occurredAt: environment.calendar.startOfDay(environment.today),
      currency: .usd, amountE4: AmountE4(whole: 5), amountRubE4: AmountE4(whole: 475))
    dollars.rate = 95
    dollars.rateSource = .cbr
    dollars.rateDate = environment.today
    let rubles = environment.money.exact(AmountE4(whole: 475), currency: .rub)
    XCTAssertEqual(
      ApproximateText.of(dollars, environment: environment, compute: compute), "≈ " + rubles)

    let friday = environment.calendar.adding(days: -3, to: environment.today)
    dollars.rateDate = friday
    XCTAssertEqual(
      ApproximateText.of(dollars, environment: environment, compute: compute),
      "≈ " + rubles + " · "
        + environment.language.format(
          "approximate.rateOf", table: "Transactions", environment.dates.dayAndMonth(friday)))
    XCTAssertTrue(Self.russian("approximate.rateOf", table: "Transactions").contains("курс от"))

    // The editor: «100» typed into «Курс» — the rate is the owner's, the rubles exact.
    let model = EntryDraftModel(environment: environment)
    model.reload()
    model.draft.currency = .usd
    model.draft.amount = AmountE4(whole: 5)
    model.draft.note = "кофе"
    model.draft.normalizeSinglePart()
    model.setManualRate("100")
    let typed = try model.draftForSaving.materialize(
      rublesConverter: environment.rublesConverter(for: model.draft)
    ).transaction
    XCTAssertEqual(typed.rateSource, .manual)
    XCTAssertEqual(typed.amountRubE4, AmountE4(whole: 500))
    XCTAssertEqual(
      ApproximateText.of(typed, environment: environment, compute: compute),
      "= " + environment.money.exact(AmountE4(whole: 500), currency: .rub))
  }
}
