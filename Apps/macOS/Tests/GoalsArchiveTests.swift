import AppCore
import AppDatabase
import XCTest

@testable import Itogo

/// Goals in the archive, in Planning: «Вернуть» brings a goal back as the database holds it —
/// not as the snapshot on screen last saw it — and one ⌘Z puts it in the archive again.
@MainActor
final class GoalsArchiveTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["ITOGO_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-goals-archive-\(UUID().uuidString)", isDirectory: true)
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
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("ITOGO_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("ITOGO_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private var references: ReferenceRepository { environment.references! }

  private var actions: PlanningActions {
    PlanningActions(AppDependencies(environment: environment, store: store, compute: compute))
  }

  /// «Вернуть» makes the goal live with what the database holds now — a target changed after
  /// the block last read it stays — and one step of ⌘Z sends it back to the archive.
  func testBringingAGoalBackIsOneStepOfUndo() throws {
    let trip = Goal(name: "Отпуск", targetE4: AmountE4(whole: 100_000), archived: true)
    try references.save(trip)
    var changed = trip
    changed.targetE4 = AmountE4(whole: 150_000)
    try references.save(changed)

    XCTAssertTrue(GoalsBlock.restore(trip.id, with: actions, references: references))
    let back = try XCTUnwrap(try references.goals().first { $0.id == trip.id })
    XCTAssertEqual(back.targetE4, AmountE4(whole: 150_000), "an older copy was written back")
    XCTAssertTrue(store.canUndo)

    store.undo()
    XCTAssertTrue(try references.goals().isEmpty, "⌘Z left the goal out of the archive")
    XCTAssertEqual(
      try references.goals(includeArchived: true).first { $0.id == trip.id }?.targetE4,
      AmountE4(whole: 150_000))
  }

  /// «Сохранить» of a new goal named as one in the archive — «отпуск» for «Отпуск» — brings
  /// that goal back as it was, its target and what was put in included, one step of ⌘Z,
  /// instead of making a second goal of the same name.
  func testANewGoalWithTheNameOfAnArchivedOneBringsItBack() throws {
    let trip = Goal(name: "Отпуск", targetE4: AmountE4(whole: 100_000), archived: true)
    try references.save(trip)

    let typed = Goal(name: "отпуск", targetE4: AmountE4(whole: 50_000))
    XCTAssertTrue(GoalForm.save(typed, isNew: true, with: actions, references: references))
    let all = try references.goals(includeArchived: true)
    XCTAssertEqual(all.map(\.id), [trip.id], "a second goal of the same name was made")
    XCTAssertEqual(all.first?.archived, false)
    XCTAssertEqual(all.first?.targetE4, AmountE4(whole: 100_000))

    store.undo()
    XCTAssertEqual(
      try references.goals(includeArchived: true).map(\.archived), [true],
      "⌘Z left the goal out of the archive")
  }

  /// Nothing comes back while a live goal has the name, and an edit of a saved goal is only
  /// that edit: the archive is asked about new goals only.
  func testALiveNameOrAnEditBringsNothingBackFromTheArchive() throws {
    let old = Goal(name: "Машина", targetE4: AmountE4(whole: 900_000), archived: true)
    let live = Goal(name: "Машина", targetE4: AmountE4(whole: 1_000_000))
    try references.save(old)
    try references.save(live)

    var edited = live
    edited.targetE4 = AmountE4(whole: 1_200_000)
    XCTAssertTrue(GoalForm.save(edited, isNew: false, with: actions, references: references))
    XCTAssertEqual(
      try references.goals(includeArchived: true).first { $0.id == old.id }?.archived, true)

    let another = Goal(name: "машина", targetE4: AmountE4(whole: 500_000))
    XCTAssertTrue(GoalForm.save(another, isNew: true, with: actions, references: references))
    let all = try references.goals(includeArchived: true)
    XCTAssertEqual(all.count, 3, "a goal was brought back beside a live one of its name")
    XCTAssertEqual(all.first { $0.id == old.id }?.archived, true)
  }

  /// A goal deleted meanwhile is not written back.
  func testAGoalGoneMeanwhileIsNotWrittenBack() throws {
    XCTAssertFalse(GoalsBlock.restore(UUID(), with: actions, references: references))
    XCTAssertTrue(try references.goals(includeArchived: true).isEmpty)
    XCTAssertFalse(store.canUndo)
  }
}
