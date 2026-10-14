import AppCore
import AppDatabase
import XCTest

@testable import Itogo

/// A source of copies that is never asked: the retention scenarios below only look at the names
/// of files already in a folder.
private final class UnusedBackupSource: BackupSource, @unchecked Sendable {
  struct Asked: Error {}
  func backup(to destination: URL) throws { throw Asked() }
  func integrityCheckPassed() throws -> Bool { true }
}

/// The name of a copy is the moment it was taken: the local time it was written at and the
/// offset of that time from UTC. These scenarios walk that name through the zones a Mac may be
/// in — west of Greenwich, half- and quarter-hour offsets, the farthest east — and through the
/// days that end a month, a leap February and a year, and read every name back as the instant
/// it stands for.
final class DataScenarioBackupNameTests: XCTestCase {
  private func zone(_ identifier: String) throws -> TimeZone {
    try XCTUnwrap(TimeZone(identifier: identifier))
  }

  private func instant(
    _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0,
    _ second: Int = 0, in zone: TimeZone
  ) throws -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return try XCTUnwrap(
      calendar.date(
        from: DateComponents(
          year: year, month: month, day: day, hour: hour, minute: minute, second: second)))
  }

  func testANameInUTCCarriesAZeroOffset() throws {
    let utc = try zone("UTC")
    let name = BackupService.fileName(at: try instant(2026, 1, 1, in: utc), in: utc)
    XCTAssertEqual(name, "finance-2026-01-01T000000+0000.sqlite")
  }

  func testANameWestOfGreenwichFollowsSummerTime() throws {
    let newYork = try zone("America/New_York")
    let winter = BackupService.fileName(
      at: try instant(2026, 1, 15, 9, 30, in: newYork), in: newYork)
    let summer = BackupService.fileName(
      at: try instant(2026, 7, 15, 9, 30, in: newYork), in: newYork)
    XCTAssertEqual(winter, "finance-2026-01-15T093000-0500.sqlite")
    XCTAssertEqual(summer, "finance-2026-07-15T093000-0400.sqlite")
  }

  func testAHalfHourZoneKeepsItsMinutes() throws {
    let kolkata = try zone("Asia/Kolkata")
    let name = BackupService.fileName(at: try instant(2026, 3, 3, 12, in: kolkata), in: kolkata)
    XCTAssertEqual(name, "finance-2026-03-03T120000+0530.sqlite")
  }

  func testAQuarterHourZoneKeepsItsMinutes() throws {
    let kathmandu = try zone("Asia/Kathmandu")
    let name = BackupService.fileName(
      at: try instant(2026, 3, 3, 12, in: kathmandu), in: kathmandu)
    XCTAssertEqual(name, "finance-2026-03-03T120000+0545.sqlite")
  }

  func testTheFarthestEastZoneIsFourteenHoursAhead() throws {
    let kiritimati = try zone("Pacific/Kiritimati")
    let name = BackupService.fileName(
      at: try instant(2026, 5, 5, 1, 2, 3, in: kiritimati), in: kiritimati)
    XCTAssertEqual(name, "finance-2026-05-05T010203+1400.sqlite")
  }

  func testALabelFollowsTheStampWithADash() throws {
    let moscow = try zone("Europe/Moscow")
    let name = BackupService.fileName(
      at: try instant(2026, 10, 14, 8, 5, 9, in: moscow), label: "before-restore", in: moscow)
    XCTAssertEqual(name, "finance-2026-10-14T080509+0300-before-restore.sqlite")
  }

  /// Every name, whatever the zone it was written in, reads back as the instant it was taken.
  func testEveryZoneReadsBackTheSameInstant() throws {
    let moment = Date(timeIntervalSince1970: 1_791_234_567)
    for identifier in [
      "UTC", "Europe/Moscow", "America/Los_Angeles", "Asia/Kolkata", "Asia/Kathmandu",
      "Pacific/Kiritimati", "Pacific/Pago_Pago", "Australia/Adelaide",
    ] {
      let name = BackupService.fileName(at: moment, in: try zone(identifier))
      XCTAssertEqual(BackupService.date(in: name), moment, identifier)
    }
  }

  /// A label does not change the moment read back.
  func testALabelledNameReadsBackItsInstant() {
    let moment = Date(timeIntervalSince1970: 1_791_000_000)
    for label in ["before-restore", "before-import", "before-migration", "before-restore-damaged"] {
      XCTAssertEqual(
        BackupService.date(in: BackupService.fileName(at: moment, label: label)), moment, label)
    }
  }

  func testTheLeapDayIsADayOfItsOwn() throws {
    let moscow = try zone("Europe/Moscow")
    let name = BackupService.fileName(
      at: try instant(2028, 2, 29, 23, 59, 59, in: moscow), in: moscow)
    XCTAssertEqual(BackupService.day(in: name), "2028-02-29")
    let next = BackupService.fileName(at: try instant(2028, 3, 1, in: moscow), in: moscow)
    XCTAssertEqual(BackupService.day(in: next), "2028-03-01")
  }

  /// The last second of a year and the first of the next are two days of two years.
  func testMidnightOfANewYearStartsAnotherDay() throws {
    let moscow = try zone("Europe/Moscow")
    let last = try instant(2026, 12, 31, 23, 59, 59, in: moscow)
    let first = last.addingTimeInterval(1)
    XCTAssertEqual(
      BackupService.day(in: BackupService.fileName(at: last, in: moscow)), "2026-12-31")
    XCTAssertEqual(
      BackupService.day(in: BackupService.fileName(at: first, in: moscow)), "2027-01-01")
  }

  /// The day of a copy is the day of its own clock: the same instant is the 31st in Los
  /// Angeles and already the 1st in Moscow.
  func testTheDayOfACopyIsTheDayOfTheZoneItWasWrittenIn() throws {
    let moment = try instant(2026, 8, 31, 22, in: try zone("UTC"))
    let losAngeles = try zone("America/Los_Angeles")
    XCTAssertEqual(
      BackupService.day(in: BackupService.fileName(at: moment, in: losAngeles)), "2026-08-31")
    XCTAssertEqual(
      BackupService.day(in: BackupService.fileName(at: moment, in: try zone("Europe/Moscow"))),
      "2026-09-01")
  }

  func testTheDayOfALabelledName() {
    XCTAssertEqual(
      BackupService.day(in: "finance-2026-04-30T235959+0300-before-migration.sqlite"),
      "2026-04-30")
  }

  func testFilesThatAreNotCopiesHaveNoMoment() {
    for name in [
      "photo.sqlite", "finance.sqlite", "finance-.sqlite", "finance-garbage.sqlite",
      "Finance-2026-01-01T000000+0000.sqlite", "notes.txt", "",
    ] {
      XCTAssertNil(BackupService.date(in: name), name)
    }
  }

  func testAShortNameHasNoDay() {
    XCTAssertNil(BackupService.day(in: "finance-2026"))
    XCTAssertNil(BackupService.day(in: "backup-2026-01-01T000000.sqlite"))
  }

  /// A name whose offset is not digits is read as the local time it says, like a name of the
  /// copies written before the offset was added.
  func testAnOffsetThatIsNotDigitsIsReadAsLocalTime() throws {
    let local = BackupService.date(in: "finance-2026-01-01T101500+03ab.sqlite")
    let expected = try instant(2026, 1, 1, 10, 15, in: .current)
    XCTAssertEqual(local, expected)
  }

  func testTheMarkOfADamagedCopy() {
    XCTAssertEqual(BackupService.damaged(nil), "damaged")
    XCTAssertEqual(BackupService.damaged("before-restore"), "before-restore-damaged")
    XCTAssertEqual(BackupService.damaged("before-import"), "before-import-damaged")
  }

  func testOnlyTheCopyBeforeAnUpdateIsSaidToBeOne() {
    XCTAssertTrue(
      BackupService.isBeforeMigration("finance-2026-01-01T000000+0300-before-migration.sqlite"))
    XCTAssertFalse(BackupService.isBeforeMigration("finance-2026-01-01T000000+0300.sqlite"))
    XCTAssertFalse(
      BackupService.isBeforeMigration("finance-2026-01-01T000000+0300-before-restore.sqlite"))
    XCTAssertFalse(
      BackupService.isBeforeMigration("finance-2026-01-01T000000+0300-before-import.sqlite"))
  }

  /// A copy taken at 10:00 in Moscow is older than one taken at 08:30 in London the same day,
  /// though its name sorts after it.
  func testNewestFirstFollowsTheInstantNotTheName() throws {
    let folder = URL(fileURLWithPath: "/copies")
    let moscow = folder.appendingPathComponent("finance-2026-06-01T100000+0300.sqlite")
    let london = folder.appendingPathComponent("finance-2026-06-01T083000+0100.sqlite")
    XCTAssertEqual(BackupService.newestFirst([moscow, london]), [london, moscow])
    XCTAssertEqual(BackupService.newestFirst([london, moscow]), [london, moscow])
  }

  func testNamesWithoutAMomentGoLastByName() {
    let folder = URL(fileURLWithPath: "/copies")
    let dated = folder.appendingPathComponent("finance-2020-01-01T000000+0000.sqlite")
    let alpha = folder.appendingPathComponent("alpha.sqlite")
    let omega = folder.appendingPathComponent("omega.sqlite")
    XCTAssertEqual(BackupService.newestFirst([alpha, dated, omega]), [dated, omega, alpha])
  }

  /// Two copies of one instant — a plain one and the one before a restore — go by name.
  func testCopiesOfOneInstantAreOrderedByName() {
    let folder = URL(fileURLWithPath: "/copies")
    let plain = folder.appendingPathComponent("finance-2026-06-01T100000+0300.sqlite")
    let labelled = folder.appendingPathComponent(
      "finance-2026-06-01T100000+0300-before-restore.sqlite")
    // Names of one instant sort descending: «.sqlite» comes after «-before-restore».
    XCTAssertEqual(BackupService.newestFirst([plain, labelled]), [plain, labelled])
    XCTAssertEqual(BackupService.newestFirst([labelled, plain]), [plain, labelled])
  }

  func testNoCopiesAreNoCopies() {
    XCTAssertEqual(BackupService.newestFirst([]), [])
  }
}

