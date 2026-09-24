import AppCore
import AppDatabase
import Foundation

/// Makes a copy of the database after every change.
///
/// Rules from the specification: a copy is written a few seconds after the last change, so a
/// burst of edits produces one file; copies go through the SQLite backup API and are checked
/// for integrity; the live database is never placed in iCloud, only copies are mirrored into
/// a folder the owner picks.
public actor BackupService {
  public struct Policy: Sendable {
    /// How long to wait after the last change before writing a copy.
    public var debounce: Duration = .seconds(5)
    /// Keep the newest copies…
    public var keepLatest = 50
    /// …and one copy per day for this many days.
    public var keepDailyForDays = 90

    public init() {}
  }

  private let source: any BackupSource
  private let directory: URL
  private let policy: Policy
  private var pending: Task<Void, Never>?
  private var mirror: URL?
  /// What went wrong with the last copy, for the Backups settings to show. The journal has the
  /// error's type; the owner reads words from the Settings catalog.
  public private(set) var lastFailure: Failure?

  public enum Failure: Sendable, Equatable {
    /// The copy was not written.
    case notWritten
    /// The copy did not pass its integrity check.
    case damaged
    /// The copy was written, but it did not reach the chosen folder.
    case notMirrored

    public var messageKey: String {
      switch self {
      case .notWritten: "backups.failure.notWritten"
      case .damaged: "backups.failure.damaged"
      case .notMirrored: "backups.failure.notMirrored"
      }
    }
  }

  public init(stack: DatabaseStack, directory: URL, policy: Policy = Policy()) {
    self.init(source: stack, directory: directory, policy: policy)
  }

  init(source: any BackupSource, directory: URL, policy: Policy = Policy()) {
    self.source = source
    self.directory = directory
    self.policy = policy
  }

  /// The folder the owner picked, usually inside iCloud Drive. Access is opened by the
  /// caller through a security-scoped bookmark.
  public func setMirror(_ url: URL?) {
    mirror = url
  }

  /// Drops a copy that has not been written yet: nothing is left to run against a database
  /// that is closing.
  public func cancelPending() {
    pending?.cancel()
    pending = nil
    pendingSince = nil
  }

  /// Drop the copy in flight and arm no more. `cancelPending()` alone only cancels the one
  /// task — the next write, and there is one for the whole of the terminate-later window,
  /// would arm another against a closed database.
  public func disable() {
    isDisabled = true
    cancelPending()
  }

  /// The database is going (`AppEnvironment.close()`): the copy still waiting out its debounce
  /// is written now, while the database is open, and no more are armed. The debounce is there
  /// so a burst of edits makes one copy, not so the last edit makes none: dropped at the quit,
  /// that edit was in no copy — neither in `backups/` nor in the mirrored folder — until some
  /// later session wrote again.
  public func finish() {
    isDisabled = true
    let waiting = pendingSince
    cancelPending()
    if let waiting { writeBackupIgnoringCancellation(now: waiting) }
  }

  private var isDisabled = false
  /// When the copy waiting out its debounce was asked for; `nil` when none is waiting.
  private var pendingSince: Date?

  /// Call after every change: a burst of calls results in a single copy. The copy is named
  /// after the last change of the burst — every call moves the moment on — which is the state
  /// it holds: no change came after it, or the copy would have been moved on again.
  public func scheduleBackup(now: Date = Date()) {
    guard !isDisabled else { return }
    pending?.cancel()
    pendingSince = now
    pending = Task { [policy] in
      try? await Task.sleep(for: policy.debounce)
      guard !Task.isCancelled else { return }
      self.writePending()
    }
  }

  /// Returns once the copy armed by `scheduleBackup` has run its course — written, failed or
  /// dropped — and none is armed any more. The tests ask this instead of sleeping for longer
  /// than the debounce and hoping the copy was done by then.
  func waitForPendingCopy() async {
    while let task = pending {
      await task.value
      if pending == task { return }
    }
  }

  /// The debounce ran out. Nothing is waiting any more once the copy starts: `finish()` must
  /// not write it a second time.
  private func writePending() {
    guard let since = pendingSince else { return }
    pending = nil
    pendingSince = nil
    writeBackupIgnoringCancellation(now: since)
  }

  /// The debounced path: a failure here must not crash anything, and it does not vanish either
  /// — `writeBackup` keeps the reason for the settings screen and writes the start and the
  /// outcome in the journal.
  private func writeBackupIgnoringCancellation(now: Date) {
    _ = try? writeBackup(now: now)
  }

  /// Writes a copy immediately — used before an archive import and before restoring.
  ///
  /// A copy that fails its check is not kept: it would take the place of a good one in the
  /// retention. `keepingADamagedCopy` is for the copy written before the database is replaced:
  /// when the database itself is damaged, its copy is still the only state there is to come
  /// back to, so it is kept under a name that says so.
  @discardableResult
  public func writeBackup(
    now: Date = Date(), label: String? = nil, keepingADamagedCopy: Bool = false
  ) throws -> URL {
    // «Бэкапы…: начало, результат, размер файла»: the start, and why this copy — after a
    // change, before a restore, before an import.
    AppLog.info(
      "backup.started", .backup, "a copy of the database is being written",
      [LogPair("reason", .token(label ?? "change"))])
    let written: (url: URL, isDamaged: Bool)
    do {
      written = try writeCheckedCopy(
        now: now, label: label, keepingADamagedCopy: keepingADamagedCopy)
    } catch {
      lastFailure = (error as? BackupError) == .integrityCheckFailed ? .damaged : .notWritten
      AppLog.error(
        "backup.failed", .backup, "a copy of the database was not written",
        [LogPair("error", .error(error))])
      throw error
    }
    let destination = written.url

    // `mirrored` says where the copy arrived, not whether a folder is set.
    let mirrored = mirror.map { copy(destination, into: $0) }
    lastFailure = written.isDamaged ? .damaged : mirrored == false ? .notMirrored : nil
    let size =
      (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
    AppLog.info(
      "backup.written", .backup, "a copy of the database was written",
      [LogPair("bytes", .bytes(size)), LogPair("mirrored", .flag(mirrored == true))])

    try applyRetention(now: now)
    return destination
  }

  /// Puts a finished copy into the mirrored folder the way it was written into its own: under a
  /// name no list shows, renamed once whole, so iCloud Drive never carries half a copy under a
  /// good copy's name. Returns whether it arrived; when it did not, the journal says why.
  private func copy(_ copy: URL, into mirror: URL) -> Bool {
    let manager = FileManager.default
    let name = copy.lastPathComponent
    let partial = mirror.appendingPathComponent(name + Self.unfinished)
    defer { try? manager.removeItem(at: partial) }
    do {
      Self.removeUnfinishedCopies(in: mirror)
      try manager.copyItem(at: copy, to: partial)
      let mirrored = mirror.appendingPathComponent(name)
      Self.removeDatabaseFiles(at: mirrored, keepingTheFileItself: true)
      try manager.putInPlace(partial, at: mirrored)
      return true
    } catch {
      AppLog.error(
        "backup.mirrorFailed", .backup, "a copy did not reach the chosen folder",
        [LogPair("error", .error(error))])
      return false
    }
  }

  /// The copy is written under a name no list shows — `backups()` takes only `.sqlite` — and
  /// is given its own only once it is whole and checked, by one rename. A copy cut short by a
  /// full disk, an I/O error or a crash never carries the name of a good one; what a crash
  /// left behind goes with the next copy.
  private func writeCheckedCopy(
    now: Date, label: String?, keepingADamagedCopy: Bool
  ) throws -> (url: URL, isDamaged: Bool) {
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    Self.removeUnfinishedCopies(in: directory)

    var name = Self.fileName(at: now, label: label)
    var isDamaged = false
    let partial = directory.appendingPathComponent(name + Self.unfinished)
    defer { Self.removeDatabaseFiles(at: partial) }
    try source.backup(to: partial)

    // The copy is checked, not the database it came from: that is the file somebody may put in
    // place of the database one day. The database is asked only when its copy fails — a sound
    // database with a broken copy is a failed copy; a damaged one has no better copy to give.
    if !DatabaseStack.integrityCheckPassed(at: partial) {
      let databaseIsDamaged = (try? source.integrityCheckPassed()) != true
      guard keepingADamagedCopy, databaseIsDamaged else {
        throw BackupError.integrityCheckFailed
      }
      name = Self.fileName(at: now, label: Self.damaged(label))
      isDamaged = true
      AppLog.warning(
        "backup.damaged", .backup,
        "the database failed its integrity check; its copy is kept, marked as damaged")
    }

    let destination = directory.appendingPathComponent(name)
    // A log beside an earlier copy of the same name belongs to that copy, not to this one.
    Self.removeDatabaseFiles(at: destination, keepingTheFileItself: true)
    try manager.putInPlace(partial, at: destination)
    return (destination, isDamaged)
  }

  /// The suffix of a copy that is still being written.
  static let unfinished = ".partial"

  private static func removeUnfinishedCopies(in folder: URL) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    for name in names where name.hasPrefix("finance-") && name.contains(".sqlite" + Self.unfinished)
    {
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
  }

  /// A database on disk is up to four files: the file itself, its write-ahead log, the shared
  /// memory and the rollback journal.
  static func removeDatabaseFiles(at url: URL, keepingTheFileItself: Bool = false) {
    let parts =
      keepingTheFileItself ? ["-wal", "-shm", "-journal"] : ["", "-wal", "-shm", "-journal"]
    for part in parts {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + part))
    }
  }

  public func backups() throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return Self.newestFirst(
      try FileManager.default
        .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "sqlite" })
  }

  /// Keeps the newest copies and one per day for the retention window — in the folder of copies
  /// and in the mirrored one alike: «хранение: последние 50 копий и одна в день за 90 дней» is
  /// about the copies, wherever they lie. A prune of the mirrored folder that fails is written
  /// in the journal and costs the copy nothing.
  func applyRetention(now: Date) throws {
    try applyRetention(in: directory, now: now)
    guard let mirror else { return }
    do {
      try applyRetention(in: mirror, now: now)
    } catch {
      AppLog.warning(
        "backup.mirrorPruneFailed", .backup, "old copies in the chosen folder were not pruned",
        [LogPair("error", .error(error))])
    }
  }

  /// Only files named as our copies are looked at: the mirrored folder is the owner's, and
  /// anything else in it is not ours to delete.
  private func applyRetention(in folder: URL, now: Date) throws {
    guard FileManager.default.fileExists(atPath: folder.path) else { return }
    let files = Self.newestFirst(
      try FileManager.default
        .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "sqlite" && Self.date(in: $0.lastPathComponent) != nil })
    guard files.count > policy.keepLatest else { return }

    var keep = Set(files.prefix(policy.keepLatest))
    var seenDays = Set<String>()
    let cutoff = now.addingTimeInterval(-Double(policy.keepDailyForDays) * 24 * 3600)

    for file in files {
      let name = file.lastPathComponent
      guard let day = Self.day(in: name), let stamp = Self.date(in: name) else { continue }
      if stamp >= cutoff, !seenDays.contains(day) {
        seenDays.insert(day)
        keep.insert(file)
      }
    }

    for file in files where !keep.contains(file) {
      try? FileManager.default.removeItem(at: file)
    }
  }

  /// `finance-2026-09-24T101500+0300.sqlite`: the local time the copy was taken at, and the
  /// offset of that time from UTC. The local time is what the owner reads in the list; the
  /// offset makes the name one instant — the hour the clocks go back is lived twice, and a
  /// flight moves the clock — so no two copies share a name and each is read back as the
  /// moment it was taken.
  static func fileName(
    at instant: Date, label: String? = nil, in timeZone: TimeZone = .current
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = stampFormat + "Z"
    let stamp = formatter.string(from: instant)
    let suffix = label.map { "-\($0)" } ?? ""
    return "finance-\(stamp)\(suffix).sqlite"
  }

  private static let stampFormat = "yyyy-MM-dd'T'HHmmss"

  /// The label of a copy kept although it failed its check: `before-restore-damaged`.
  static func damaged(_ label: String?) -> String {
    [label, "damaged"].compactMap { $0 }.joined(separator: "-")
  }

  static func day(in fileName: String) -> String? {
    guard fileName.hasPrefix("finance-"), fileName.count > 18 else { return nil }
    return String(fileName.dropFirst(8).prefix(10))
  }

  /// The moment a copy was taken, read from its name. A name without an offset — copies
  /// written before the offset was — is read as the local time it is.
  static func date(in fileName: String) -> Date? {
    guard fileName.hasPrefix("finance-") else { return nil }
    let rest = fileName.dropFirst(8)
    let stamp = String(rest.prefix(17))
    let offset = rest.dropFirst(17).prefix(5)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    if offset.count == 5, let sign = offset.first, sign == "+" || sign == "-",
      offset.dropFirst().allSatisfy({ $0.isASCII && $0.isNumber })
    {
      formatter.dateFormat = stampFormat + "Z"
      return formatter.date(from: stamp + offset)
    }
    formatter.timeZone = TimeZone.current
    formatter.dateFormat = stampFormat
    return formatter.date(from: stamp)
  }

  /// Newest first, by when the copies were taken — not by how their names sort, which an offset
  /// that changed would put out of order. The name decides between copies of one moment.
  static func newestFirst(_ copies: [URL]) -> [URL] {
    copies
      .map { (url: $0, name: $0.lastPathComponent, taken: date(in: $0.lastPathComponent)) }
      .sorted { lhs, rhs in
        switch (lhs.taken, rhs.taken) {
        case (let left?, let right?) where left != right: left > right
        case (_?, nil): true
        case (nil, _?): false
        default: lhs.name > rhs.name
        }
      }
      .map(\.url)
  }
}

