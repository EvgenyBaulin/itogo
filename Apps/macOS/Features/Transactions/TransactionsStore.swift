import AppCore
import AppDatabase
import Foundation
import OSLog
import Observation

/// What one write of the store changed, as the app laid it over its data: the operations
/// as they are now, the ones that went, and parts whose status moved without their
/// operation being rewritten.
public struct StoreWrite: Sendable {
  public var upserted: [TransactionEntry] = []
  public var removed: [UUID] = []
  public var partStatuses: [UUID: ReimbursementStatus] = [:]

  public init(
    upserted: [TransactionEntry] = [], removed: [UUID] = [],
    partStatuses: [UUID: ReimbursementStatus] = [:], planningChanged: Bool = false
  ) {
    self.upserted = upserted
    self.removed = removed
    self.partStatuses = partStatuses
    self.planningChanged = planningChanged
  }

  /// Rows of planning changed with it (payments, limits, goals, reconciliations, journals):
  /// the pipeline reads them again at once rather than waiting for the observation.
  public var planningChanged = false

  public var isEmpty: Bool {
    upserted.isEmpty && removed.isEmpty && partStatuses.isEmpty && !planningChanged
  }

  /// The operations the write touched.
  public var touchedIds: [UUID] { upserted.map(\.id) + removed }
}

/// A write of the store that did not land («блок показывает сообщение…, ошибка уходит
/// в журнал»).
public struct StoreFailure: Hashable, Sendable {
  /// What the write was doing — the word the journal gets, too.
  public enum Action: String, Hashable, Sendable {
    case save, planning, edit, change, delete, undo

    /// The entry line, the editor and the actions of planning get the failure back and say
    /// it in their own words. ⌘Z, a bulk change and a deletion — above all one that lands
    /// off the main thread — have nobody to say it but the screen.
    var isShownByTheScreen: Bool {
      switch self {
      case .save, .planning, .edit: false
      case .change, .delete, .undo: true
      }
    }
  }

  public var action: Action
  public var cause: WriteFailureCause

  public init(action: Action, cause: WriteFailureCause) {
    self.action = action
    self.cause = cause
  }
}

/// Performs every change through the repository and keeps ⌘Z. The lists do not come from
/// here any more: they are the data of the calculation pipeline (`ComputeStore`), which
/// hands its ledger over after every change (`show`), so the menus and the confirmations
/// read the very operations the lists show. Deletion is soft, so undo is a single restore.
///
/// A bulk write of more than `backgroundThreshold` operations — a change, a deletion or
/// the undo of one — goes through `await writer.write`, off the main thread.
/// It is still one write and one step of ⌘Z, and `didWrite` still follows it; it only
/// lands a moment later, and its step takes the place in the stack it was asked for in.
@MainActor
@Observable
public final class TransactionsStore {
  public struct DayGroup: Identifiable, Sendable {
    public let day: DateOnly
    /// Spending and refunds of spending.
    public let expenses: [TransactionEntry]
    /// Income, and the money people gave back. A reimbursement is listed here because money
    /// came in, but it is not income: the row says so and `totals` never adds it to income.
    public let income: [TransactionEntry]
    /// What the day comes to — the same function the selection and the delete confirmation
    /// use, so selecting the whole day shows exactly the numbers of its header. Transfers are
    /// in none of it: money moved between the owner's own accounts is neither earned nor spent.
    /// A refund taken back from a purchase counts on the purchase's day, as the purchase
    /// made cheaper, and adds nothing on its own day.
    public let totals: RowTotals
    /// Money moved that day between the owner's own accounts, newest first: rows of their own,
    /// after the income and the spending.
    public let transfers: [Transfer]

    /// `refunds` are the refunds of the whole ledger: a purchase listed here shows what a
    /// refund made on a later day took back, and a refund listed here whose purchase is on
    /// another day adds nothing — the same numbers as Overview and the selection.
    public init(
      day: DateOnly, expenses: [TransactionEntry], income: [TransactionEntry],
      debts: [UUID: Debt] = [:], transfers: [Transfer] = [], refunds: RefundIndex = .empty
    ) {
      self.day = day
      self.expenses = expenses
      self.income = income
      self.transfers = transfers
      self.totals = RowTotals(entries: income + expenses, debts: debts, refunds: refunds)
    }

    public var id: String { day.iso }
    public var entries: [TransactionEntry] { income + expenses }
    /// Everything of the day a list can select: the operations, then the transfers.
    public var selectableIds: [UUID] { entries.map(\.id) + transfers.map(\.id) }

    /// Which side of a day an operation is listed on.
    nonisolated static func isListedWithIncome(_ kind: TransactionKind) -> Bool {
      kind == .income || kind == .reimbursement
    }
  }

  /// The type of the error of the last write that failed.
  public private(set) var lastError: String?
  /// A failed write nobody else reports — ⌘Z, a bulk change, a deletion — for the alert of
  /// the screen (`operationPresentations`); `nil` once it has been seen.
  public private(set) var failure: StoreFailure?

  public func forgetFailure() { failure = nil }
  /// The data the lists show, from the pipeline; `nil` until its first read.
  public private(set) var listing: Ledger?