/// «Хранение: последние 50 копий и одна в день за 90 дней» on a small scale: the policy keeps
/// three latest copies and one a day for five days, and the scenarios fill a folder with empty
/// files under copies' names and apply it — a quiet week, a busy day, copies across a leap
/// February, the copies before an update and the owner's own files beside them.
final class DataScenarioBackupRetentionTests: XCTestCase {
  private var directory: URL!
  private let utc = TimeZone(identifier: "UTC")!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-f-retention-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func service(latest: Int = 3, days: Int = 5, folder: URL? = nil) -> BackupService {
    var policy = BackupService.Policy()
    policy.keepLatest = latest
    policy.keepDailyForDays = days
    return BackupService(
      source: UnusedBackupSource(), directory: folder ?? directory, policy: policy)
  }

  private func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = utc
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
  }

  @discardableResult
  private func put(
    _ instants: [Date], label: String? = nil, in folder: URL? = nil
  ) throws
    -> [String]
  {
    try instants.map { instant in
      let name = BackupService.fileName(at: instant, label: label, in: utc)
      try Data("x".utf8).write(to: (folder ?? directory).appendingPathComponent(name))
      return name
    }
  }

  private func left(in folder: URL? = nil) -> Set<String> {
    Set((try? FileManager.default.contentsOfDirectory(atPath: (folder ?? directory).path)) ?? [])
  }

  func testFewerCopiesThanTheLatestAreAllKept() async throws {
    let names = try put([day(2026, 1, 1), day(2026, 1, 2)])
    try await service().applyRetention(now: day(2026, 6, 1))
    XCTAssertEqual(left(), Set(names))
  }

  func testExactlyTheLatestAreAllKeptHoweverOld() async throws {
    let names = try put([day(2020, 1, 1), day(2021, 1, 1), day(2022, 1, 1)])
    try await service().applyRetention(now: day(2026, 6, 1))
    XCTAssertEqual(left(), Set(names))
  }

  /// One copy too many on one day: the oldest of that day goes — the day keeps its newest.
  func testOneCopyTooManyOnOneDayDropsTheOldest() async throws {
    let base = day(2026, 3, 10, 8)
    let names = try put((0..<4).map { base.addingTimeInterval(Double($0) * 600) })
    try await service().applyRetention(now: base.addingTimeInterval(3_600))
    XCTAssertEqual(left(), Set(names.suffix(3)))
  }

  /// A copy a day for ten days: the three newest, and one a day for the five days back, stay.
  func testAQuietWeekKeepsTheLatestAndOneADay() async throws {
    let names = try put((1...10).map { day(2026, 3, $0) })
    try await service().applyRetention(now: day(2026, 3, 10, 13))
    // Five days back from 10 March 13:00 is 5 March 13:00: the copies of 6…10 March are inside.
    XCTAssertEqual(left(), Set(names[5...]))
  }

  /// A busy day of many copies after a quiet stretch: the latest three are all of that day, and
  /// each earlier day within the window keeps its newest copy alone.
  func testABusyDayLeavesEachEarlierDayItsNewestCopy() async throws {
    let earlier = try put([day(2026, 5, 8, 9), day(2026, 5, 8, 18), day(2026, 5, 9, 7)])
    let busy = try put((0..<6).map { day(2026, 5, 10, 8).addingTimeInterval(Double($0) * 60) })
    try await service().applyRetention(now: day(2026, 5, 10, 9))
    XCTAssertEqual(left(), Set(busy.suffix(3)).union([earlier[1], earlier[2]]))
  }

  func testCopiesOlderThanTheWindowGo() async throws {
    let old = try put([day(2025, 1, 1), day(2025, 1, 2), day(2025, 1, 3)])
    let recent = try put([day(2026, 1, 1), day(2026, 1, 2), day(2026, 1, 3)])
    try await service().applyRetention(now: day(2026, 1, 3, 13))
    XCTAssertEqual(left(), Set(recent))
    XCTAssertTrue(left().isDisjoint(with: old))
  }

  /// The copies before an update are never pruned and take no place among the latest.
  func testTheCopiesBeforeAnUpdateStayAndCountForNothing() async throws {
    let migration = try put([day(2024, 1, 1), day(2025, 1, 1)], label: "before-migration")
    let regular = try put((1...6).map { day(2026, 2, $0) })
    try await service(latest: 3, days: 1).applyRetention(now: day(2026, 2, 6, 13))
    XCTAssertEqual(left(), Set(migration).union(regular.suffix(3)))
  }

  /// The copies before a restore and before an import are copies like the others.
  func testTheCopiesBeforeARestoreAreKeptByTheSameRule() async throws {
    let restore = try put([day(2026, 2, 1)], label: "before-restore")
    let regular = try put((2...5).map { day(2026, 2, $0) })
    try await service(latest: 3, days: 1).applyRetention(now: day(2026, 2, 5, 13))
    XCTAssertEqual(left(), Set(regular.suffix(3)))
    XCTAssertFalse(left().contains(restore[0]))
  }

  /// Whatever else lies in the folder is not ours to delete.
  func testFilesThatAreNotCopiesAreLeftAlone() async throws {
    let foreign = ["notes.txt", "other.sqlite", "finance-bogus.sqlite", "finance.sqlite"]
    for name in foreign {
      try Data("mine".utf8).write(to: directory.appendingPathComponent(name))
    }
    let regular = try put((1...6).map { day(2026, 2, $0) })
    try await service(latest: 2, days: 1).applyRetention(now: day(2026, 2, 6, 13))
    XCTAssertEqual(left(), Set(foreign).union(regular.suffix(2)))
  }

  /// The window is counted in days, and a leap February has a day more: 29 February is a day
  /// like any other inside it.
  func testTheLeapDayIsKeptInsideTheWindow() async throws {
    let names = try put([
      day(2028, 2, 26), day(2028, 2, 27), day(2028, 2, 28), day(2028, 2, 29), day(2028, 3, 1),
      day(2028, 3, 2),
    ])
    try await service(latest: 1, days: 4).applyRetention(now: day(2028, 3, 2, 13))
    // Four days back from 2 March 13:00 is 27 February 13:00.
    XCTAssertEqual(left(), Set(names[2...]))
    XCTAssertTrue(left().contains(names[3]), "29 February was not kept")
  }

  /// Copies across the end of a year keep one a day on both sides of it.
  func testTheWindowCrossesTheNewYear() async throws {
    let names = try put([
      day(2026, 12, 29), day(2026, 12, 30), day(2026, 12, 31), day(2027, 1, 1), day(2027, 1, 2),
    ])
    try await service(latest: 1, days: 3).applyRetention(now: day(2027, 1, 2, 13))
    XCTAssertEqual(left(), Set(names[2...]))
  }

  /// A clock set back leaves a copy «from the future»: it is the newest and it stays.
  func testACopyFromAClockSetBackStays() async throws {
    let future = try put([day(2030, 1, 1)])
    let regular = try put((1...4).map { day(2026, 2, $0) })
    try await service(latest: 2, days: 1).applyRetention(now: day(2026, 2, 4, 13))
    XCTAssertTrue(left().contains(future[0]))
    XCTAssertEqual(left(), Set(future).union([regular[3]]))
  }

  func testAFolderThatIsNotThereIsNoProblem() async throws {
    let missing = directory.appendingPathComponent("missing", isDirectory: true)
    try await service(folder: missing).applyRetention(now: day(2026, 1, 1))
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
  }

  /// The chosen folder keeps the same copies as the folder of copies, and the owner's files in
  /// it stay.
  func testTheChosenFolderIsPrunedByTheSameRuleAndKeepsTheOwnersFiles() async throws {
    let mirror = directory.appendingPathComponent("mirror", isDirectory: true)
    let local = directory.appendingPathComponent("local", isDirectory: true)
    for folder in [mirror, local] {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    try Data("mine".utf8).write(to: mirror.appendingPathComponent("tax-2025.pdf"))
    let instants = (1...6).map { day(2026, 4, $0) }
    let names = try put(instants, in: mirror)
    try put(instants, in: local)

    let backups = service(latest: 2, days: 1, folder: local)
    await backups.setMirror(mirror)
    try await backups.applyRetention(now: day(2026, 4, 6, 13))

    XCTAssertEqual(left(in: mirror), Set(names.suffix(2)).union(["tax-2025.pdf"]))
    XCTAssertEqual(left(in: local), Set(names.suffix(2)))
  }

  /// Applying the rule twice changes nothing the second time.
  func testRetentionIsStable() async throws {
    try put((1...10).map { day(2026, 7, $0) })
    let backups = service()
    try await backups.applyRetention(now: day(2026, 7, 10, 13))
    let once = left()
    try await backups.applyRetention(now: day(2026, 7, 10, 13))
    XCTAssertEqual(left(), once)
  }

  /// The listing of the Backups tab: only `.sqlite`, the newest first.
  func testTheListShowsOnlyCopiesNewestFirst() async throws {
    try Data("mine".utf8).write(to: directory.appendingPathComponent("readme.txt"))
    let names = try put([day(2026, 1, 3), day(2026, 1, 1), day(2026, 1, 2)])
    let listed = try await service().backups().map(\.lastPathComponent)
    XCTAssertEqual(listed, [names[0], names[2], names[1]])
  }

  func testTheListOfAFolderThatIsNotThereIsEmpty() async throws {
    let missing = directory.appendingPathComponent("nothing", isDirectory: true)
    let listed = try await service(folder: missing).backups()
    XCTAssertEqual(listed, [])
  }
}

