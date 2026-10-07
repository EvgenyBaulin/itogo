import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import Itogo

/// The window of Transactions must settle after a double click.
///
/// On 19.09 it did not: the owner double-clicked a row, the window hung for eight seconds and
/// the app died on an `NSGenericException` — «has already had more Update Constraints in
/// Window passes than there are views in the window». The repeating stack was
/// `NSHostingView.SizeConstraints.update` →
/// `SplitViewChildController.hostingView(_:didUpdateMinSize:maxSize:)` →
/// `AppKitPlatformViewHost.enqueueLayoutInvalidation` → the parent's `setNeedsUpdateConstraints`:
/// a column of the split kept reporting a new minimum on every pass, so the window never
/// converged. The number of views in the window alternated between 358 and 612 from pass to
/// pass, so a whole column's worth of views was being added and removed.
///
/// So the test opens the real window on real data, asks for the same edit the double click
/// asks for, then drives the layout by hand and watches the split: the thicknesses, the
/// collapsed flags and the number of views must stop changing, and the log must stay quiet.
/// A watchdog ends the process rather than let it hang: the failure must arrive in seconds.
///
/// Some of these tests take the app's activity away and give it back (`NSApp.deactivate()` and
/// `NSApp.activate()`), which is what reproduces the loop. On a machine somebody is using, the
/// focus blinks for a moment while they run; that is the test, not a bug.
@MainActor
final class TransactionsLayoutTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var actions: OperationActions!
  private var directory: URL!
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var windows: [NSWindow] = []
  private var missingReadersBefore: Set<String> = []
  private var dataDirectoryBefore: String?

  /// The synthetic history the window shows.
  private var plain: TransactionEntry!
  private var split: TransactionEntry!
  private var crowdedDay: [TransactionEntry] = []
  private var everything: [TransactionEntry]!
  private let food = CoreKit.Category(kind: .expense, name: "Food")
  private let salary = CoreKit.Category(kind: .income, name: "Salary")

  override func setUp() async throws {
    missingReadersBefore = AppDependencies.missingReaders
    AppDependencies.missingReaders = []
    dataDirectoryBefore = ProcessInfo.processInfo.environment["ITOGO_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-layout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("ITOGO_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    compute = ComputeStore(calendar: .system, rebuildsInline: true)
    // Without this the window has rows but the store has no listing, and `edit` — the very
    // call a double click makes — would return before it opened anything (AppLaunch does the
    // same wiring).
    compute.onSnapshot = { [store] snapshot in store?.show(snapshot.ledger) }
    // The columns of the table are a setting of the window; the owner's own must not move.
    suiteName = "itogo-layout-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    seed()
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    defaults?.removePersistentDomain(forName: suiteName)
    if let dataDirectoryBefore {
      setenv("ITOGO_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("ITOGO_DATA_DIR")
    }
    AppDependencies.missingReaders = missingReadersBefore
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: - The history

  /// Rows around today, because the window opens on this month: a plain operation, a split of
  /// two parts, a day of three operations and enough rows to fill the table.
  private func seed() {
    plain = entry(.expense, [1_250], daysAgo: 0, hour: 12, note: "Coffee and a bun")
    split = entry(.expense, [2_500, 250], daysAgo: 1, hour: 19, note: "Dinner for two")
    crowdedDay = [
      entry(.expense, [430], daysAgo: 2, hour: 9, note: "Bus"),
      entry(.expense, [1_900], daysAgo: 2, hour: 14, note: "Bookshop"),
      entry(.income, [60_000], daysAgo: 2, hour: 18, note: "Salary"),
    ]
    let filler = (3..<40).map { day in
      entry(.expense, [Int64(200 + day * 7)], daysAgo: day % 27, hour: 8, note: "Row \(day)")
    }
    everything = [plain, split] + crowdedDay + filler
    show(everything, version: 0)
  }

  private func show(_ entries: [TransactionEntry], version: Int) {
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(entries: entries, categories: [food, salary]), calendar: .system,
        today: environment.today, context: SnapshotContext(),
        version: DataVersion(load: version)))
  }

  private func entry(
    _ kind: TransactionKind, _ amounts: [Int64], daysAgo: Int, hour: Int, note: String
  ) -> TransactionEntry {
    let id = UUID()
    let day = CalendarContext.system.day(
      of: Date().addingTimeInterval(TimeInterval(-86_400 * daysAgo)))
    let when = CalendarContext.system.startOfDay(day).addingTimeInterval(TimeInterval(hour * 3_600))
    let parts = amounts.map {
      TransactionPart(
        transactionId: id, categoryId: kind == .income ? salary.id : food.id,
        quality: kind.hasQuality ? .neutral : nil,
        qualitySource: kind.hasQuality ? .category : nil, amountE4: AmountE4(whole: $0))
    }
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: kind, occurredAt: when, amountE4: AmountE4(whole: amounts.reduce(0, +)),
        note: note, createdAt: when, updatedAt: when),
      parts: parts)
  }

  // MARK: - The window

  private func makeWindow(
    width: CGFloat = 1120, height: CGFloat = 720, editing: TransactionEditorModel? = nil
  ) -> NSWindow {
    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    let actions = OperationActions()
    self.actions = actions
    let root =
      AppScenes.root(deps, window: .transactions, launches: false) { deps in
        SecondaryWindow(titleKey: "window.transactions") {
          TransactionsRootView(deps: deps, actions: actions, editing: editing)
        }
      }
      .defaultAppStorage(defaults)
    let controller = NSHostingController(rootView: root)
    controller.sceneBridgingOptions = [.toolbars]
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: height),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setContentSize(CGSize(width: width, height: height))
    window.toolbarStyle = .unified
    window.orderFront(nil)
    windows.append(window)
    return window
  }

  /// Runs the loop until the table has rows, or gives up and says so.
  private func waitForTable(_ window: NSWindow, timeout: TimeInterval = 5) throws {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      window.layoutIfNeeded()
      if let table = Self.table(in: window), table.numberOfRows > 0, actions.opensEditor != nil {
        return
      }
    } while Date() < deadline
    XCTFail("the table never filled: rows \(Self.table(in: window)?.numberOfRows ?? -1)")
    throw XCTSkip("no table, nothing to click")
  }

  private static func table(in window: NSWindow) -> NSTableView? {
    guard let root = window.contentView else { return nil }
    return firstSubview(of: root)
  }

  private static func firstSubview<V: NSView>(of view: NSView) -> V? {
    if let found = view as? V { return found }
    for subview in view.subviews {
      if let found: V = firstSubview(of: subview) { return found }
    }
    return nil
  }

  private static func allSubviews<V: NSView>(of view: NSView, into found: inout [V]) {
    if let match = view as? V { found.append(match) }
    for subview in view.subviews { allSubviews(of: subview, into: &found) }
  }

  private static func viewCount(of view: NSView) -> Int {
    1 + view.subviews.reduce(0) { $0 + viewCount(of: $1) }
  }

  // MARK: - What the layout is doing

  /// What the split views of the window look like on one pass. Everything that made the
  /// window loop is in here: the minimum and maximum a column reports, whether it is
  /// collapsed, how wide it is, and how many views the window holds.
  private struct LayoutRecord: Equatable, CustomStringConvertible {
    var items: [String]
    var views: Int

    var description: String { "views \(views); " + items.joined(separator: " | ") }
  }

  private func record(_ window: NSWindow) -> LayoutRecord {
    guard let frame = window.contentView?.superview ?? window.contentView else {
      return LayoutRecord(items: [], views: 0)
    }
    var splits: [NSSplitView] = []
    Self.allSubviews(of: frame, into: &splits)
    var items: [String] = []
    for (index, split) in splits.enumerated() {
      let widths = split.arrangedSubviews.map { String(format: "%.1f", $0.frame.width) }
      items.append("split\(index) [\(widths.joined(separator: ", "))]")
      guard let controller = split.delegate as? NSSplitViewController else { continue }
      for (itemIndex, item) in controller.splitViewItems.enumerated() {
        items.append(
          "split\(index).item\(itemIndex) "
            + "behavior \(item.behavior.rawValue) "
            + "min \(String(format: "%.1f", item.minimumThickness)) "
            + "max \(String(format: "%.1f", item.maximumThickness)) "
            + "collapsed \(item.isCollapsed) "
            + "holding \(String(format: "%.0f", item.holdingPriority.rawValue))")
      }
    }
    return LayoutRecord(items: items, views: Self.viewCount(of: frame))
  }

  /// Drives the layout by hand and records what the split does on every pass.
  @discardableResult
  private func settle(_ window: NSWindow, passes: Int = 30, _ what: String) -> [LayoutRecord] {
    var records: [LayoutRecord] = []
    for _ in 0..<passes {
      window.updateConstraintsIfNeeded()
      window.layoutIfNeeded()
      window.displayIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      let record = record(window)
      // Printed as it goes: when the window takes the process down with it, the build log
      // still holds every pass up to that point.
      print("layout \(what) pass \(records.count): \(record); bar \(actions?.barFrame ?? .zero)")
      fflush(stdout)
      records.append(record)
      // Ten identical passes are all `assertSettled` needs: the rest would only spend seconds
      // of every run proving the same thing again.
      if records.count >= 10, records.suffix(10).allSatisfy({ $0 == record }) { break }
    }
    return records
  }

  private func assertSettled(
    _ records: [LayoutRecord], _ window: NSWindow, _ what: String,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let tail = records.suffix(10)
    let settled = tail.allSatisfy { $0 == tail.first }
    XCTAssertTrue(
      settled,
      "the window never settled \(what): "
        + Set(tail.map(\.description)).sorted().joined(separator: "  ≠  "),
      file: file, line: line)
    XCTAssertFalse(
      window.contentView?.needsLayout ?? false, "layout still dirty \(what)", file: file,
      line: line)
    XCTAssertFalse(
      window.contentView?.needsUpdateConstraints ?? false, "constraints still dirty \(what)",
      file: file, line: line)
  }

  /// Ends the process if the body outlives its bound: a layout loop must fail in seconds, not
  /// hang for the whole allowance of the test.
  /// The flag the watchdog reads on another thread, behind its own lock.
  /// The watchdog's side of a step. The queue that notices the overrun can only leave a
  /// complaint; failing the test is the main thread's to do. `XCTFail` is not usable off the
  /// main queue, and `abort()` — what stood here — took the whole process down with every
  /// other test in it and no attribution at all.
  private final class Watch: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var complaint: String?
    func finish() {
      lock.lock()
      finished = true
      lock.unlock()
    }
    /// Records the complaint unless the step has finished in the meantime. Under the one
    /// lock, so a step that finishes just as the watch fires cannot be failed for it.
    func complainIfRunning(_ text: String) {
      lock.lock()
      if !finished { complaint = text }
      lock.unlock()
    }
    var complaintIfAny: String? {
      lock.lock()
      defer { lock.unlock() }
      return complaint
    }
  }

  private func watched<T>(
    _ seconds: TimeInterval, _ what: String, file: StaticString = #filePath, line: UInt = #line,
    _ body: () -> T
  ) -> T {
    let watch = Watch()
    let since = Date()
    let messages = loopMessages
    // Only the flag is set here, never the report: reading the log takes long enough that
    // the step can finish first, and then the complaint would land after the main thread had
    // already looked for it. The report is read below, where there is time for it.
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
      watch.complainIfRunning("layout watchdog: \(what) did not finish in \(seconds) s")
    }
    let value = body()
    watch.finish()
    // A step that ran long is a failure, not a killed process: `abort()` — what stood here —
    // took every other test in the run down with it and named none of them. The log report is
    // the valuable part, so it is gathered now and said out loud.
    if let complaint = watch.complaintIfAny {
      let report = LogProbe.report(of: messages, since: since)
      XCTFail("\(complaint); the log says \(report)", file: file, line: line)
    }
    return value
  }

  private var loopMessages: [String] {
    [
      LogProbe.Message.layoutLoop, LogProbe.Message.updateConstraints,
      LogProbe.Message.reentrantTable, LogProbe.Message.invalidGeometry,
      LogProbe.Message.stateDuringUpdate,
    ]
  }

  // MARK: - A double click, the way the window makes it

  /// The call the table's `primaryAction` makes, through the same actions object the window
  /// holds. A part of a split maps to its operation first, as `owners(of:)` does.
  private func doubleClick(_ entry: TransactionEntry, _ what: String) {
    watched(30, "double click \(what)") {
      actions.edit([entry.id], store: store)
    }
  }

  func testADoubleClickOnAPlainOperationLeavesTheWindowSettled() throws {
    let opening = LogProbe()
    let window = makeWindow()
    try waitForTable(window)
    settle(window, passes: 5, "before the click")
    print("layout opening messages: \(opening.seen(of: loopMessages))")

    // Counted from this moment, so what the probe sees belongs to the click, not the opening.
    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    doubleClick(plain, "plain operation")
    let records = settle(window, "after a double click on a plain operation")

    assertSettled(records, window, "after a double click on a plain operation")
    XCTAssertTrue(inspectorIsOpen(window), "the inspector did not open")
    XCTAssertNil(actions.editing, "the sheet opened instead of the inspector")
    probe.assertQuiet(
      about: loopMessages, comparedWith: before, "after a double click on a plain operation")
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }

  func testADoubleClickOnAnotherOperationWhileTheInspectorIsOpenLeavesTheWindowSettled() throws {
    let opening = LogProbe()
    let window = makeWindow()
    try waitForTable(window)
    doubleClick(plain, "plain operation")
    settle(window, passes: 10, "with the inspector open")
    print("layout opening messages: \(opening.seen(of: loopMessages))")

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    doubleClick(split, "split, inspector open")
    let records = settle(window, "after a double click on a split")

    assertSettled(records, window, "after a double click on a split")
    probe.assertQuiet(about: loopMessages, comparedWith: before, "after a double click on a split")
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }

  // MARK: - The triggers the log points at

  /// The loop of 19.09 started about twelve seconds after the last click, with nothing but
  /// RunningBoard between: new data landing, a change of the key window or of the app's
  /// activity are the candidates.
  func testNewDataWhileTheInspectorIsOpenLeavesTheWindowSettled() throws {
    let window = makeWindow()
    try waitForTable(window)
    doubleClick(plain, "plain operation")
    settle(window, passes: 10, "with the inspector open")

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    watched(30, "new data") {
      show(changedPlain(), version: 1)
      // The window refilters 150 ms after the change, off the main thread.
      for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let records = settle(window, passes: 40, "after new data with the inspector open")

    assertSettled(records, window, "after new data with the inspector open")
    probe.assertQuiet(
      about: loopMessages, comparedWith: before, "after new data with the inspector open")
  }

  func testAChangeOfTheKeyWindowWithTheInspectorOpenLeavesTheWindowSettled() throws {
    let window = makeWindow()
    try waitForTable(window)
    doubleClick(plain, "plain operation")
    settle(window, passes: 10, "with the inspector open")

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    let other = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    other.isReleasedWhenClosed = false
    windows.append(other)
    watched(30, "key window") {
      other.makeKeyAndOrderFront(nil)
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
      window.makeKeyAndOrderFront(nil)
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let records = settle(window, passes: 40, "after the key window changed")

    assertSettled(records, window, "after the key window changed")
    probe.assertQuiet(about: loopMessages, comparedWith: before, "after the key window changed")
  }

  func testLosingAndRegainingActivityWithTheInspectorOpenLeavesTheWindowSettled() throws {
    let window = makeWindow()
    try waitForTable(window)
    actions.selection = [plain.id]
    doubleClick(plain, "plain operation")
    settle(window, passes: 10, "with the inspector and the bar open")

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    print("layout activity before: \(NSApp.isActive)")
    watched(30, "activity") {
      NSApp.deactivate()
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
      NSApp.activate()
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    print("layout activity after: \(NSApp.isActive)")
    let records = settle(window, passes: 40, "after the app lost and regained activity")

    assertSettled(records, window, "after the app lost and regained activity")
    probe.assertQuiet(
      about: loopMessages, comparedWith: before, "after the app lost and regained activity")
  }

  /// The smallest window the root allows: with the inspector open the sidebar, the table and
  /// the inspector all want their minimum at once.
  func testADoubleClickInTheSmallestWindowLeavesItSettled() throws {
    let window = makeWindow(width: 820, height: 480)
    try waitForTable(window)
    settle(window, passes: 5, "before the click, 820 pt")

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    doubleClick(plain, "plain operation in a narrow window")
    let records = settle(window, passes: 40, "after a double click at 820 pt")

    assertSettled(records, window, "after a double click at 820 pt")
    probe.assertQuiet(about: loopMessages, comparedWith: before, "after a double click at 820 pt")
  }

  /// 820 pt is as narrow as this window goes, and the inspector has to fit in it. Before this
  /// the root asked for 1100 pt while the inspector was open, so the window grew — and AppKit
  /// never shrinks a window back, so one double click left Transactions at least 1100 pt wide
  /// for the rest of its life. On a screen that cannot give 1100 pt, SwiftUI folded the
  /// inspector away again right after opening it.
  func testTheInspectorFitsTheSmallestWindowWithoutWideningIt() throws {
    let window = makeWindow(width: 820, height: 480)
    try waitForTable(window)
    settle(window, passes: 5, "before the click, 820 pt")
    XCTAssertEqual(window.frame.width, 820, accuracy: 1)

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    doubleClick(plain, "plain operation in a narrow window")
    let records = settle(window, passes: 40, "with the inspector at 820 pt")

    XCTAssertTrue(inspectorIsOpen(window), "the inspector folded away in the smallest window")
    XCTAssertEqual(
      window.frame.width, 820, accuracy: 1,
      "the window grew to make room for the inspector and will never shrink back")
    XCTAssertTrue(
      sidebarIsCollapsed(window), "the sidebar kept its room and the window had to grow")
    assertSettled(records, window, "with the inspector at 820 pt")
    probe.assertQuiet(about: loopMessages, comparedWith: before, "with the inspector at 820 pt")
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }

  /// What a double click really is: the table selects the row **and** asks for the edit. The
  /// bar slides in at the same moment the inspector column is added, and the inspector with
  /// the bar is the only combination that loops. Every test above this one asked for the edit
  /// alone, so the bar was never on screen and half the gesture was never tested.
  func testADoubleClickThatAlsoSelectsTheRowLeavesTheWindowSettled() throws {
    let window = makeWindow()
    try waitForTable(window)
    settle(window, passes: 5, "before the click that also selects")

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    watched(30, "select and open in one turn") {
      actions.selection = [plain.id]
      actions.edit([plain.id], store: store)
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let records = settle(window, passes: 60, "after a double click that selected the row")

    assertSettled(records, window, "after a double click that selected the row")
    probe.assertQuiet(
      about: loopMessages, comparedWith: before,
      "after a double click that selected the row")
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }

  /// The same gesture in Russian, in the window of the default size. On 23.09 the app died on
  /// it — «--present inspector,selection» on the sample set, the window at 1120 pt: the bar and
  /// the inspector fit in English and not in Russian, where every word of the bar is longer,
  /// and the window asked for one Update Constraints pass after another until AppKit threw.
  /// The English test above never saw it: the test host speaks English unless told otherwise.
  func testADoubleClickThatAlsoSelectsTheRowSettlesInRussian() throws {
    try TestEnvironment.requireScreen(width: 1_120)
    environment.language.choice = .russian
    let window = makeWindow()
    try waitForTable(window)
    settle(window, passes: 5, "before the click that also selects, in Russian")

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    watched(30, "select and open in one turn, in Russian") {
      actions.selection = [plain.id]
      actions.edit([plain.id], store: store)
      // Recorded on every turn: the window died inside this very loop before the fix, and
      // the passes printed up to that point are what showed the inspector growing past
      // its ideal while the bar wanted the room.
      for pass in 0..<10 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        print("layout during the gesture, in Russian pass \(pass): \(record(window))")
      }
    }
    let records = settle(
      window, passes: 60, "after a double click that selected the row, in Russian")

    XCTAssertEqual(
      window.frame.width, 1120, accuracy: 1,
      "the window grew to make room for the inspector and will never shrink back")
    assertSettled(records, window, "after a double click that selected the row, in Russian")
    probe.assertQuiet(
      about: loopMessages, comparedWith: before,
      "after a double click that selected the row, in Russian")
  }

  /// The same gesture where the sidebar has to give way at the very moment the bar slides in.
  func testADoubleClickThatAlsoSelectsTheRowInANarrowWindowSettles() throws {
    let window = makeWindow(width: 900, height: 600)
    try waitForTable(window)
    settle(window, passes: 5, "before the click that also selects, 900 pt")

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    watched(30, "select and open in one turn at 900 pt") {
      actions.selection = [plain.id]
      actions.edit([plain.id], store: store)
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let records = settle(window, passes: 60, "after a double click that selected the row, 900 pt")

    XCTAssertEqual(
      window.frame.width, 900, accuracy: 1,
      "the window grew to make room for the inspector and will never shrink back")
    assertSettled(records, window, "after a double click that selected the row, 900 pt")
    probe.assertQuiet(
      about: loopMessages, comparedWith: before,
      "after a double click that selected the row, 900 pt")
    // The sidebar folded away for the inspector: every column is a host of its own, and each
    // must still have been handed the dependencies. The red badge of 23.09 stood on exactly
    // this window, naming DayList, TransactionEditor and TransactionsTable.
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }

  /// Where the bar is, is measured inside the very column the popovers hang on. Whoever reads
  /// it is laid out again every time the bar moves, and the bar moves on every frame of its
  /// entrance — a size taken off the screen coming back into the layout of its own branch,
  /// which is the loop the bar's measured height once made through `@State`, with one more hop
  /// through an object.
  func testWhereTheBarIsDrawsNothingAgain() {
    let actions = OperationActions()
    // `onChange` is called off this actor, so the answer travels in a box both sides may hold.
    let fired = Fired()
    withObservationTracking {
      _ = actions.barFrame
    } onChange: {
      fired.value = true
    }
    actions.barFrame = CGRect(x: 0, y: 0, width: 320, height: 44)
    XCTAssertFalse(
      fired.value,
      "whoever reads where the bar is is redrawn when the bar moves, and the bar is measured "
        + "inside the column that reader lays out, so the layout never settles")
  }

  /// Whether the observation fired, written from whichever thread `onChange` runs on.
  private final class Fired: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool {
      get { lock.withLock { flag } }
      set { lock.withLock { flag = newValue } }
    }
  }

  /// The band between the two widths above, where AppKit meets the rule that the sidebar, not
  /// the window, makes room for the inspector: the sidebar is folded away because the window
  /// is under `widthWithInspector`, which frees room, which could let the sidebar back, which
  /// takes the room again. 820 pt and 1120 pt are both far from that line; 1050 pt is just
  /// under it, and the crash the owner hit on 21.09 — the same «Update Constraints in Window
  /// passes» abort as 19.09 — was a window somewhere in this band.
  func testAWindowJustUnderTheInspectorWidthDoesNotGrowOrLoop() throws {
    try TestEnvironment.requireScreen(width: 1_050)
    let window = makeWindow(width: 1_050, height: 720)
    try waitForTable(window)
    settle(window, passes: 5, "before the click, 1050 pt")
    XCTAssertEqual(window.frame.width, 1_050, accuracy: 1)

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    doubleClick(plain, "plain operation just under the inspector width")
    let records = settle(window, passes: 40, "with the inspector at 1050 pt")

    XCTAssertTrue(inspectorIsOpen(window), "the inspector folded away at 1050 pt")
    XCTAssertEqual(
      window.frame.width, 1_050, accuracy: 1,
      "the window grew to make room for the inspector and will never shrink back")
    XCTAssertTrue(sidebarIsCollapsed(window), "the sidebar kept its room at 1050 pt")
    assertSettled(records, window, "with the inspector at 1050 pt")
    probe.assertQuiet(about: loopMessages, comparedWith: before, "with the inspector at 1050 pt")
  }

  /// One operation after another in the same band: every switch replaces the whole inspector
  /// (`.id(ObjectIdentifier(editor))`), so the column is rebuilt and reports its minimum
  /// again. Five in a row is what would show the two rules handing the room to each other.
  func testOneOperationAfterAnotherInTheBandSettlesEveryTime() throws {
    try TestEnvironment.requireScreen(width: 1_050)
    let window = makeWindow(width: 1_050, height: 720)
    try waitForTable(window)
    settle(window, passes: 5, "before the clicks, 1050 pt")

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    for round in 0..<5 {
      doubleClick(round.isMultiple(of: 2) ? plain : split, "operation of round \(round)")
      settle(window, passes: 20, "inspector on round \(round)")
      XCTAssertEqual(
        window.frame.width, 1_050, accuracy: 1, "the window grew in round \(round)")
    }
    let records = settle(window, passes: 40, "after five operations at 1050 pt")

    assertSettled(records, window, "after five operations at 1050 pt")
    probe.assertQuiet(about: loopMessages, comparedWith: before, "after five operations at 1050 pt")
  }

  /// The sidebar gives way only when it has to. In a window with room for all three columns
  /// it stays where it is, and opening the inspector changes nothing about it.
  func testAWindowWithRoomForThreeColumnsKeepsItsSidebar() throws {
    try TestEnvironment.requireScreen(width: 1_120)
    let window = makeWindow()
    try waitForTable(window)
    settle(window, passes: 5, "before the click, 1120 pt")

    doubleClick(plain, "plain operation in a wide window")
    let records = settle(window, passes: 40, "with the inspector at 1120 pt")

    XCTAssertTrue(inspectorIsOpen(window))
    XCTAssertFalse(sidebarIsCollapsed(window), "the sidebar gave way with room to spare")
    XCTAssertEqual(window.frame.width, 1120, accuracy: 1)
    assertSettled(records, window, "with the inspector at 1120 pt")
  }

  /// The window keeps its sidebar at 1120 pt, so the inspector gets its ideal and no more —
  /// and everything in it has to be inside the column. On 24.09 it was not: the editor wanted
  /// about 400 pt, the column gave 360, and the column showed the middle of it — «mount»,
  /// «ategory», the buttons cut at the right edge (seen live in English, with a split open).
  func testTheEditorFitsTheInspectorBesideTheSidebar() throws {
    try TestEnvironment.requireScreen(width: 1_120)
    try assertTheEditorFits(split, "in English")
    try assertTheEditorFits(plain, "in English")
  }

  func testTheEditorFitsTheInspectorBesideTheSidebarInRussian() throws {
    try TestEnvironment.requireScreen(width: 1_120)
    environment.language.choice = .russian
    try assertTheEditorFits(split, "in Russian")
    try assertTheEditorFits(plain, "in Russian")
  }

  private func assertTheEditorFits(_ entry: TransactionEntry, _ language: String) throws {
    // A menu is as wide as its longest choice, and the owner's dictionaries have long names;
    // the history above has none, which is why the other tests never saw the column cut.
    let references = try XCTUnwrap(environment.references)
    if try references.places().isEmpty {
      try references.save(Place(name: "Riverside Coffee House on the Embankment"))
      let today = environment.today
      try references.save(
        Event(
          name: "Summer holiday by the sea with the whole family", startDate: today,
          endDate: today))
      try references.save(PaymentMethod(name: "Everyday card of the joint family account"))
      try references.save(Person(name: "Alexandra Konstantinovna"))
    }
    let window = makeWindow()
    defer { window.close() }
    try waitForTable(window)
    settle(window, passes: 5, "before the click, \(language)")
    doubleClick(entry, "\(entry.transaction.note ?? "") \(language)")
    settle(window, passes: 40, "with the inspector open, \(language)")

    XCTAssertTrue(inspectorIsOpen(window), language)
    XCTAssertFalse(sidebarIsCollapsed(window), "the sidebar gave way, \(language)")
    guard let column = inspectorColumn(window) else {
      return XCTFail("no inspector column, \(language)")
    }
    var controls: [NSControl] = []
    Self.allSubviews(of: column, into: &controls)
    XCTAssertFalse(controls.isEmpty, "the inspector shows no controls, \(language)")
    let outside = controls.compactMap { control -> String? in
      let frame = control.convert(control.bounds, to: column)
      guard frame.width > 0, frame.minX < -0.5 || frame.maxX > column.bounds.width + 0.5
      else { return nil }
      return "\(type(of: control)) \(Int(frame.minX))…\(Int(frame.maxX))"
    }
    XCTAssertEqual(
      outside, [],
      "controls reach past the inspector column of \(Int(column.bounds.width)) pt, "
        + "\(entry.transaction.note ?? "") \(language)")
  }

  /// The view of the inspector column, asked of AppKit.
  private func inspectorColumn(_ window: NSWindow) -> NSView? {
    guard let frame = window.contentView?.superview ?? window.contentView else { return nil }
    var splits: [NSSplitView] = []
    Self.allSubviews(of: frame, into: &splits)
    for split in splits {
      guard let controller = split.delegate as? NSSplitViewController else { continue }
      if let item = controller.splitViewItems.first(where: {
        $0.behavior == .inspector && !$0.isCollapsed
      }) {
        return item.viewController.view
      }
    }
    return nil
  }

  /// Whether the column of filters is collapsed, asked of AppKit rather than of our state.
  private func sidebarIsCollapsed(_ window: NSWindow) -> Bool {
    guard let root = window.contentView else { return false }
    var splits: [NSSplitView] = []
    Self.allSubviews(of: root, into: &splits)
    for split in splits {
      guard let controller = split.delegate as? NSSplitViewController else { continue }
      for item in controller.splitViewItems where item.behavior == .sidebar {
        return item.isCollapsed
      }
    }
    return false
  }

  /// SwiftUI folds the inspector away and the edit in it is not saved. The window asks — once
  /// — and the inspector does not come straight back up.
  ///
  /// It used to. The binding answered «no» to the fold-away: it armed the question but left
  /// the editor in place, so the next read said the inspector was shown and SwiftUI put it
  /// back. With the reason for folding still there that repeated, and if the other dialog of
  /// this window was already up, one of the two was dropped in silence with its flag left set
  /// to fire later.
  func testAnInspectorFoldedAwayWithAnUnsavedEditAsksOnceAndStaysAway() throws {
    let model = TransactionEditorModel(entry: plain, environment: environment)
    model.draft.draft.note = "changed, not saved"
    XCTAssertTrue(model.hasChanges, "the test did not manage to make an unsaved change")

    let window = makeWindow(editing: model)
    try waitForTable(window)
    settle(window, passes: 10, "with the inspector open")
    XCTAssertTrue(inspectorIsOpen(window), "the seeded editor did not reach the inspector")

    foldTheInspectorAway(window)
    let records = settle(window, passes: 30, "after the inspector was folded away")

    XCTAssertNotNil(
      window.attachedSheet, "the unsaved edit went away without a question being asked")
    XCTAssertFalse(
      inspectorIsOpen(window), "the inspector came back up behind the question it just raised")
    assertSettled(records, window, "after the inspector was folded away")
  }

  /// The operation in the inspector is deleted elsewhere — ⌘Z of its creation in the main
  /// window, a bulk deletion here — while an edit of it is typed and not saved. The inspector
  /// keeps the edit and says the operation was deleted; it used to close with everything typed
  /// into it and not a word. Nothing typed, it closes as before.
  func testAnOperationDeletedElsewhereKeepsTheUnsavedEditInTheInspector() throws {
    let model = TransactionEditorModel(entry: plain, environment: environment)
    model.draft.draft.note = "Coffee with Alex"
    let window = makeWindow(editing: model)
    try waitForTable(window)
    settle(window, passes: 10, "with the inspector open")
    XCTAssertTrue(inspectorIsOpen(window), "the seeded editor did not reach the inspector")

    show(everything.filter { $0.id != plain.id }, version: 1)
    // The column folds away a few passes after the editor is let go: a second is ample.
    XCTAssertFalse(
      runs(window, for: 1, until: { !inspectorIsOpen(window) }),
      "the inspector closed over an unsaved edit")
    assertSettled(
      settle(window, passes: 30, "after the edited operation was deleted"), window,
      "after the edited operation was deleted")
    XCTAssertEqual(model.draft.draft.note, "Coffee with Alex")
    XCTAssertEqual(model.errorKey, "entry.error.gone")

    // Back — a ⌘Z of the deletion: the word that it is gone goes too.
    show(everything, version: 2)
    XCTAssertFalse(
      runs(window, for: 1, until: { !inspectorIsOpen(window) }),
      "the inspector closed when the operation came back")
    XCTAssertNil(model.errorKey)
  }

  func testAnOperationDeletedElsewhereClosesAnInspectorWithNothingTyped() throws {
    let model = TransactionEditorModel(entry: plain, environment: environment)
    let window = makeWindow(editing: model)
    try waitForTable(window)
    settle(window, passes: 10, "with the inspector open")
    XCTAssertTrue(inspectorIsOpen(window), "the seeded editor did not reach the inspector")

    show(everything.filter { $0.id != plain.id }, version: 1)
    XCTAssertTrue(
      runs(window, for: 3, until: { !inspectorIsOpen(window) }),
      "the inspector held on to a deleted operation")
  }

  /// Drives the layout pass by pass for up to `seconds`; whether `condition` came true.
  private func runs(
    _ window: NSWindow, for seconds: TimeInterval, until condition: () -> Bool
  ) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
      window.updateConstraintsIfNeeded()
      window.layoutIfNeeded()
      window.displayIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.02))
      if condition() { return true }
    } while Date() < deadline
    return false
  }

  /// Every message the editor can show under the panel, in both languages, leaves the window
  /// settled. A message long enough to wrap used to kill it: the text was fixed to its full
  /// height, so the minimum the inspector column reported was that text wrapped at a width of
  /// zero — a character a line, taller than the window — and the split asked for one Update
  /// Constraints pass after another until AppKit threw. Nothing showed it while the inspector
  /// closed over a deleted operation; «Save» over a refusal of the store would have.
  func testEveryMessageOfTheEditorLeavesTheInspectorSettled() throws {
    try TestEnvironment.requireScreen(width: 1_120)
    try assertEveryMessageSettles("in English")
  }

  func testEveryMessageOfTheEditorLeavesTheInspectorSettledInRussian() throws {
    try TestEnvironment.requireScreen(width: 1_120)
    environment.language.choice = .russian
    try assertEveryMessageSettles("in Russian")
  }

  private func assertEveryMessageSettles(_ language: String) throws {
    let model = TransactionEditorModel(entry: plain, environment: environment)
    let window = makeWindow(editing: model)
    try waitForTable(window)
    settle(window, passes: 10, "with the inspector open, \(language)")
    let keys =
      [
        "entry.error.amountMissing", "entry.error.notBalanced", "entry.error.notSaved",
        "entry.error.rateMissing", "entry.error.gone", "entry.error.noDependencies",
        "entry.error.amountNotPositive", "entry.error.debtorMissing",
      ] + EditRefusal.allCases.map(TransactionEditorModel.errorKey(of:))
    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    for key in keys {
      watched(30, "\(key) \(language)") { model.errorKey = key }
      let records = settle(window, passes: 30, "showing \(key), \(language)")
      assertSettled(records, window, "showing \(key), \(language)")
      XCTAssertTrue(inspectorIsOpen(window), "the inspector folded away over \(key)")
      XCTAssertEqual(window.frame.width, 1120, accuracy: 1, "the window grew over \(key)")
    }
    // The panel's own words under its fields, for a draft «Save» cannot take.
    watched(30, "a total below zero \(language)") {
      model.errorKey = nil
      model.draft.draft.amount = AmountE4(whole: -100)
      model.draft.draft.normalizeSinglePart()
    }
    XCTAssertEqual(model.draft.shownRefusalKey, "entry.error.amountNotPositive")
    let records = settle(window, passes: 30, "showing a total below zero, \(language)")
    assertSettled(records, window, "showing a total below zero, \(language)")
    XCTAssertTrue(inspectorIsOpen(window), "the inspector folded away over a total below zero")
    probe.assertQuiet(about: loopMessages, comparedWith: before, "the messages, \(language)")
  }

  /// What SwiftUI does when it runs out of room, done by hand: the inspector column of the
  /// split view is collapsed, and SwiftUI writes `false` into the binding that presents it.
  private func foldTheInspectorAway(_ window: NSWindow) {
    guard let root = window.contentView else { return XCTFail("no content view") }
    var splits: [NSSplitView] = []
    Self.allSubviews(of: root, into: &splits)
    for split in splits {
      guard let controller = split.delegate as? NSSplitViewController else { continue }
      for item in controller.splitViewItems where item.behavior == .inspector {
        item.isCollapsed = true
        return
      }
    }
    XCTFail("the inspector column was not found")
  }

  /// The same operation, changed elsewhere: `followData` swaps the editor and the inspector
  /// subtree is rebuilt under a new `.id`.
  private func changedPlain() -> [TransactionEntry] {
    var entries = everything!
    guard let index = entries.firstIndex(where: { $0.transaction.id == plain.transaction.id })
    else { return entries }
    let old = entries[index]
    var transaction = old.transaction
    transaction.note = "Coffee, a bun and a long enough note to change the width of the row"
    entries[index] = TransactionEntry(transaction: transaction, parts: old.parts)
    return entries
  }

  // MARK: - Saving from the inspector
  //
  // On 05.10 the released copy died the same death — «more Update Constraints in Window passes
  // than there are views» — seven seconds after an operation edited in the inspector was saved
  // with this window open. The loop ran through the safe area this time: a view the display
  // list moved told the hosting views inside it that their safe area had changed, and each of
  // them asked for constraints again inside the layout pass. Every test above opens or changes
  // the inspector; none of them saves from it, so the write, the inspector closing over it, the
  // sidebar coming back and the data that follows the write had never been laid out together.

  /// The history of the window put in the database too, so a save is a real write, and the
  /// write laid over the data the way the app lays it (`AppLaunch`).
  private func keepTheHistoryInTheDatabase() throws {
    let references = try XCTUnwrap(environment.references)
    try references.save(food)
    try references.save(salary)
    let repository = try XCTUnwrap(environment.transactions)
    for entry in everything { _ = try repository.save(entry) }
    store.didWrite = { [weak self] write in
      self?.writes.append(write.upserted.count)
      self?.compute.overlay(write)
    }
  }

  /// How many operations each write of the store reported, in order.
  private var writes: [Int] = []

  /// The history as the database has it now: the data the app reads again after a write.
  private func readTheDatabaseAgain(version: Int) throws {
    let repository = try XCTUnwrap(environment.transactions)
    let entries = try repository.entries(from: .distantPast, to: .distantFuture)
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(entries: entries, categories: [food, salary]), calendar: .system,
        today: environment.today, context: SnapshotContext(),
        version: DataVersion(load: version)))
  }

  /// `plain` with a comment long enough to change its row, as the inspector's save writes it.
  private func editedPlain() -> TransactionEntry {
    var transaction = plain.transaction
    transaction.note = "Coffee, a bun and a note long enough to change the row's width"
    transaction.updatedAt = Date()
    return TransactionEntry(transaction: transaction, parts: plain.parts)
  }

  /// A control of SwiftUI found the way VoiceOver finds it: a button of SwiftUI is no
  /// `NSButton`, and only the accessibility tree reaches it.
  private func element(identified identifier: String, in window: NSWindow) -> NSObject? {
    func attribute(_ object: NSObject, _ name: String) -> Any? {
      guard object.responds(to: NSSelectorFromString(name)) else { return nil }
      return object.value(forKey: name)
    }
    var found: NSObject?
    func walk(_ element: Any) {
      guard found == nil, let object = element as? NSObject else { return }
      if attribute(object, "accessibilityIdentifier") as? String == identifier {
        found = object
        return
      }
      for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] { walk(child) }
    }
    if let root = window.contentView { walk(root) }
    return found
  }

  /// The gesture of 05.10: an operation opened by a double click, its edit written, «Save»
  /// pressed — the inspector closes, the sidebar comes back if it had stepped aside — and the
  /// data read again a moment later. Every step must settle quietly.
  private func assertSavingSettles(
    width: CGFloat, height: CGFloat = 720, selecting: Bool, _ what: String,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try keepTheHistoryInTheDatabase()
    let window = makeWindow(width: width, height: height)
    try waitForTable(window)
    settle(window, passes: 5, "before the click, \(what)")
    if selecting { actions.selection = [plain.id] }
    doubleClick(plain, what)
    settle(window, passes: 20, "with the inspector open, \(what)")
    XCTAssertTrue(
      inspectorIsOpen(window), "the inspector did not open, \(what)", file: file, line: line)

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    // «Save» closes the inspector, and the write of the save is laid over the data in the same
    // turn. The edit is written by the store here: the editor the double click made cannot be
    // typed into from a test, and its own save of an untouched draft writes nothing.
    let save = try XCTUnwrap(
      element(identified: "editor.save", in: window), "no «Save» in the inspector, \(what)")
    let outcome = watched(30, "the save, \(what)") {
      _ = save.perform(NSSelectorFromString("accessibilityPerformPress"))
      return store.saveEdit(editedPlain())
    }
    XCTAssertEqual(outcome, .saved, what, file: file, line: line)
    watched(30, "the turns after the save, \(what)") {
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let saved = settle(window, passes: 40, "after the save, \(what)")
    // The press reaches the editor a moment later, and its draft of the operation as it was
    // may be written over the store's write: one more write, not a layout matter.
    XCTAssertEqual(writes.first, 1, "the save wrote nothing, \(what)")
    XCTAssertFalse(inspectorIsOpen(window), "the inspector stayed open after the save, \(what)")
    assertSettled(saved, window, "after the save, \(what)", file: file, line: line)
    // Where the sidebar stepped aside, its return widens the window — a fault of its own,
    // pinned down by `testClosingTheInspectorInANarrowWindowKeepsItsWidth`.
    if width >= TransactionsRootView.widthWithInspector {
      XCTAssertEqual(
        window.frame.width, width, accuracy: 1, "the window changed its width, \(what)")
    }
    XCTAssertFalse(
      sidebarIsCollapsed(window), "the sidebar did not come back after the save, \(what)")

    // The database is read again a moment after any write, and the window refilters 150 ms
    // after the data changes.
    watched(30, "the read after the save, \(what)") {
      try? readTheDatabaseAgain(version: 1)
      for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let read = settle(window, passes: 40, "after the read that follows the save, \(what)")
    assertSettled(
      read, window, "after the read that follows the save, \(what)", file: file, line: line)
    probe.assertQuiet(
      about: loopMessages, comparedWith: before, "saving from the inspector, \(what)")
    XCTAssertEqual(AppDependencies.missingReaders, [])
  }

  func testSavingFromTheInspectorWithTheBarShownLeavesTheWindowSettled() throws {
    try TestEnvironment.requireScreen(width: 1_120)
    try assertSavingSettles(width: 1_120, selecting: true, "1120 pt, a row selected")
  }

  func testSavingFromTheInspectorWithNothingSelectedLeavesTheWindowSettled() throws {
    try TestEnvironment.requireScreen(width: 1_120)
    try assertSavingSettles(width: 1_120, selecting: false, "1120 pt, nothing selected")
  }

  /// The sidebar was folded away for the inspector; the save closes the inspector and the
  /// sidebar comes back in the same pass, with the bar standing at the bottom of the table.
  func testSavingFromTheInspectorInANarrowWindowWithTheBarLeavesItSettled() throws {
    try assertSavingSettles(width: 900, height: 600, selecting: true, "900 pt, a row selected")
  }

  func testSavingFromTheInspectorInANarrowWindowLeavesItSettled() throws {
    try assertSavingSettles(width: 900, height: 600, selecting: false, "900 pt, nothing selected")
  }

  func testSavingFromTheInspectorJustUnderTheInspectorWidthLeavesItSettled() throws {
    try TestEnvironment.requireScreen(width: 1_050)
    try assertSavingSettles(width: 1_050, selecting: true, "1050 pt, a row selected")
  }

  func testSavingFromTheInspectorInTheSmallestWindowLeavesItSettled() throws {
    try assertSavingSettles(width: 820, height: 480, selecting: true, "820 pt, a row selected")
  }

  func testSavingFromTheInspectorInRussianLeavesTheWindowSettled() throws {
    try TestEnvironment.requireScreen(width: 1_120)
    environment.language.choice = .russian
    try assertSavingSettles(width: 1_120, selecting: true, "1120 pt, a row selected, in Russian")
  }

  /// The sidebar steps aside for the inspector in a narrow window and comes back when the
  /// inspector goes. Coming back, it takes its width from the window: the window grows by the
  /// sidebar and AppKit never shrinks it back. Known and not fixed yet: showing the sidebar a
  /// turn after the inspector has gone grows the window all the same.
  func testClosingTheInspectorInANarrowWindowKeepsItsWidth() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let window = makeWindow(width: 900, height: 600)
    try waitForTable(window)
    settle(window, passes: 5, "before the click, 900 pt")
    doubleClick(plain, "plain, 900 pt")
    settle(window, passes: 20, "with the inspector open, 900 pt")
    XCTAssertTrue(sidebarIsCollapsed(window), "the sidebar kept its room at 900 pt")

    let cancel = try XCTUnwrap(element(identified: "editor.cancel", in: window))
    watched(30, "cancel at 900 pt") {
      _ = cancel.perform(NSSelectorFromString("accessibilityPerformPress"))
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let records = settle(window, passes: 40, "after cancel, 900 pt")
    assertSettled(records, window, "after cancel, 900 pt")
    XCTAssertFalse(inspectorIsOpen(window))
    XCTAssertFalse(sidebarIsCollapsed(window), "the sidebar did not come back")
    XCTExpectFailure("the sidebar coming back widens a narrow window by its own width") {
      XCTAssertEqual(window.frame.width, 900, accuracy: 1, "the window grew")
    }
  }

  /// «Save» in the question asked when another operation is opened writes without closing the
  /// inspector: the write lands, and the data that follows it, while the inspector is still
  /// there — `followData` hands it a fresh model of the saved operation.
  func testAWriteLandingWhileTheInspectorStaysOpenLeavesTheWindowSettled() throws {
    try keepTheHistoryInTheDatabase()
    let window = makeWindow(width: 900, height: 600)
    try waitForTable(window)
    settle(window, passes: 5, "before the click, 900 pt")
    actions.selection = [plain.id]
    doubleClick(plain, "plain, 900 pt")
    settle(window, passes: 20, "with the inspector and the bar open")
    XCTAssertTrue(inspectorIsOpen(window))

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    let outcome = watched(30, "a write that keeps the inspector") {
      store.saveEdit(editedPlain())
    }
    XCTAssertEqual(outcome, .saved)
    XCTAssertEqual(writes, [1])
    let records = settle(window, passes: 40, "after a write with the inspector still open")
    XCTAssertTrue(inspectorIsOpen(window), "the inspector closed over a write it did not make")
    assertSettled(records, window, "after a write with the inspector still open")

    watched(30, "the read after a write with the inspector open") {
      try? readTheDatabaseAgain(version: 1)
      for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let read = settle(window, passes: 40, "after the read, inspector still open")
    assertSettled(read, window, "after the read, inspector still open")
    XCTAssertTrue(inspectorIsOpen(window), "the inspector closed over the read")
    probe.assertQuiet(
      about: loopMessages, comparedWith: before, "a write landing with the inspector open")
  }

  /// A write of more than a thousand operations leaves the main thread, and while it is on its
  /// way the bar stands at the bottom of the table with nothing selected — so the bar comes and
  /// goes by itself, with the inspector open, twice within a moment.
  func testALargeWriteTogglingTheBarWithTheInspectorOpenLeavesTheWindowSettled() throws {
    try keepTheHistoryInTheDatabase()
    let repository = try XCTUnwrap(environment.transactions)
    let longAgo = CalendarContext.utc.startOfDay(DateOnly(year: 2020, month: 1, day: 1))
    let many = try (0...TransactionsStore.backgroundThreshold).map { index in
      var draft = TransactionDraft(
        occurredAt: longAgo.addingTimeInterval(TimeInterval(index) * 60),
        amount: AmountE4(whole: 100), note: "row \(index)")
      draft.normalizeSinglePart()
      return try draft.materialize()
    }
    let window = makeWindow(width: 900, height: 600)
    try waitForTable(window)
    settle(window, passes: 5, "before the click, 900 pt")
    try repository.insert(many)
    doubleClick(plain, "plain, 900 pt")
    settle(window, passes: 20, "with the inspector open, nothing selected")
    XCTAssertTrue(inspectorIsOpen(window))

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    XCTAssertTrue(store.apply(.quality(.bad), to: many.map(\.id)))
    XCTAssertTrue(store.isWritingInBackground, "the write did not leave the main thread")
    let shown = settle(window, passes: 40, "with the bar of a write on its way")
    assertSettled(shown, window, "with the bar of a write on its way")
    // Waited for by turning the run loop, not by `await`: the window's own work goes on only
    // while the run loop turns.
    XCTAssertTrue(
      runs(window, for: 20, until: { !store.isWritingInBackground }),
      "the large write never landed")
    XCTAssertNil(store.lastError)
    // The landed write is new data: the window refilters its rows off the main thread and lays
    // them out when they come, which may be just after ten quiet passes. Work comes to rest —
    // measured under load at 0.03 s —; a loop never does, so the window must come to rest
    // within ten seconds and then stay settled.
    let dirty = {
      (window.contentView?.needsLayout ?? false)
        || (window.contentView?.needsUpdateConstraints ?? false)
    }
    settle(window, passes: 40, "after the large write landed")
    XCTAssertTrue(runs(window, for: 10, until: { !dirty() }), "the window never came to rest")
    let gone = settle(window, passes: 40, "after the large write came to rest")
    assertSettled(gone, window, "after the large write landed")
    XCTAssertTrue(inspectorIsOpen(window), "the inspector folded away under the bar")
    probe.assertQuiet(
      about: loopMessages, comparedWith: before, "a large write with the inspector open")
  }

  /// The window laid out for the first time with an operation already in the inspector, and a
  /// row selected after: the bar slides in beside an inspector that was never given its room by
  /// a double click. This is the one way found here to the loop of 05.10 — the very stack of
  /// the owner's crash report, through the safe area of a moved view — and, on other runs, to
  /// the loop of 19.09 through the minimum of a column.
  func testAWindowOpeningWithTheInspectorThenASelectionLeavesItSettled() throws {
    try TestEnvironment.requireScreen(width: 1_120)
    let window = makeWindow(editing: TransactionEditorModel(entry: plain, environment: environment))
    try waitForTable(window)
    settle(window, passes: 10, "opened with the inspector")
    XCTAssertTrue(inspectorIsOpen(window), "the seeded editor did not reach the inspector")

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    watched(30, "a selection beside an inspector the window opened with") {
      actions.selection = [plain.id]
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let records = settle(window, passes: 60, "a selection beside the inspector it opened with")
    assertSettled(records, window, "a selection beside the inspector it opened with")
    probe.assertQuiet(
      about: loopMessages, comparedWith: before, "a selection beside the inspector it opened with")
  }

  /// The owner can drag the inspector wider or narrower than its ideal; a row selected then
  /// brings the bar in beside an inspector of that width.
  func testASelectionBesideAnInspectorDraggedWiderLeavesTheWindowSettled() throws {
    try assertSelectionBesideADraggedInspectorSettles(width: 418)
  }

  func testASelectionBesideAnInspectorDraggedNarrowerLeavesTheWindowSettled() throws {
    try assertSelectionBesideADraggedInspectorSettles(width: 320)
  }

  private func assertSelectionBesideADraggedInspectorSettles(
    width inspector: CGFloat, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    try TestEnvironment.requireScreen(width: 1_120)
    try TestEnvironment.requireUnlockedScreen()
    let window = makeWindow()
    try waitForTable(window)
    settle(window, passes: 5, "before the click")
    doubleClick(plain, "plain")
    settle(window, passes: 20, "with the inspector open")
    watched(30, "dragging the inspector to \(Int(inspector)) pt") {
      dragTheInspector(window, to: inspector)
    }
    settle(window, passes: 20, "with the inspector dragged to \(Int(inspector)) pt")
    // The column keeps to its content's minimum, so a drag below it stops there; what counts
    // is that the inspector is no longer at its ideal width.
    XCTAssertGreaterThan(
      abs(
        (inspectorColumn(window)?.frame.width ?? TransactionInspector.idealWidth)
          - TransactionInspector.idealWidth), 10,
      "the drag left the inspector at its ideal width", file: file, line: line)

    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    watched(30, "a selection beside an inspector of \(Int(inspector)) pt") {
      actions.selection = [plain.id]
      for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let records = settle(
      window, passes: 60, "a selection beside an inspector of \(Int(inspector)) pt")
    assertSettled(records, window, "a selection beside a dragged inspector", file: file, line: line)
    probe.assertQuiet(
      about: loopMessages, comparedWith: before, "a selection beside a dragged inspector")
  }

  /// The divider before the inspector moved the way a drag moves it.
  private func dragTheInspector(_ window: NSWindow, to width: CGFloat) {
    guard let root = window.contentView?.superview ?? window.contentView else { return }
    var splits: [NSSplitView] = []
    Self.allSubviews(of: root, into: &splits)
    for split in splits {
      guard let controller = split.delegate as? NSSplitViewController,
        let index = controller.splitViewItems.firstIndex(where: { $0.behavior == .inspector }),
        index > 0
      else { continue }
      split.setPosition(
        split.bounds.width - width - split.dividerThickness, ofDividerAt: index - 1)
      return
    }
    XCTFail("the inspector column was not found")
  }

  // MARK: - Coming back to the app
  //
  // The loop of 19.09 started about twelve seconds after the last click, with nothing but
  // RunningBoard between. Losing and regaining the app's activity is what reproduces it, and
  // only with the inspector open and the selection bar shown: either alone settles at once.

  /// Loses and regains activity, then says how long the window took and what the log said.
  /// A window that loops spends seconds inside a single turn of the run loop and AppKit says
  /// «has continued for 300 iterations» — both are failures here.
  @discardableResult
  private func activityRound(
    _ window: NSWindow, _ what: String, file: StaticString = #filePath, line: UInt = #line
  ) -> (seconds: Double, loops: Int) {
    let probe = LogProbe()
    let before = probe.counts(of: loopMessages)
    let started = Date()
    NSApp.deactivate()
    for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    NSApp.activate()
    for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    let seconds = Date().timeIntervalSince(started)
    let loops =
      probe.count(LogProbe.Message.layoutLoop) - (before[LogProbe.Message.layoutLoop] ?? 0)
    print(String(format: "layout activity %@: %.1f s, %d layout loops", what, seconds, loops))
    if probe.isBlind {
      print("log probe: blind; \(what) not checked for layout loops")
    } else {
      XCTAssertEqual(loops, 0, "the layout looped: \(what)", file: file, line: line)
    }
    XCTAssertLessThan(
      seconds, 30, "coming back took too long: \(what)", file: file, line: line)
    return (seconds, loops)
  }

  func testComingBackWithTheInspectorAndTheBarLeavesTheWindowSettled() throws {
    let window = makeWindow()
    try waitForTable(window)
    actions.selection = [plain.id]
    doubleClick(plain, "plain")
    settle(window, passes: 10, "both")
    activityRound(window, "inspector open + bar shown")
  }

  func testComingBackWithTheInspectorAloneLeavesTheWindowSettled() throws {
    let window = makeWindow()
    try waitForTable(window)
    doubleClick(plain, "plain")
    settle(window, passes: 10, "inspector only")
    activityRound(window, "inspector open, no bar")
  }

  func testComingBackWithTheBarAloneLeavesTheWindowSettled() throws {
    let window = makeWindow()
    try waitForTable(window)
    actions.selection = [plain.id]
    settle(window, passes: 10, "bar only")
    activityRound(window, "bar shown, no inspector")
  }

  func testComingBackWithNeitherLeavesTheWindowSettled() throws {
    let window = makeWindow()
    try waitForTable(window)
    settle(window, passes: 10, "plain window")
    activityRound(window, "no inspector, no bar")
  }

  // MARK: - The click is not handled inside the table's callback

  /// Nothing of the window changes while the table is still handling the double click: the
  /// inspector opens on the next turn of the main queue.
  func testTheInspectorOpensAfterTheTableHasFinishedWithTheClick() throws {
    let window = makeWindow()
    try waitForTable(window)

    actions.edit([plain.id], store: store)

    XCTAssertFalse(inspectorIsOpen(window), "the inspector opened inside the table's callback")
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    settle(window, passes: 10, "after the deferred open")
    XCTAssertTrue(inspectorIsOpen(window), "the inspector never opened")
  }

  /// Whether the inspector column is there and not collapsed.
  private func inspectorIsOpen(_ window: NSWindow) -> Bool {
    guard let frame = window.contentView?.superview ?? window.contentView else { return false }
    var splits: [NSSplitView] = []
    Self.allSubviews(of: frame, into: &splits)
    for split in splits {
      guard let controller = split.delegate as? NSSplitViewController else { continue }
      if controller.splitViewItems.contains(where: { $0.behavior == .inspector && !$0.isCollapsed })
      {
        return true
      }
    }
    return false
  }
}