  /// Bulk writes of more operations than this leave the main thread. ⌘A over the two
  /// months Overview lists selects about 1 700 operations of the large sample, and a write
  /// that size, made where the window draws, would freeze it.
  public nonisolated static let backgroundThreshold = 1_000

  /// A bulk write too large for the main thread is on its way. The selection bar says so
  /// and disables its buttons, and the store takes no other bulk write and no undo until it
  /// lands. One operation can still be saved meanwhile — the entry line is never locked —
  /// and its step stays above the step of the bulk write, which lands where it was asked
  /// for: ⌘Z takes back the last thing the owner did first.
  public private(set) var isWritingInBackground = false
  /// That write, for a caller that has to wait for it: the tests. Whether it landed.
  @ObservationIgnored public private(set) var backgroundWrite: Task<Bool, Never>?

  /// Called after every write that landed — undo included — with what it changed. The app
  /// hangs the backup on it (a copy after every change) and lays the change over the
  /// pipeline's data, so the new row and the numbers appear at once.
  public var didWrite: (@MainActor (StoreWrite) -> Void)?

  /// Empty until the database has been opened, so the window can render immediately.
  private var repository: TransactionRepository?
  private var references: ReferenceRepository?
  /// The one write path of planning: an action and its operations in one write.
  private var planning: PlanningRepository?
  private var undoStack: [UndoStep] = []
  /// How far back ⌘Z reaches; a test sets smaller numbers.
  @ObservationIgnored var undoDepth = UndoDepth()
  /// Moves on every time the history is forgotten. A bulk write that set off before that
  /// leaves no step when it lands: its undo would reach across the write the history was
  /// forgotten for.
  @ObservationIgnored private var undoEpoch = 0

  /// How far back ⌘Z reaches: at most `levels` steps, and at most `operations` operations to
  /// write back across them — a bulk change keeps a copy of every operation it touched, and a
  /// session of «apply to past operations» on a large history kept hundreds of megabytes
  /// until quit. The oldest steps go first; the newest is kept whatever its size, so the last
  /// thing done can always be taken back.
  struct UndoDepth: Sendable {
    var levels = 100
    /// A little more than the whole large sample: one change of all of it fits.
    var operations = 25_000
  }

  private enum UndoStep: Sendable {
    case created(UUID)
    /// One operation edited, with the journal lines the edit moved (`EditedEntry`).
    case edited(EditedEntry)
    /// One bulk change: the operations as they were before it.
    case editedMany([TransactionEntry])
    /// One deletion, of one operation or many, with everything it took along.
    case deletedMany([UUID], DeletionEffects)
    /// One action of planning — «Mark as paid», a contribution, a reconciliation, a limit, a
    /// transfer — with the operations it created, rewrote and deleted.
    case planned(PlanningUndo)

    /// How many operations undoing it writes.
    var size: Int {
      switch self {
      case .created, .edited: 1
      case .editedMany(let before): before.count
      case .deletedMany(let ids, let effects): ids.count + effects.companionIds.count
      case .planned(let undo):
        max(
          1,
          undo.createdTransactionIds.count + undo.rewrittenBefore.count
            + undo.deletion.deletedIds.count + undo.deletion.companionIds.count)
      }
    }
  }

  /// What a write leaves behind once it has landed: the step that takes it back — none for
  /// an undo — and what it changed.
  private struct Landed: Sendable {
    var step: UndoStep?
    var write: StoreWrite
  }

  public init(repository: TransactionRepository? = nil, references: ReferenceRepository? = nil) {
    self.repository = repository
    self.references = references
    self.standInFor = nil
  }

  /// The store of the stand-in dependencies, named after the view file that went without.
  public init(standInFor reader: String) {
    self.repository = nil
    self.references = nil
    self.standInFor = reader
  }

  /// True once the database has been opened and handed over.
  public private(set) var isAttached = false

  /// Lets go of the database: the repositories, the report of what was written and the undo
  /// history, which belongs to rows that are about to be out of reach. After this a write
  /// finds no repository and does nothing, instead of reaching a closed connection.
  public func detach() {
    repository = nil
    references = nil
    planning = nil
    didWrite = nil
    letGoOfTheDatabase()
    isAttached = false
  }

  public func attach(
    _ repository: TransactionRepository, references: ReferenceRepository?,
    planning: PlanningRepository? = nil
  ) {
    self.repository = repository
    self.references = references
    self.planning = planning
    letGoOfTheDatabase()
    isAttached = true
  }

  /// Moves on every time the store is handed a database or lets one go. A bulk write still
  /// on its way was asked of the database before: it lands there, and the store no longer
  /// waits for it (`land`).
  @ObservationIgnored private var attachment = 0

  /// Forgets what belonged to the database the store held: the steps of ⌘Z, which would undo
  /// into rows that are not there, and a bulk write on its way to it — the database the store
  /// holds now has no write on its way, and its `didWrite` must not hear of that one.
  private func letGoOfTheDatabase() {
    forgetUndoHistory()
    attachment += 1
    isWritingInBackground = false
    backgroundWrite = nil
  }

  // MARK: The stand-in

  /// Set when this store belongs to the stand-in dependencies: a view was shown without the
  /// app's own store, and nothing it writes can land anywhere. Every attempt says so in the
  /// log and on screen rather than failing quietly.
  private let standInFor: String?
  /// The view file of the last refused write; what the screen shows an alert about.
  public private(set) var refusal: String?