/// Copies written from a real database: the label of each reason, two copies of one second,
/// the content of a copy, a database that never opened. Every copy is a whole SQLite file the
/// owner could put back.
final class DataScenarioBackupWriteTests: XCTestCase {
  private var directory: URL!
  private var stack: DatabaseStack!
  private var folder: URL { directory.appendingPathComponent("backups", isDirectory: true) }

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-f-write-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    for amount in [120, 340] {
      var draft = TransactionDraft(amount: AmountE4(whole: Int64(amount)), note: "synthetic")
      draft.normalizeSinglePart()
      try TransactionRepository(writer: stack.writer).save(try draft.materialize())
    }
  }

  override func tearDownWithError() throws {
    stack = nil
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  func testACopyHoldsEveryRowOfTheDatabase() async throws {
    let copy = try await BackupService(stack: stack, directory: folder).writeBackup()
    XCTAssertTrue(DatabaseStack.integrityCheckPassed(at: copy))
    XCTAssertEqual(try DatabaseStack.rowCounts(fileAt: copy)["transactions"], 2)
  }

  func testACopyIsNamedAfterTheMomentAsked() async throws {
    let now = Date(timeIntervalSince1970: 1_792_000_000)
    let copy = try await BackupService(stack: stack, directory: folder).writeBackup(now: now)
    XCTAssertEqual(copy.lastPathComponent, BackupService.fileName(at: now))
  }

  func testEveryReasonGivesItsLabel() async throws {
    let now = Date(timeIntervalSince1970: 1_792_000_000)
    let service = BackupService(stack: stack, directory: folder)
    for label in ["before-restore", "before-import"] {
      let copy = try await service.writeBackup(now: now, label: label)
      XCTAssertEqual(copy.lastPathComponent, BackupService.fileName(at: now, label: label))
    }
  }

  /// Two restores within one second: the second copy before a restore takes the next second's
  /// name and never the first one's place.
  func testTwoCopiesBeforeARestoreInOneSecondKeepBoth() async throws {
    let now = Date(timeIntervalSince1970: 1_792_000_000)
    let service = BackupService(stack: stack, directory: folder)
    let first = try await service.writeBackup(now: now, label: "before-restore")
    let second = try await service.writeBackup(now: now, label: "before-restore")
    XCTAssertNotEqual(first, second)
    XCTAssertEqual(
      second.lastPathComponent,
      BackupService.fileName(at: now.addingTimeInterval(1), label: "before-restore"))
    let listed = try await service.backups()
    XCTAssertEqual(listed.count, 2)
  }

  /// Copies after a change follow each other: the newer of one second stands for both.
  func testTwoCopiesAfterAChangeInOneSecondAreOne() async throws {
    let now = Date(timeIntervalSince1970: 1_792_000_000)
    let service = BackupService(stack: stack, directory: folder)
    let first = try await service.writeBackup(now: now)
    let second = try await service.writeBackup(now: now)
    XCTAssertEqual(first, second)
    let listed = try await service.backups()
    XCTAssertEqual(listed, [second])
  }

  func testASuccessfulCopyLeavesNoFailure() async throws {
    let service = BackupService(stack: stack, directory: folder)
    _ = try await service.writeBackup()
    let failure = await service.lastFailure
    XCTAssertNil(failure)
  }

  /// A copy written while a mirror is set reaches it under the same name.
  func testACopyReachesTheChosenFolderUnderItsName() async throws {
    let mirror = directory.appendingPathComponent("mirror", isDirectory: true)
    try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
    let service = BackupService(stack: stack, directory: folder)
    await service.setMirror(mirror)
    let copy = try await service.writeBackup()
    let there = mirror.appendingPathComponent(copy.lastPathComponent)
    XCTAssertTrue(DatabaseStack.integrityCheckPassed(at: there))
    let names = try FileManager.default.contentsOfDirectory(atPath: mirror.path)
    XCTAssertEqual(names, [copy.lastPathComponent], "a partial file was left in the folder")
  }

  /// A copy dropped before its debounce ran out is never written.
  func testACancelledCopyIsNeverWritten() async throws {
    var policy = BackupService.Policy()
    policy.debounce = .seconds(30)
    let service = BackupService(stack: stack, directory: folder, policy: policy)
    await service.scheduleBackup()
    await service.cancelPending()
    await service.waitForPendingCopy()
    let listed = try await service.backups()
    XCTAssertEqual(listed, [])
  }

  /// The quit writes the copy still waiting under the moment of the last change, not of the quit.
  func testTheQuitWritesTheWaitingCopyUnderTheMomentOfTheChange() async throws {
    var policy = BackupService.Policy()
    policy.debounce = .seconds(30)
    let service = BackupService(stack: stack, directory: folder, policy: policy)
    let change = Date(timeIntervalSince1970: 1_792_100_000)
    await service.scheduleBackup(now: change)
    await service.finish()
    let listed = try await service.backups().map(\.lastPathComponent)
    XCTAssertEqual(listed, [BackupService.fileName(at: change)])
  }

  /// A database file SQLite cannot read at all is still copied, byte for byte, and its copy is
  /// said not to pass.
  func testAFileThatIsNotADatabaseIsCopiedAsItIs() throws {
    let broken = directory.appendingPathComponent("broken.sqlite")
    let bytes = Data("not a database at all".utf8)
    try bytes.write(to: broken)
    let destination = directory.appendingPathComponent("copy.sqlite")
    let source = UnopenedDatabase(url: broken)
    try source.backup(to: destination)
    XCTAssertEqual(try Data(contentsOf: destination), bytes)
    XCTAssertFalse(try source.integrityCheckPassed())
  }

  /// A sound file that did not open for another reason is copied through SQLite and passes.
  func testASoundUnopenedDatabaseGivesASoundCopy() throws {
    let source = UnopenedDatabase(url: directory.appendingPathComponent("finance.sqlite"))
    let destination = directory.appendingPathComponent("copy.sqlite")
    try source.backup(to: destination)
    XCTAssertTrue(try source.integrityCheckPassed())
    XCTAssertTrue(DatabaseStack.integrityCheckPassed(at: destination))
    XCTAssertEqual(try DatabaseStack.rowCounts(fileAt: destination)["transactions"], 2)
  }

  /// The database files beside a name — the log, the shared memory, the journal — go with it.
  func testRemovingADatabaseTakesItsCompanionFiles() throws {
    let base = directory.appendingPathComponent("gone.sqlite")
    for suffix in ["", "-wal", "-shm", "-journal"] {
      try Data("x".utf8).write(to: URL(fileURLWithPath: base.path + suffix))
    }
    BackupService.removeDatabaseFiles(at: base, keepingTheFileItself: true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: base.path))
    for suffix in ["-wal", "-shm", "-journal"] {
      XCTAssertFalse(FileManager.default.fileExists(atPath: base.path + suffix), suffix)
    }
    BackupService.removeDatabaseFiles(at: base)
    XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
  }
}
