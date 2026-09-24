import AppCore
import AppDatabase
import XCTest

@testable import Itogo

/// «Бэкап после каждого изменения … через backup API, с проверкой целостности; в `backups/`,
/// копия — в выбранную папку в iCloud Drive; хранение: последние 50 копий и одна в день за
/// 90 дней». Every file the Backups tab lists is one the owner may restore, and the database
/// it replaces is deleted at the next launch: a file under a copy's name has to be a whole,
/// checked copy.
final class BackupServiceTests: XCTestCase {
  private var directory: URL!
  private var stack: DatabaseStack!
  private var backupsFolder: URL { directory.appendingPathComponent("backups", isDirectory: true) }

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-backups-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    var draft = TransactionDraft(amount: AmountE4(whole: 250), note: "synthetic")
    draft.normalizeSinglePart()
    try TransactionRepository(writer: stack.writer).save(try draft.materialize())
  }

  override func tearDownWithError() throws {
    stack = nil
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func contents(of folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
  }

  /// Whether the journal — opened by the test on a folder of its own — has a line with this in
  /// it. A line is written off the caller's turn, so the question waits a moment for it.
  private func journal(contains needle: String) async -> Bool {
    for _ in 0..<50 {
      if Logbook.shared.lines().contains(where: { $0.contains(needle) }) { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return false
  }

  // MARK: A copy that does not finish

  /// The copy stops halfway — here the database is closed under it, the way a full disk or an
  /// I/O error stops the backup API. Nothing is left that the Backups tab would offer to
  /// restore, and the failure is in the journal.
  func testACopyThatFailsHalfwayLeavesNothingToRestore() async throws {
    let logs = directory.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Task { Logbook.shared.close() } }
    let service = BackupService(stack: stack, directory: backupsFolder)
    try stack.close()

    do {
      _ = try await service.writeBackup()
      XCTFail("a copy of a closed database was written")
    } catch {}

    let listed = try await service.backups()
    XCTAssertEqual(listed, [], "a copy that never finished is offered for restore")
    XCTAssertEqual(contents(of: backupsFolder), [], "something was left behind")
    let logged = await journal(contains: "backup.failed")
    XCTAssertTrue(logged, "the failed copy is not in the journal")
  }

  /// «Бэкапы…: начало, результат, размер файла». The copy that runs by itself a few seconds
  /// after a change is the one nobody watches: a copy that fails there for a month has to be
  /// in the journal the problem report gathers — its start, its failure with the error's
  /// type, and never a path.
  func testTheCopyAfterAChangeWritesItsStartAndItsFailureInTheJournal() async throws {
    let logs = directory.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Task { Logbook.shared.close() } }
    var policy = BackupService.Policy()
    policy.debounce = .milliseconds(10)
    let service = BackupService(stack: stack, directory: backupsFolder, policy: policy)
    try stack.close()

    await service.scheduleBackup()

    let failed = await journal(contains: "backup.failed")
    XCTAssertTrue(failed, "the failed copy after a change is not in the journal")
    let lines = Logbook.shared.lines()
    let started = lines.firstIndex { $0.contains("backup.started") }
    let failure = try XCTUnwrap(lines.firstIndex { $0.contains("backup.failed") })
    XCTAssertNotNil(started, "the start of the copy is not in the journal")
    XCTAssertLessThan(started ?? .max, failure, "the copy failed before it started")
    XCTAssertTrue(lines[failure].contains("error="), lines[failure])
    XCTAssertFalse(
      lines.contains { $0.contains(directory.path) }, "a path of the owner's reached the journal")
  }

  /// A crash is not an error anybody catches: whatever is on disk at that moment stays. So
  /// while the copy is being written it has a name the list does not show, and it gets its
  /// own only once it is whole and checked.
  func testACopyIsWrittenUnderANameNoListShows() async throws {
    let source = RecordingSource(stack: stack)
    let service = BackupService(source: source, directory: backupsFolder)

    let copy = try await service.writeBackup()

    let writtenAt = try XCTUnwrap(source.destinations.first)
    XCTAssertNotEqual(
      writtenAt.pathExtension, "sqlite", "the copy was written under its final name")
    XCTAssertNotEqual(writtenAt, copy)
    let listed = try await service.backups()
    XCTAssertEqual(listed.map(\.lastPathComponent), [copy.lastPathComponent])
    XCTAssertEqual(contents(of: backupsFolder), [copy.lastPathComponent])
  }

  /// What a crash left behind is swept away by the next copy.
  func testWhatACrashLeftBehindGoesWithTheNextCopy() async throws {
    try FileManager.default.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
    let leftover = backupsFolder.appendingPathComponent("finance-2026-09-23T101500.sqlite.partial")
    try Data("half a copy".utf8).write(to: leftover)
    try Data("its journal".utf8).write(to: URL(fileURLWithPath: leftover.path + "-journal"))
    let service = BackupService(stack: stack, directory: backupsFolder)

    let copy = try await service.writeBackup()

    XCTAssertEqual(contents(of: backupsFolder), [copy.lastPathComponent])
  }

  // MARK: The name of a copy

  /// The hour the clocks go back is lived twice. A copy is named by the local time it was
  /// taken at, so the two copies of that hour, an hour apart, had one name — the second
  /// replaced the first — and the time read back from it was one of the two, whichever.
  func testTheHourTheClocksGoBackGivesTwoCopiesTwoNames() throws {
    let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    // 1 November 2026, 01:30 in summer time, and an hour later 01:30 again in winter time.
    let first = Date(timeIntervalSince1970: 1_793_511_000)
    let second = first.addingTimeInterval(3600)

    let firstName = BackupService.fileName(at: first, in: newYork)
    let secondName = BackupService.fileName(at: second, in: newYork)

    XCTAssertNotEqual(firstName, secondName, "two copies an hour apart share a name")
    XCTAssertEqual(BackupService.date(in: firstName), first)
    XCTAssertEqual(BackupService.date(in: secondName), second)
  }

  /// The owner flies from Moscow to Berlin: the copy written half an hour later reads an earlier
  /// hour. The list, and the retention that keeps the newest copies, go by when a copy was
  /// taken, not by how its name sorts.
  func testCopiesAreListedByWhenTheyWereTakenAcrossTimeZones() async throws {
    let moscow = try XCTUnwrap(TimeZone(identifier: "Europe/Moscow"))
    let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
    let inMoscow = Date(timeIntervalSince1970: 1_790_233_200)  // 24.09.2026, 10:00 there
    let inBerlin = inMoscow.addingTimeInterval(1_800)  // 09:30 there
    try FileManager.default.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
    let older = BackupService.fileName(at: inMoscow, in: moscow)
    let newer = BackupService.fileName(at: inBerlin, in: berlin)
    for name in [older, newer] {
      try Data("x".utf8).write(to: backupsFolder.appendingPathComponent(name))
    }
    let service = BackupService(stack: stack, directory: backupsFolder)

    let listed = try await service.backups().map(\.lastPathComponent)

    XCTAssertEqual(listed, [newer, older], "the newest copy is not listed first")
  }

  /// A copy after a change is named after the last change of the burst — the state it holds —
  /// not after the first: two changes four seconds apart across midnight make one copy, and it
  /// carries the new day.
  func testABurstAcrossMidnightIsNamedAfterItsLastChange() async throws {
    var policy = BackupService.Policy()
    policy.debounce = .milliseconds(20)
    let service = BackupService(stack: stack, directory: backupsFolder, policy: policy)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let midnight = try XCTUnwrap(
      calendar.date(from: DateComponents(year: 2026, month: 9, day: 25)))

    await service.scheduleBackup(now: midnight.addingTimeInterval(-2))
    await service.scheduleBackup(now: midnight.addingTimeInterval(2))
    await service.waitForPendingCopy()

    let names = try await service.backups().map(\.lastPathComponent)
    XCTAssertEqual(names, [BackupService.fileName(at: midnight.addingTimeInterval(2))])
    XCTAssertEqual(names.first.flatMap(BackupService.day(in:)), "2026-09-25")
  }

  /// Copies named before the offset was written keep being read, as the local time they are.
  func testACopyNamedWithoutAnOffsetIsReadAsLocalTime() throws {
    let name = "finance-2026-09-10T101500-before-restore.sqlite"
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let expected = calendar.date(
      from: DateComponents(year: 2026, month: 9, day: 10, hour: 10, minute: 15))
    XCTAssertEqual(BackupService.date(in: name), expected)
    XCTAssertEqual(BackupService.day(in: name), "2026-09-10")
  }

  // MARK: The Backups tab

  /// «Хранение: последние 50 копий и одна в день за 90 дней» — and «Восстановление — из
  /// настроек». The tab listed the newest twenty only, so the other thirty of the newest and
  /// every daily copy of the ninety days were kept on disk and out of reach. Every copy kept is
  /// listed: the newest in view, the rest under a disclosure.
  @MainActor
  func testTheBackupsTabListsEveryCopyThatIsKept() {
    let start = Date(timeIntervalSince1970: 1_789_000_000)
    let copies = (0..<140).map { index in
      backupsFolder.appendingPathComponent(
        BackupService.fileName(at: start.addingTimeInterval(-Double(index) * 86_400)))
    }

    let listing = BackupSettingsView.listing(of: copies)

    XCTAssertEqual(listing.recent + listing.older, copies, "a copy that is kept is not listed")
    XCTAssertLessThanOrEqual(listing.recent.count, 20)
  }

  /// The disclosure over the older copies counts them in the words of each language.
  @MainActor
  func testTheOlderCopiesAreCountedInBothLanguages() {
    let language = AppLanguage()
    let expected: [(AppLanguage.Choice, Int, String)] = [
      (.english, 1, "1 older copy"), (.english, 120, "120 older copies"),
      (.russian, 1, "1 более старая копия"), (.russian, 3, "3 более старые копии"),
      (.russian, 120, "120 более старых копий"),
    ]
    for (choice, count, words) in expected {
      language.choice = choice
      let format = language("backups.older", table: "Settings")
      XCTAssertEqual(String(format: format, locale: language.locale, count), words)
    }
  }

  // MARK: The check looks at the copy

  /// «Сразу после снятия проверяется целостность» — of the copy. Asking the
  /// live database says nothing about a file that came out wrong: here the database is sound
  /// and its copy is not a database at all.
  func testACopyThatFailsItsOwnCheckIsNotKept() async throws {
    let service = BackupService(
      source: DamagedSource(databaseIsSound: true), directory: backupsFolder)

    do {
      _ = try await service.writeBackup()
      XCTFail("a copy that is not a database was kept")
    } catch {
      XCTAssertEqual(error as? BackupError, .integrityCheckFailed)
    }
    let listed = try await service.backups()
    XCTAssertEqual(listed, [])
    XCTAssertEqual(contents(of: backupsFolder), [])
  }

  /// A copy that came out wrong from a sound database is not the state before a restore: it is
  /// a failed copy, and the restore stops. Only a damaged database keeps a damaged copy.
  func testABrokenCopyOfASoundDatabaseIsNotKeptEvenBeforeAReplacement() async throws {
    let service = BackupService(
      source: DamagedSource(databaseIsSound: true), directory: backupsFolder)

    do {
      _ = try await service.writeBackup(label: "before-restore", keepingADamagedCopy: true)
      XCTFail("a broken copy of a sound database was kept as the state before a restore")
    } catch {
      XCTAssertEqual(error as? BackupError, .integrityCheckFailed)
    }
    XCTAssertEqual(contents(of: backupsFolder), [])
  }

  // MARK: The mirrored folder

  private var mirrorFolder: URL { directory.appendingPathComponent("iCloud", isDirectory: true) }

  /// «Хранение: последние 50 копий и одна в день за 90 дней» holds for the copies, and the
  /// mirrored folder holds copies too: without it the owner's iCloud Drive grew by a copy per
  /// burst of edits, for ever. A file there that is not a copy of ours is never touched.
  func testTheMirroredFolderKeepsTheSameCopiesAsTheLocalOne() async throws {
    let manager = FileManager.default
    try manager.createDirectory(at: backupsFolder, withIntermediateDirectories: true)
    try manager.createDirectory(at: mirrorFolder, withIntermediateDirectories: true)
    // Named in Moscow time, where the hour stays inside one day: the count below is exact
    // whatever the zone of the Mac running the test.
    let moscow = try XCTUnwrap(TimeZone(identifier: "Europe/Moscow"))
    let start = Date(timeIntervalSince1970: 1_789_000_000)
    for index in 0..<60 {
      let name = BackupService.fileName(
        at: start.addingTimeInterval(Double(index) * 60), in: moscow)
      try Data("x".utf8).write(to: backupsFolder.appendingPathComponent(name))
      try Data("x".utf8).write(to: mirrorFolder.appendingPathComponent(name))
    }
    let owners = mirrorFolder.appendingPathComponent("a database of my own.sqlite")
    try Data("mine".utf8).write(to: owners)

    let service = BackupService(stack: stack, directory: backupsFolder)
    await service.setMirror(mirrorFolder)
    try await service.applyRetention(now: start.addingTimeInterval(3_600))

    let local = contents(of: backupsFolder)
    let mirrored = contents(of: mirrorFolder).filter { $0.hasPrefix("finance-") }
    XCTAssertEqual(mirrored.count, 50, "the mirrored folder is not pruned to the fifty newest")
    XCTAssertEqual(mirrored, local)
    XCTAssertTrue(manager.fileExists(atPath: owners.path), "a file of the owner's was deleted")
  }

  /// The folder was moved, renamed or went away with its volume. The copy is still written
  /// where it always is, but the owner is told the mirror failed, and so is the journal —
  /// which until now said `mirrored=yes` whenever a folder was merely set.
  func testAMirrorThatCannotBeWrittenIsReported() async throws {
    let logs = directory.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Task { Logbook.shared.close() } }
    let notAFolder = directory.appendingPathComponent("iCloud")
    try Data("a file where the folder was".utf8).write(to: notAFolder)
    let service = BackupService(stack: stack, directory: backupsFolder)
    await service.setMirror(notAFolder)

    let copy = try await service.writeBackup()

    XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
    let failure = await service.lastFailure
    XCTAssertEqual(failure, .notMirrored, "the settings screen is not told the mirror failed")
    let mirrorFailed = await journal(contains: "backup.mirrorFailed")
    XCTAssertTrue(mirrorFailed, "the journal is not told the mirror failed")
    let lines = Logbook.shared.lines()
    let written = try XCTUnwrap(lines.last { $0.contains("backup.written") })
    XCTAssertTrue(written.contains("mirrored=no"), written)
  }

  /// The copy lands in the mirrored folder the same way it lands in its own: under a name no
  /// list shows until it is whole, so iCloud Drive never carries half a copy under a good name.
  func testAMirroredCopyArrivesWhole() async throws {
    try FileManager.default.createDirectory(at: mirrorFolder, withIntermediateDirectories: true)
    let service = BackupService(stack: stack, directory: backupsFolder)
    await service.setMirror(mirrorFolder)

    let copy = try await service.writeBackup()

    XCTAssertEqual(contents(of: mirrorFolder), [copy.lastPathComponent])
    let mirrored = mirrorFolder.appendingPathComponent(copy.lastPathComponent)
    XCTAssertEqual(try Data(contentsOf: mirrored), try Data(contentsOf: copy))
    let failure = await service.lastFailure
    XCTAssertNil(failure)
  }

  /// The words the Backups tab shows for each failure, in both languages.
  @MainActor
  func testEveryFailureOfACopyHasWordsInBothLanguages() {
    let language = AppLanguage()
    let failures: [BackupService.Failure] = [.notWritten, .damaged, .notMirrored]
    let keys =
      failures.map(\.messageKey) + [
        BackupSettingsView.mirrorUnavailableKey, BackupSettingsView.dataSetMirrorsNowhereKey,
      ]
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys {
        XCTAssertNotEqual(language(key, table: "Settings"), key, "\(key) in \(choice.rawValue)")
      }
    }
  }

  /// A failed copy is named for the settings screen, and a good copy clears it.
  func testTheLastFailureIsWhatHappenedToTheLastCopy() async throws {
    let service = BackupService(
      source: DamagedSource(databaseIsSound: true), directory: backupsFolder)
    _ = try? await service.writeBackup()
    let afterBroken = await service.lastFailure
    XCTAssertEqual(afterBroken, .damaged)

    let sound = BackupService(stack: stack, directory: backupsFolder)
    try stack.close()
    _ = try? await sound.writeBackup()
    let afterClosed = await sound.lastFailure
    XCTAssertEqual(afterClosed, .notWritten)
  }
}