  private static let standInLog = Logger(
    subsystem: "io.github.EvgenyBaulin.itogo", category: "dependencies")

  public func forgetRefusal() { refusal = nil }

  /// True when the write must not even be attempted, having been announced as refused.
  private func refuses(_ what: String, _ file: String) -> Bool {
    guard let standInFor else { return false }
    Self.standInLog.fault(
      "a write was refused: \(standInFor, privacy: .public) asked \(what, privacy: .public) from \(file, privacy: .public)"
    )
    refusal = standInFor
    return true
  }

  /// The pipeline's ledger, after each of its reads and rebuilds.
  public func show(_ ledger: Ledger) {
    listing = ledger
  }

  // MARK: Reading what the lists show

  /// The listed operations with these ids, newest first.
  public func entries(ids: Set<UUID>) -> [TransactionEntry] {
    guard let listing else { return [] }
    return ids.compactMap { listing.entry($0) }
      .sorted { $0.transaction.occurredAt > $1.transaction.occurredAt }
  }

  public func entry(id: UUID) -> TransactionEntry? { listing?.entry(id) }

  public func totals(ids: Set<UUID>) -> RowTotals {
    listing?.rowTotals(of: ids) ?? .zero
  }

  /// Every debt, closed ones included: whether a payment is spending depends on its debt,
  /// and closing a loan must not change the days it was paid on.
  public var debts: [UUID: Debt] { listing?.debtsById ?? [:] }

  /// The categories as the dictionary holds them right now, archived ones included. Read on
  /// every call and never kept: Settings adds, re-rates and archives categories without
  /// going through the store, and a bulk change judged by an older copy would file money
  /// into a retired category, refuse a new one, or rate by a quality that is gone. The
  /// popover of a bulk change offers categories from here too, so it offers what the rule
  /// accepts.
  public func categories() -> [CoreKit.Category] {
    (try? references?.categories(includeArchived: true)) ?? []
  }

  // MARK: Writing one operation

  /// Writes an operation and returns whether it actually landed, so the entry line only
  /// clears itself over a save that happened.
  ///
  /// Whether this creates or replaces is read from the database rather than taken from the
  /// caller. Undoing a creation is a physical delete, and there is no way back from one: a
  /// call site that says "new" about an operation that was already there would turn ⌘Z
  /// into a shredder.
  @discardableResult
  public func save(_ entry: TransactionEntry, file: String = #fileID) -> Bool {
    guard !refuses("save", file), let repository else { return false }
    do {
      let previous = try repository.entry(id: entry.id)
      // What the write wrote: an operation that named no account is on the main one now, and
      // that is what the lists show and what ⌘Z takes back.
      let written = try repository.save(entry)
      push(
        previous.map { .edited(EditedEntry(before: $0, after: written)) } ?? .created(written.id))
      finishWrite(StoreWrite(upserted: [written]))
      return true
    } catch {
      failed(.save, error, file: file)
      return false
    }
  }

  // MARK: Planning

  /// Writes one action of planning in one write and keeps one step of ⌘Z for it: the
  /// operations it creates, rewrites and deletes, the rows of planning it inserts, changes or
  /// deletes, and the settings it sets. Returns whether it landed.
  @discardableResult
  public func apply(_ change: PlanningChange, file: String = #fileID) -> Bool {
    guard !refuses("apply(PlanningChange)", file) else { return false }
    guard let planning else { return false }
    do {
      let undo = try planning.apply(change)
      push(.planned(undo))
      finishWrite(Self.applied(change, undo: undo))
      return true
    } catch {
      failed(.planning, error, file: file)
      return false
    }
  }

  /// What a change of planning wrote, as the lists lay it over their data: the operations it
  /// created and rewrote as the write left them — an operation that named no account is on
  /// the main one —, the ones it deleted with the surplus and shortfalls that went along, and
  /// the parts the deletion reopened.
  nonisolated static func applied(_ change: PlanningChange, undo: PlanningUndo) -> StoreWrite {
    let written = Set(undo.written.map(\.id))
    // Anything the write did not hand back is laid as it was asked for.
    let rewritten = change.rewritten.map { entry in
      var stamped = entry
      stamped.transaction.updatedAt = change.at
      return stamped
    }
    let asked = (change.created + rewritten).filter { !written.contains($0.id) }
    return StoreWrite(
      upserted: undo.written + asked,
      removed: undo.deletion.deletedIds + undo.deletion.companionIds,
      partStatuses: statuses(undo.deletion.reopenedPartIds, .expected),
      planningChanged: true)
  }

  /// What the undo of a change of planning wrote: the operations it created are gone, and the
  /// ones it rewrote or deleted are back — as they are after the undo, read again, the live
  /// ones only — with the parts a deletion had reopened closed again.
  nonisolated static func reverted(
    _ undo: PlanningUndo, readBack: [TransactionEntry]
  ) -> StoreWrite {
    StoreWrite(
      upserted: readBack.filter { !$0.transaction.isDeleted },
      removed: undo.createdTransactionIds,
      partStatuses: statuses(undo.deletion.reopenedPartIds, .returned),
      planningChanged: true)
  }