/// What a copy is taken from. The application passes its `DatabaseStack`; a test passes a
/// source that fails halfway, or one that writes something that is not a database.
protocol BackupSource: Sendable {
  func backup(to destination: URL) throws
  func integrityCheckPassed() throws -> Bool
}

extension DatabaseStack: BackupSource {}

/// The database file when it did not open (`AppEnvironment.start`): a schema of a newer build,
/// a file the disk damaged. That is when a copy is needed most, so the Backups tab still lists
/// the copies and restores one — and the state before the restore is still copied first.
///
/// SQLite reads what it can through the backup API, as the file is: nothing is migrated or
/// written. A file SQLite cannot read at all is copied byte for byte; its copy then fails the
/// check and is kept marked as damaged, like the copy of any damaged database.
struct UnopenedDatabase: BackupSource {
  let url: URL

  func backup(to destination: URL) throws {
    do {
      try DatabaseStack.backup(fileAt: url, to: destination)
    } catch {
      BackupService.removeDatabaseFiles(at: destination)
      try FileManager.default.copyItem(at: url, to: destination)
    }
  }

  func integrityCheckPassed() throws -> Bool {
    DatabaseStack.integrityCheckPassed(at: url)
  }
}

public enum BackupError: Error, Sendable {
  case integrityCheckFailed
  case restoreFailed
}