/// Writes real copies and remembers where it was asked to put them.
final class RecordingSource: BackupSource, @unchecked Sendable {
  private let stack: DatabaseStack
  private let lock = NSLock()
  private var written: [URL] = []

  init(stack: DatabaseStack) { self.stack = stack }

  var destinations: [URL] { lock.withLock { written } }

  func backup(to destination: URL) throws {
    lock.withLock { written.append(destination) }
    try stack.backup(to: destination)
  }

  func integrityCheckPassed() throws -> Bool { try stack.integrityCheckPassed() }
}

/// «Запасной путь — копия бэкапа в iCloud Drive». A folder whose bookmark no longer opens —
/// renamed, moved, gone with its volume — used to leave the app without a mirror and without
/// a word: the Backups tab went on showing its name, and the spare path could be dead
/// for months.
@MainActor
final class MirrorFolderAtLaunchTests: XCTestCase {
  private var environment: AppEnvironment?
  private var directory: URL!
  private var key: String!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["ITOGO_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-mirror-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("ITOGO_DATA_DIR", directory.path, 1)
    // A key of the test's own: the defaults of the test host are the owner's.
    key = "tests.backup.folder.\(UUID().uuidString)"
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    UserDefaults.standard.removeObject(forKey: key)
    if let dataDirectoryBefore {
      setenv("ITOGO_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("ITOGO_DATA_DIR")
    }
    try? FileManager.default.removeItem(at: directory)
  }

  private func start() async -> AppEnvironment {
    let environment = AppEnvironment()
    self.environment = environment
    environment.backupFolder = BookmarkStore(key: key)
    await environment.start()
    return environment
  }

  func testAFolderWhoseBookmarkNoLongerOpensIsSaidToBeUnavailable() async {
    UserDefaults.standard.set(Data("a bookmark that no longer opens".utf8), forKey: key)

    let environment = await start()

    XCTAssertNil(environment.mirrorFolder)
    XCTAssertTrue(environment.mirrorFolderUnavailable, "a dead mirror folder went unnoticed")
  }

  func testNoFolderChosenIsNotAFailure() async {
    let environment = await start()

    XCTAssertNil(environment.mirrorFolder)
    XCTAssertFalse(environment.mirrorFolderUnavailable)
  }

  /// Choosing a folder again is the way out, and it clears the warning.
  func testChoosingAFolderAgainClearsTheWarning() async {
    UserDefaults.standard.set(Data("a bookmark that no longer opens".utf8), forKey: key)
    let environment = await start()

    environment.useMirrorFolder(directory)

    XCTAssertFalse(environment.mirrorFolderUnavailable)
  }

  /// The tab names the folder the copies go to. A folder whose bookmark no longer opens is not
  /// that folder: its name stood beside «Choose folder…» as if the copies still reached it.
  func testTheTabNamesNoFolderWhenTheChosenOneDoesNotOpen() async throws {
    let chosen = directory.appendingPathComponent("Itogo Backups", isDirectory: true)
    try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
    var store = BookmarkStore(key: key)
    try store.save(chosen)
    store.startAccess = { _ in false }
    let environment = AppEnvironment()
    self.environment = environment
    environment.backupFolder = store
    await environment.start()

    XCTAssertTrue(environment.mirrorFolderUnavailable)
    XCTAssertNil(
      BackupSettingsView.shownFolder(in: environment),
      "a folder the copies do not reach is named as theirs")
  }

  /// The test host is the app itself, in the owner's container, so its defaults are the
  /// owner's. A test that opened the owner's folder would mirror synthetic copies into it, and
  /// a stale bookmark would be saved again by the test host.
  func testTheTestHostNeverReadsTheOwnersFolder() {
    XCTAssertNotEqual(AppEnvironment().backupFolder.key, "backup.folder")
  }

  // MARK: After an import

  /// Stages the database of an archive the way File → Import does, over a database in place.
  private func stageAnImport() async throws {
    let source = try DatabaseStack(
      url: directory.appendingPathComponent("other-mac/finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    let archives = ArchiveService(stack: source, appVersion: "0.1.0")
    let archive = directory.appendingPathComponent("transfer.itogoarchive")
    _ = try archives.exportArchive(to: archive)
    let backups = BackupService(
      stack: source, directory: directory.appendingPathComponent("other-mac/backups"))
    try await ArchiveImportFlow.stageReplacement(
      opened: try archives.openArchive(at: archive), archives: archives, backups: backups,
      target: AppPaths.pendingReplacementURL)
    try source.close()
    try DatabaseStack(url: AppPaths.databaseURL, schema: BundleSchemaSource(bundle: .main))
      .close()
  }

  /// «После импорта приложение просит заново выбрать папку для копий бэкапов: закладки не
  /// переносятся». On a new Mac nothing asked: the imported data was copied into
  /// `backups/` only, and the spare path in iCloud Drive was gone until the owner happened to
  /// open Settings → Backups.
  func testTheLaunchThatPutsAnImportInPlaceAsksForTheFolderOfTheCopies() async throws {
    try await stageAnImport()

    let environment = await start()

    XCTAssertEqual(environment.state, .ready)
    XCTAssertNil(environment.mirrorFolder)
    XCTAssertTrue(environment.asksForMirrorFolder, "nothing asks for the folder after an import")
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: AppPaths.importMark(for: AppPaths.pendingReplacementURL).path),
      "the next launch would ask again")
  }

  /// A restore of a copy on this Mac is not an import: nothing travelled, nothing is asked.
  func testTheLaunchThatPutsARestoreInPlaceDoesNotAsk() async throws {
    try DatabaseStack(url: AppPaths.databaseURL, schema: BundleSchemaSource(bundle: .main))
      .close()
    try DatabaseStack.backup(fileAt: AppPaths.databaseURL, to: AppPaths.pendingReplacementURL)

    let environment = await start()

    XCTAssertEqual(environment.state, .ready)
    XCTAssertFalse(environment.asksForMirrorFolder)
  }

  /// An archive imported on the Mac it came from: the folder chosen there still opens, and the
  /// copies already go to it.
  func testAnImportWithTheFolderStillWithinReachDoesNotAsk() async throws {
    try await stageAnImport()
    let chosen = directory.appendingPathComponent("Itogo Backups", isDirectory: true)
    try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
    var store = BookmarkStore(key: key)
    try store.save(chosen)
    store.startAccess = { _ in true }
    let environment = AppEnvironment()
    self.environment = environment
    environment.backupFolder = store
    await environment.start()

    XCTAssertNotNil(environment.mirrorFolder)
    XCTAssertFalse(environment.asksForMirrorFolder)
  }

  /// The words of the question, in both languages.
  func testTheQuestionAfterAnImportHasWordsInBothLanguages() {
    let language = AppLanguage()
    let keys = [
      "backups.afterImport.title", "backups.afterImport.message", "backups.afterImport.later",
      "settings.backups.choose",
    ]
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys {
        XCTAssertNotEqual(language(key, table: "Settings"), key, "\(key) in \(choice.rawValue)")
      }
    }
  }
}