  /// The operations the undo of a change of planning brings back.
  nonisolated static func broughtBack(by undo: PlanningUndo) -> [UUID] {
    undo.rewrittenBefore.map(\.id) + undo.deletion.deletedIds + undo.deletion.companionIds
  }

  /// What became of the edit of a saved operation.
  public enum EditOutcome: Equatable, Sendable {
    case saved
    /// The operation was deleted after the editing began: there is nothing to save the
    /// edit over, and writing it would bring the operation back.
    case gone
    /// The write failed; `lastError` says how.
    case failed
    /// The edit may not be written, for the reason given; nothing was.
    case declined(EditRefusal)
    /// A refund or money back that covered only some of a part leans on what the edit
    /// changes; nothing was written.
    case declinedByLink(LinkedEditRefusal)
    /// A refund taken back from a purchase may not become what the edit makes it: more than is
    /// left of the part, or in another currency; nothing was written.
    case refundRefused(RefundError)
    /// The edit moves the money on an account that does not hold the currency, and nothing
    /// says what the account was charged; nothing was written.
    case chargeMissing
    /// The view was shown without the app's dependencies, so there was nothing to write to.
    /// Never seen in a window that was assembled properly.
    case refused
  }

  /// Writes the edit of a saved operation — from the inspector or the edit sheet — over
  /// the operation as it is in the database at that moment, in one write.
  ///
  /// An editor holds the copy it was opened with, and the inspector keeps it while the
  /// owner works elsewhere: meanwhile a reimbursement may close one of its parts, a part
  /// may be written off, a deletion may take it away. Written as it was edited, the old
  /// copy would undo all of that. So the edit is laid over the row read inside the write
  /// (`TransactionEntry.rebased(onto:)`), and a deleted operation is not written at all.
  ///
  /// An operation that moves a debt takes its journal line along in the same write — the
  /// amount, the day and the debt the edit changed («Платёж одновременно уменьшает
  /// долг») — and one ⌘Z brings both back. `calendar` dates the line, as the entry line does.
  @discardableResult
  public func saveEdit(
    _ edited: TransactionEntry, calendar: CalendarContext = .system, file: String = #fileID
  ) -> EditOutcome {
    guard !refuses("saveEdit", file) else { return .refused }
    guard let repository else { return .failed }
    do {
      // `edit` passes over a deleted row and stamps what it writes with this instant, so the
      // operation reported below is the very row in the database.
      let result = try repository.edit(
        id: edited.id, at: edited.transaction.updatedAt, calendar: calendar
      ) { fresh in edited.rebased(onto: fresh) }
      switch result {
      case .gone:
        return .gone
      case .unchanged:
        return .saved
      case .edited(let change):
        push(.edited(change))
        finishWrite(
          StoreWrite(upserted: [change.after], planningChanged: change.reachesBeyondTheOperation))
        return .saved
      }
    } catch let refusal as EditRefusal {
      return .declined(refusal)
    } catch let refusal as LinkedEditRefusal {
      return .declinedByLink(refusal)
    } catch let refusal as RefundError {
      return .refundRefused(refusal)
    } catch AccountWriteError.chargeMissing {
      return .chargeMissing
    } catch {
      failed(.edit, error, file: file)
      return .failed
    }
  }

  /// Deleting one operation is deleting many that happen to be one: the same rules, the
  /// same companions taken along, the same single step of undo.
  @discardableResult
  public func delete(id: UUID, file: String = #fileID) -> Bool {
    guard !refuses("delete(id:)", file) else { return false }
    return delete(ids: [id])
  }

  // MARK: Many operations at once

  /// What a bulk change would do to the listed operations: the text of the confirmation.
  /// The write itself works on the rows as they are in the database at that moment.
  ///
  /// `rates` — the bank's rates by day — and `calendar` work out what an account that does not
  /// hold an operation's currency is charged for it, when the change moves it there.
  public func plan(
    _ edit: BulkEdit, ids: Set<UUID>, rates: DayRates = .empty,
    calendar: CalendarContext = .system
  ) -> BulkEditPlan {
    BulkEditRule.plan(
      edit, entries: entries(ids: ids), tree: CategoryTree(categories()),
      history: qualityHistory(), accounts: accounts(), rates: rates, calendar: calendar)
  }

  /// What deleting the listed operations would take: a purchase a live refund takes money
  /// back from stays, unless that refund goes too.
  public func planDeletion(ids: Set<UUID>) -> BulkEditPlan {
    BulkEditRule.deletion(of: entries(ids: ids), refunds: listing?.refundIndex ?? .empty)
  }

  /// Every account the data knows, archived ones included: an operation moved in bulk goes to
  /// the account the menu offered, and one already on an archived account keeps what it was
  /// charged there.
  private func accounts() -> [PaymentMethod] {
    listing?.dataset.paymentMethods ?? []
  }

  /// One bulk change, one write, one step of undo. More than `backgroundThreshold`
  /// operations are written off the main thread: the call returns at once, and the change
  /// is reported through `didWrite` when it has landed.
  @discardableResult
  public func apply(
    _ edit: BulkEdit, to ids: [UUID], rates: DayRates = .empty,
    calendar: CalendarContext = .system, file: String = #fileID
  ) -> Bool {
    guard !refuses("apply(BulkEdit:)", file), repository != nil, !isWritingInBackground else {
      return false
    }
    let tree = CategoryTree(categories())
    let history = qualityHistory()
    let accounts = accounts()
    return modifyMany(ids, file: file) { fresh in
      BulkEditRule.apply(
        edit, to: fresh, tree: tree, history: history, accounts: accounts, rates: rates,
        calendar: calendar
      ).changedEntry
    }
  }

  /// The new quality of a category carried over to the operations filed under it — the
  /// answer «yes» to the question Settings asks after the change. The same way
  /// as a bulk change: one write, one step of ⌘Z, off the main thread beyond
  /// `backgroundThreshold`. The rule is applied again to each row as it is in the database
  /// then, with the categories as they are then: a part rated by hand since the question
  /// was asked keeps its rating.
  @discardableResult
  public func apply(
    _ change: CategoryQualityChange, to ids: [UUID], file: String = #fileID
  )
    -> Bool
  {
    guard !refuses("apply(CategoryQualityChange:)", file) else { return false }
    guard repository != nil, !isWritingInBackground else { return false }
    let tree = CategoryTree(categories())
    return modifyMany(ids, file: file) { fresh in change.applied(to: fresh, tree: tree) }
  }

  /// Rewrites the operations `transform` changes, in one write that is one step of undo.
  private func modifyMany(
    _ ids: [UUID], file: String,
    transform: @escaping @Sendable (TransactionEntry) -> TransactionEntry?
  ) -> Bool {
    guard let repository, !isWritingInBackground else { return false }
    if Self.writesInBackground(ids.count) {
      runInBackground(.change, file: file) {
        let modified = try await repository.modifyInBackground(ids: ids, transform: transform)
        guard !modified.isEmpty else { return nil }
        return Landed(
          step: .editedMany(modified.map(\.before)),
          write: StoreWrite(upserted: modified.map(\.after)))
      }
      return true
    }
    do {
      var after: [UUID: TransactionEntry] = [:]
      let before = try repository.modify(ids: ids) { fresh in
        let changed = transform(fresh)
        after[fresh.id] = changed
        return changed
      }
      guard !before.isEmpty else { return true }
      let write = StoreWrite(upserted: before.compactMap { after[$0.id] })
      record(Landed(step: .editedMany(before), write: write))
      return true
    } catch {
      failed(.change, error, file: file)
      return false
    }
  }

  /// Deletes operations in one write. A purchase on credit is left alone (it is changed in
  /// Debts); whether an operation is one is read from the database, not from the list,
  /// inside the write that deletes: nothing that lands between the choice and the deletion
  /// can change what the choice was made on. More than `backgroundThreshold` operations are
  /// chosen and deleted that way off the main thread: the whole deletion is queued at once,
  /// so nothing the owner does next lands between the choice and the deletion either.
  @discardableResult
  public func delete(ids: [UUID], file: String = #fileID) -> Bool {
    guard !refuses("delete(ids:)", file), let repository, !isWritingInBackground else {
      return false
    }
    let transfers = transfers(among: ids)
    if !transfers.isEmpty { return delete(ids, with: transfers, file: file) }
    // A purchase a live refund takes money back from stays: the write refuses it, and would
    // refuse the whole deletion with it.
    let refunds = listing?.refundIndex ?? .empty
    if Self.writesInBackground(ids.count) {
      runInBackground(.delete, file: file) {
        let effects = try await repository.softDeleteInBackground(ids: ids) { listed in
          Self.deletable(listed, refunds: refunds)
        }
        return effects.deletedIds.isEmpty ? nil : Self.deletion(effects)
      }
      return true
    }
    do {
      var listed: [TransactionEntry] = []
      let effects = try repository.softDelete(ids: ids) { rows in
        listed = rows
        return Self.deletable(rows, refunds: refunds)
      }
      guard !effects.deletedIds.isEmpty else {
        return BulkEditRule.deletion(of: listed, refunds: refunds).skipped.isEmpty
      }
      record(Self.deletion(effects))
      return true
    } catch {
      failed(.delete, error, file: file)
      return false
    }
  }

  // MARK: Transfers

  /// The transfers among `ids`, as the lists show them now; the rest of `ids` are operations.
  public func transfers(among ids: some Sequence<UUID>) -> [Transfer] {
    guard let listing else { return [] }
    let wanted = Set(ids)
    guard !wanted.isEmpty else { return [] }
    return listing.dataset.transfers.filter { wanted.contains($0.id) }
  }

  /// The ids among `ids` that are transfers: what a confirmation of a deletion names besides
  /// the operations.
  public func transferIds(in ids: some Sequence<UUID>) -> [UUID] {
    transfers(among: ids).map(\.id)
  }

  /// What a deletion of `ids` takes besides operations: the transfers among them, and the
  /// rubles of their live fees — what the question before it says.
  func transferDeletion(in ids: some Sequence<UUID>) -> TransferDeletion {
    let transfers = transfers(among: ids)
    guard !transfers.isEmpty, let listing else { return .none }
    let fees = feeIds(of: transfers).compactMap { listing.entry($0) }
    return TransferDeletion(
      count: transfers.count, fees: AmountE4.sum(fees.map(\.transaction.amountRubE4)))
  }

  /// A deletion that takes transfers along: the transfers, their fees and the operations the
  /// rules let go, in one change of planning and so one step of ⌘Z, which brings all of it back
  /// — the parts a deleted money back had closed included. The operations are chosen by the
  /// same rule as any deletion, from the rows the lists show. More than `backgroundThreshold`
  /// rows are written off the main thread.
  private func delete(_ ids: [UUID], with transfers: [Transfer], file: String) -> Bool {
    guard let planning else { return false }
    let transferIds = Set(transfers.map(\.id))
    let operations = entries(ids: Set(ids).subtracting(transferIds))
    // A purchase a live refund still takes money back from stays, as in any deletion: the write
    // would refuse it, and the whole change with it.
    var gone = Self.deletable(operations, refunds: listing?.refundIndex ?? .empty)
    for fee in feeIds(of: transfers) where !gone.contains(fee) { gone.append(fee) }
    let change = PlanningChange(
      delete: PlanningRowIDs(transfers: transfers.map(\.id)), softDeleted: gone, at: Date())
    if Self.writesInBackground(gone.count + transfers.count) {
      runInBackground(.delete, file: file) {
        let undo = try await planning.applyInBackground(change)
        return Landed(step: .planned(undo), write: Self.applied(change, undo: undo))
      }
      return true
    }
    do {
      let undo = try planning.apply(change)
      record(Landed(step: .planned(undo), write: Self.applied(change, undo: undo)))
      return true
    } catch {
      failed(.delete, error, file: file)
      return false
    }
  }

  /// The live fees of these transfers (`transfer:<id>:fee`): a transfer takes its fee along.
  private func feeIds(of transfers: [Transfer]) -> [UUID] {
    guard let listing else { return [] }
    let keys = Set(transfers.map { TransferRules.feeKey(of: $0.id) })
    return listing.dataset.entries.compactMap { entry in
      guard entry.transaction.deletedAt == nil, let key = entry.transaction.externalId,
        keys.contains(key)
      else { return nil }
      return entry.id
    }
  }

  /// What of these operations a deletion takes: the rule's choice, without what is gone.
  /// `refunds` say which purchases a live refund takes money back from.
  private nonisolated static func deletable(
    _ entries: [TransactionEntry], refunds: RefundIndex = .empty
  ) -> [UUID] {
    BulkEditRule.deletion(of: entries, refunds: refunds).changed
      .filter { !$0.transaction.isDeleted }.map(\.id)
  }

  /// The step and the report of a deletion that happened.
  private nonisolated static func deletion(_ effects: DeletionEffects) -> Landed {
    Landed(
      step: .deletedMany(effects.deletedIds, effects),
      write: StoreWrite(
        removed: effects.deletedIds + effects.companionIds,
        partStatuses: statuses(effects.reopenedPartIds, .expected)))
  }

  /// Whether a bulk write of this many operations leaves the main thread.
  nonisolated static func writesInBackground(_ count: Int) -> Bool {
    count > backgroundThreshold
  }

  /// Runs a bulk write off the main thread. The store stays busy until it has landed or
  /// failed; a failure goes the way of any other (`failed`) and leaves nothing to undo.
  /// `write` returns what landed, or `nil` when there was nothing to do.
  ///
  /// Where its step goes is taken now, when the write is asked for, not when it lands: a
  /// line saved in between was asked for later, and ⌘Z must take it back first. An undo that
  /// fails gives its step — `undone`, taken off the stack for the write — back to that place.
  private func runInBackground(
    _ action: StoreFailure.Action, file: String, undone: UndoStep? = nil,
    _ write: @escaping @Sendable () async throws -> Landed?
  ) {
    isWritingInBackground = true
    let asked = Asked(slot: undoStack.count, epoch: undoEpoch, attachment: attachment)
    backgroundWrite = Task { [weak self] in
      let result: Result<Landed?, any Error>
      do {
        result = .success(try await write())
      } catch {
        result = .failure(error)
      }
      self?.land(result, asked: asked, action: action, file: file, undone: undone)
      if case .success = result { return true }
      return false
    }
  }

  /// Where and when a bulk write was asked for: its place in the stack, the history and the
  /// database of that moment.
  private struct Asked: Sendable {
    var slot: Int
    var epoch: Int
    var attachment: Int
  }

  /// A bulk write back from off the main thread: its step kept where it was asked for, or —
  /// an undo that failed — the undone step given back there, and the store free again.
  ///
  /// A write asked of a database the store has let go of since (`attach`, `detach`) is none
  /// of the database it holds now: no report to its `didWrite` (an overlay of rows that are
  /// not there, a backup of a change it never had), no step, and the store — free since it
  /// let go — is not touched. A failure of such a write reaches the journal only.
  private func land(
    _ result: Result<Landed?, any Error>, asked: Asked, action: StoreFailure.Action,
    file: String, undone: UndoStep?
  ) {
    guard asked.attachment == attachment else {
      if case .failure(let error) = result { failed(action, error, file: file, onScreen: false) }
      return
    }
    switch result {
    case .success(let outcome):
      if let outcome { record(outcome, at: asked.slot, epoch: asked.epoch) }
    case .failure(let error):
      if let undone { keep(undone, at: asked.slot, epoch: asked.epoch) }
      failed(action, error, file: file)
    }
    isWritingInBackground = false
    backgroundWrite = nil
    // Held back while the write was on its way (`trimUndoHistory`).
    trimUndoHistory()
  }

  // MARK: Undo

  public var canUndo: Bool { !undoStack.isEmpty && !isWritingInBackground }

  /// Undo steps only make sense against the database they were taken from, and only up to
  /// a write that ⌘Z cannot describe (a reimbursement, a part written off). A bulk write
  /// still on its way was asked for before it and is forgotten with the rest when it lands.
  public func forgetUndoHistory() {
    undoStack.removeAll()
    undoEpoch += 1
  }

  /// ⌘Z. Undo steps are kept in the store rather than in a window's UndoManager because
  /// editing happens in one window and the list lives in another. A bulk
  /// change is one step and goes back in one write.
  ///
  /// A step leaves the stack only once it has gone back. One the database refuses — an
  /// operation filed since under the category it created — stays where it is, the journal
  /// and the screen say so (`failure`), and the next ⌘Z tries it again rather than reaching
  /// past it to the step before.
  public func undo(file: String = #fileID) {
    guard !refuses("undo", file) else { return }
    guard let repository, !isWritingInBackground, let step = undoStack.last else { return }
    if Self.writesInBackground(step.size) {
      undoStack.removeLast()
      let planning = planning
      runInBackground(.undo, file: file, undone: step) {
        Landed(
          step: nil,
          write: try await Self.undoInBackground(
            step, repository: repository, planning: planning))
      }
      return
    }
    do {
      let write: StoreWrite
      switch step {
      case .created(let id):
        try repository.purge(id: id)
        write = StoreWrite(removed: [id])
      case .edited(let change):
        try repository.revert(change)
        write = StoreWrite(
          upserted: [change.before], planningChanged: change.reachesBeyondTheOperation)
      case .editedMany(let before):
        // My change is taken back from the rows as they are now: a part written off or a
        // rate refined since the change stays as it is.
        let snapshots = Self.byId(before)
        var reverted: [UUID: TransactionEntry] = [:]
        // What the account was charged comes back with the account: the undo puts back what
        // the operations were, a row of the time before accounts included, and asks nothing.
        let changed = try repository.modify(
          ids: before.map(\.id), checkingCharges: false
        ) { fresh in
          let back = snapshots[fresh.id].map { BulkEditRule.revert(fresh, to: $0) }
          reverted[fresh.id] = back
          return back
        }
        write = StoreWrite(upserted: changed.compactMap { reverted[$0.id] })
      case .deletedMany(let ids, let effects):
        try repository.restore(ids: ids, effects: effects)
        // What comes back is whatever the rows are now; the few of them are read again.
        let restored = try repository.entries(ids: ids + effects.companionIds)
          .filter { !$0.transaction.isDeleted }
        write = StoreWrite(
          upserted: restored, partStatuses: Self.statuses(effects.reopenedPartIds, .returned))
      case .planned(let undo):
        guard let planning else { return }
        try planning.revert(undo)
        let back = Self.broughtBack(by: undo)
        var readBack: [TransactionEntry] = []
        if !back.isEmpty { readBack = try repository.entries(ids: back) }
        write = Self.reverted(undo, readBack: readBack)
      }
      // Nothing else runs on the main actor meanwhile: the step is still the last one.
      undoStack.removeLast()
      finishWrite(write)
    } catch {
      failed(.undo, error, file: file)
    }
  }

  /// The undo of a bulk step too large for the main thread: the same rules, awaited. Only
  /// the steps of many operations ever get here; the others go the way `undo` takes them.
  private nonisolated static func undoInBackground(
    _ step: UndoStep, repository: TransactionRepository, planning: PlanningRepository?
  ) async throws -> StoreWrite {
    switch step {
    case .created(let id):
      try repository.purge(id: id)
      return StoreWrite(removed: [id])
    case .edited(let change):
      try repository.revert(change)
      return StoreWrite(
        upserted: [change.before], planningChanged: change.reachesBeyondTheOperation)
    case .editedMany(let before):
      let snapshots = byId(before)
      let modified = try await repository.modifyInBackground(
        ids: before.map(\.id), checkingCharges: false
      ) { fresh in
        snapshots[fresh.id].map { BulkEditRule.revert(fresh, to: $0) }
      }
      return StoreWrite(upserted: modified.map(\.after))
    case .deletedMany(let ids, let effects):
      try await repository.restoreInBackground(ids: ids, effects: effects)
      let restored = try await repository.entriesInBackground(ids: ids + effects.companionIds)
        .filter { !$0.transaction.isDeleted }
      return StoreWrite(
        upserted: restored, partStatuses: statuses(effects.reopenedPartIds, .returned))
    case .planned(let undo):
      // A change of planning that deleted or rewrote many operations: taken back off the main
      // thread like any bulk step.
      guard let planning else { throw PlanningUndoUnavailable() }
      try await planning.revertInBackground(undo)
      let back = broughtBack(by: undo)
      var readBack: [TransactionEntry] = []
      if !back.isEmpty { readBack = try await repository.entriesInBackground(ids: back) }
      return reverted(undo, readBack: readBack)
    }
  }

  /// The planning repository is gone — the store let go of its database — while an undo of
  /// planning was asked for.
  private struct PlanningUndoUnavailable: Error {}

  // MARK: Helpers

  /// Keeps the step of a write that has just been made and reports the write.
  private func record(_ landed: Landed) {
    record(landed, at: undoStack.count, epoch: undoEpoch)
  }

  /// Keeps the step of a write where it was asked for — at `slot`, under the steps taken
  /// while it was on its way — unless the history was forgotten since, and reports the
  /// write either way: it happened, and the backup and the lists must follow it.
  private func record(_ landed: Landed, at slot: Int, epoch: Int) {
    if let step = landed.step { keep(step, at: slot, epoch: epoch) }
    finishWrite(landed.write)
  }

  /// Puts a step at `slot`, unless the history was forgotten since.
  private func keep(_ step: UndoStep, at slot: Int, epoch: Int) {
    guard epoch == undoEpoch else { return }
    // Nothing is popped or trimmed while a bulk write is on its way, and forgetting moves
    // the epoch, so the slot is still inside the stack; `min` only keeps it so.
    undoStack.insert(step, at: min(slot, undoStack.count))
    trimUndoHistory()
  }

  /// Keeps the step of a write that has just landed on the main thread.
  private func push(_ step: UndoStep) {
    undoStack.append(step)
    trimUndoHistory()
  }

  /// Lets the oldest steps go once the history reaches further back than `undoDepth`
  /// allows; the newest always stays. Not while a bulk write is on its way: its step goes
  /// in at the place it was asked for, counted from the bottom of the stack, and a step
  /// taken off the bottom meanwhile would put it above a line saved after it. The history
  /// is trimmed when that write has landed.
  private func trimUndoHistory() {
    guard !isWritingInBackground else { return }
    var operations = undoStack.reduce(0) { $0 + $1.size }
    var dropped = 0
    while undoStack.count - dropped > 1,
      undoStack.count - dropped > undoDepth.levels || operations > undoDepth.operations
    {
      operations -= undoStack[dropped].size
      dropped += 1
    }
    undoStack.removeFirst(dropped)
  }

  /// A write that did not land. The journal gets what was being done, the type of the error
  /// and the file that asked («тип, категория, место в коде»); `lastError` the type; and
  /// `failure` — what the screen shows — a write whose caller has no words of its own for it,
  /// unless it was a write on a database the screen no longer shows (`onScreen: false`).
  private func failed(
    _ action: StoreFailure.Action, _ error: any Error, file: String, onScreen: Bool = true
  ) {
    let type = String(describing: Swift.type(of: error))
    lastError = type
    AppLog.error(
      "store.writeFailed", .db, "a write of the store did not land",
      [
        LogPair("action", .token(action.rawValue)), LogPair("error", .typeName(type)),
        LogPair("from", .file(file)),
      ])
    if onScreen, action.isShownByTheScreen {
      failure = StoreFailure(action: action, cause: WriteFailureCause(of: error))
    }
  }

  private func finishWrite(_ write: StoreWrite) {
    didWrite?(write)
  }

  private nonisolated static func statuses(
    _ parts: [UUID], _ status: ReimbursementStatus
  ) -> [UUID: ReimbursementStatus] {
    Dictionary(parts.map { ($0, status) }, uniquingKeysWith: { first, _ in first })
  }

  private nonisolated static func byId(_ entries: [TransactionEntry]) -> [UUID: TransactionEntry] {
    Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }

  /// My ratings by description as the database has them now: rule 2 of the qualities decides
  /// what a changed category rates a part as. The repository keeps them until a write,
  /// so a plan and the change that follows it do not read them twice.
  private func qualityHistory() -> ManualQualityHistory {
    (try? repository?.manualQualityHistory()) ?? .empty
  }

  /// Pure grouping, isolated from the store so it can be exercised without a UI. A transfer
  /// goes on the day it was made, newest first; a day of transfers alone is a day too.
  /// `refunds` — the ledger's (`Ledger.refundIndex`) — count a refund taken back from a
  /// purchase in the purchase's day, never twice.
  nonisolated static func group(
    _ entries: [TransactionEntry], calendar: CalendarContext, debts: [UUID: Debt] = [:],
    transfers: [Transfer] = [], refunds: RefundIndex = .empty
  )
    -> [DayGroup]
  {
    let byDay = Dictionary(grouping: entries) { calendar.day(of: $0.transaction.occurredAt) }
    let transfersByDay = Dictionary(grouping: transfers) { calendar.day(of: $0.occurredAt) }
    let days = Set(byDay.keys).union(transfersByDay.keys)
    return days.sorted(by: >).map { day in
      let entries = byDay[day] ?? []
      return DayGroup(
        day: day,
        expenses: entries.filter { !DayGroup.isListedWithIncome($0.transaction.kind) },
        income: entries.filter { DayGroup.isListedWithIncome($0.transaction.kind) },
        debts: debts,
        transfers: (transfersByDay[day] ?? []).sorted(by: Self.newestFirst),
        refunds: refunds)
    }
  }

  /// Newest first; of two made at the same moment, the later written first.
  nonisolated static func newestFirst(_ left: Transfer, _ right: Transfer) -> Bool {
    if left.occurredAt != right.occurredAt { return left.occurredAt > right.occurredAt }
    if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
    return left.id.uuidString > right.id.uuidString
  }
}
