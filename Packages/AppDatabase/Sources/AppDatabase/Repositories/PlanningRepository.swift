import AppCore
import CoreKit
import Foundation
import GRDB

/// Rows of the tables an action of the planning writes, one list per table. The reference
/// books are here because the planning makes rows of them too: the subcategory of a new goal,
/// of a new debt. So are the accounts and their groups, the transfers between them and the
/// balances counted on them.
public struct PlanningRows: Sendable, Hashable {
  public var accountGroups: [AccountGroup]
  public var paymentMethods: [PaymentMethod]
  public var categories: [CoreKit.Category]
  public var events: [Event]
  public var goals: [Goal]
  public var debts: [Debt]
  public var scheduled: [ScheduledPayment]
  public var prices: [SubscriptionPrice]
  public var expected: [ExpectedIncome]
  public var expectedLinks: [ExpectedIncomeLink]
  public var budgets: [Budget]
  public var debtEntries: [DebtEntry]
  public var reconciliations: [Reconciliation]
  public var transfers: [Transfer]
  public var reconciledBalances: [ReconciledBalance]

  public init(
    categories: [CoreKit.Category] = [], events: [Event] = [], goals: [Goal] = [],
    debts: [Debt] = [], scheduled: [ScheduledPayment] = [], prices: [SubscriptionPrice] = [],
    expected: [ExpectedIncome] = [], expectedLinks: [ExpectedIncomeLink] = [],
    budgets: [Budget] = [], debtEntries: [DebtEntry] = [], reconciliations: [Reconciliation] = [],
    accountGroups: [AccountGroup] = [], paymentMethods: [PaymentMethod] = [],
    transfers: [Transfer] = [], reconciledBalances: [ReconciledBalance] = []
  ) {
    self.accountGroups = accountGroups
    self.paymentMethods = paymentMethods
    self.transfers = transfers
    self.reconciledBalances = reconciledBalances
    self.categories = categories
    self.events = events
    self.goals = goals
    self.debts = debts
    self.scheduled = scheduled
    self.prices = prices
    self.expected = expected
    self.expectedLinks = expectedLinks
    self.budgets = budgets
    self.debtEntries = debtEntries
    self.reconciliations = reconciliations
  }

  public static let empty = PlanningRows()
}

/// Ids of rows of the same tables as `PlanningRows`, one list per table.
public struct PlanningRowIDs: Sendable, Hashable {
  public var accountGroups: [UUID]
  public var paymentMethods: [UUID]
  public var categories: [UUID]
  public var events: [UUID]
  public var goals: [UUID]
  public var debts: [UUID]
  public var scheduled: [UUID]
  public var prices: [UUID]
  public var expected: [UUID]
  public var expectedLinks: [UUID]
  public var budgets: [UUID]
  public var debtEntries: [UUID]
  public var reconciliations: [UUID]
  public var transfers: [UUID]
  public var reconciledBalances: [UUID]

  public init(
    categories: [UUID] = [], events: [UUID] = [], goals: [UUID] = [], debts: [UUID] = [],
    scheduled: [UUID] = [], prices: [UUID] = [], expected: [UUID] = [],
    expectedLinks: [UUID] = [], budgets: [UUID] = [], debtEntries: [UUID] = [],
    reconciliations: [UUID] = [], accountGroups: [UUID] = [], paymentMethods: [UUID] = [],
    transfers: [UUID] = [], reconciledBalances: [UUID] = []
  ) {
    self.accountGroups = accountGroups
    self.paymentMethods = paymentMethods
    self.transfers = transfers
    self.reconciledBalances = reconciledBalances
    self.categories = categories
    self.events = events
    self.goals = goals
    self.debts = debts
    self.scheduled = scheduled
    self.prices = prices
    self.expected = expected
    self.expectedLinks = expectedLinks
    self.budgets = budgets
    self.debtEntries = debtEntries
    self.reconciliations = reconciliations
  }

  public static let empty = PlanningRowIDs()
}

/// One action of the planning, written whole or not at all: «Mark as paid»,
/// a contribution to a goal, a reconciliation, a debt payment, a transfer, an edit of a
/// definition or of an account.
public struct PlanningChange: Sendable, Hashable {
  /// New operations with their parts.
  public var created: [TransactionEntry]
  /// Rows written over the row with the same id, or added when there is none.
  public var upsert: PlanningRows
  public var delete: PlanningRowIDs
  /// Keys of `settings` to set; a key whose value is `nil` is deleted. A dictionary drops a
  /// key assigned `nil`, so a deletion goes in as `.some(nil)` or through `updateValue`.
  public var settings: [String: String?]
  /// Live operations written over as they are given, stamped as updated at `at`. Only the
  /// operation and its parts are written: a debt payment's journal line does not follow its
  /// operation here, so a change that rewrites one gives the line in `upsert.debtEntries`.
  /// A part the rewrite drops takes its money-back links along, and ⌘Z gives them back.
  public var rewritten: [TransactionEntry]
  /// Operations deleted softly, with everything a deletion takes along
  /// (`TransactionRepository.softDelete(ids:at:)`), at `at`. They go after `created` is
  /// written, so a key one of them lets go — a due date, a transfer's fee — cannot be taken
  /// by a new operation of the same change; an operation of `rewritten` can move it.
  public var softDeleted: [UUID]
  /// The instant of the change: `updated_at` of what it rewrites, `deleted_at` of what it
  /// deletes.
  public var at: Date

  public init(
    created: [TransactionEntry] = [], upsert: PlanningRows = .empty,
    delete: PlanningRowIDs = .empty, settings: [String: String?] = [:],
    rewritten: [TransactionEntry] = [], softDeleted: [UUID] = [], at: Date = Date()
  ) {
    self.created = created
    self.upsert = upsert
    self.delete = delete
    self.settings = settings
    self.rewritten = rewritten
    self.softDeleted = softDeleted
    self.at = at
  }
}

/// Everything `revert` needs to take a `PlanningChange` back: one step of ⌘Z.
public struct PlanningUndo: Sendable, Hashable {
  public var createdTransactionIds: [UUID]
  /// Rows the change added.
  public var inserted: PlanningRowIDs
  /// Every row the change wrote over or removed — the rows a deletion cascaded to or cleared
  /// included — as it was before.
  public var before: PlanningRows
  /// The values the change's keys had; `nil` — the key was not there.
  public var settingsBefore: [String: String?]
  /// The rowid each row of `before` had, by id: lists read in rowid order — the limits, the
  /// lines of one day of a journal — get a removed row back in its place, not last.
  public var rowIDs: [UUID: Int64]
  /// Links to a deleted category the schema cleared in tables the planning does not write —
  /// templates, import mappings, the model's corrections — set back once the category is.
  public var cleared: [ClearedReference]
  /// The operations the change rewrote, as they were before it.
  public var rewrittenBefore: [TransactionEntry]
  /// Links of money back to the parts a rewrite dropped: a link goes with its part
  /// (`ON DELETE CASCADE`), and the part ⌘Z gives back needs it, or deleting that money back
  /// would never open the part again.
  public var removedLinks: [ReimbursementLink]
  /// What deleting the operations of `PlanningChange.softDeleted` did, for `restore`.
  public var deletion: DeletionEffects
  /// Refunds in the bin that let go of a part a rewrite dropped, refund part → purchase part:
  /// ⌘Z ties them back once the part is back.
  public var releasedRefunds: [UUID: UUID]
  /// The operations the change created and rewrote, as the write left them — with the account
  /// it gave the ones that named none —, for the caller to show; ⌘Z does not need them.
  public var written: [TransactionEntry]

  public init(
    createdTransactionIds: [UUID] = [], inserted: PlanningRowIDs = .empty,
    before: PlanningRows = .empty, settingsBefore: [String: String?] = [:],
    rowIDs: [UUID: Int64] = [:], cleared: [ClearedReference] = [],
    rewrittenBefore: [TransactionEntry] = [], removedLinks: [ReimbursementLink] = [],
    deletion: DeletionEffects = .none, releasedRefunds: [UUID: UUID] = [:],
    written: [TransactionEntry] = []
  ) {
    self.createdTransactionIds = createdTransactionIds
    self.inserted = inserted
    self.before = before
    self.settingsBefore = settingsBefore
    self.rowIDs = rowIDs
    self.cleared = cleared
    self.rewrittenBefore = rewrittenBefore
    self.removedLinks = removedLinks
    self.deletion = deletion
    self.releasedRefunds = releasedRefunds
    self.written = written
  }
}

/// One link a category deletion cleared (`ON DELETE SET NULL`) in a row the planning does not
/// otherwise write: `column` of the row `rowId` of `table` pointed at `categoryId`.
public struct ClearedReference: Sendable, Hashable {
  public let table: String
  public let column: String
  public let rowId: String
  public let categoryId: UUID
}

public enum PlanningWriteError: Error, Equatable, Sendable {
  /// An event, a goal or a debt that operations point at is archived or closed, never
  /// deleted (the schema's rule). Deleting it would quietly clear the operations' references
  /// — a contribution would stop counting towards its goal — and undo could not put them
  /// back, since operations are not rows of the planning. The same holds for an account that
  /// operations, transfers, scheduled payments or debt journal lines point at.
  case referencedByOperations(UUID)
}

/// The one write path of the planning, so every action is one transaction and one step of
/// undo, plus the reads the planning screens need.
public struct PlanningRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  // MARK: Writing

  /// Writes the change in one transaction and returns how to take it back.
  ///
  /// Each row is read right before it is first written or deleted: a row that is there goes
  /// to `before`, a new one to `inserted`. A deletion also reads the rows of the planning the
  /// schema cascades it to or clears — the prices of a payment, the links of an expected
  /// income, the journal of a debt, the limits and definitions filed under a category, the
  /// balances counted on an account or in a reconciliation — so undo gives them back as well.
  ///
  /// Rows go in the order their foreign keys need: groups of accounts, accounts, categories
  /// (parents first), events, goals, debts, scheduled payments, prices, expected income,
  /// limits, then the new operations with their parts and the operations rewritten, and after
  /// them the debt journal, the income links, the transfers, the reconciliations and the
  /// balances they counted, which may point at those operations. Deletions come after, in the
  /// reverse order; then the operations deleted softly, with what their deletion takes along;
  /// and the settings after everything.
  ///
  /// The accounts keep one main account: one written as main takes the flag from every other,
  /// and a main account is deleted only while another live account is main. An account
  /// deleted takes along a reconciliation of accounts it leaves with no count, as
  /// `AccountRepository.delete` does.
  ///
  /// Every operation written gets an account — the main one when it names none — and one that
  /// moves money on an account that does not hold its currency says what the account was
  /// charged (`TransactionRepository.assigningAccount`); so does money borrowed or lent through
  /// the debt journal alone. The operations as written come back in `PlanningUndo.written`.
  /// A refund is held to the part it takes back from, and a rewrite to what refunds and partial
  /// money back lean on (`rewrite`).
  ///
  /// Throws `DatabaseError.unbalancedParts` before writing anything when an operation does
  /// not add up, `DatabaseError.notFound` when an operation to rewrite is not there or is
  /// deleted, `PlanningWriteError.referencedByOperations` when an event, a goal, a debt or
  /// an account to delete is still used, `AccountWriteError.isMain` when the main account
  /// to delete is the only one, `AccountWriteError.chargeMissing` when a charge is
  /// missing, and `LinkedEditRefusal` or `RefundError` when a refund or partial money back
  /// would be left without its ground. Any failure rolls the whole change back — among them the
  /// unique `external_id`, which keeps one due date from being paid twice.
  public func apply(_ change: PlanningChange) throws -> PlanningUndo {
    try Self.refuseUnbalanced(change)
    return try writer.write { db in try Self.apply(change, db: db) }
  }

  /// `apply` off the calling thread: the same write, awaited — for a change of many
  /// operations, which would otherwise freeze the window.
  public func applyInBackground(_ change: PlanningChange) async throws -> PlanningUndo {
    try Self.refuseUnbalanced(change)
    return try await writer.write { db in try Self.apply(change, db: db) }
  }

  private static func refuseUnbalanced(_ change: PlanningChange) throws {
    guard change.created.allSatisfy(\.isBalanced), change.rewritten.allSatisfy(\.isBalanced)
    else { throw DatabaseError.unbalancedParts }
  }

  static func apply(_ change: PlanningChange, db: Database) throws -> PlanningUndo {
    var journal = UndoJournal()
    let rows = change.upsert
    try journal.upsert(rows.accountGroups, db: db)
    try journal.upsert(rows.paymentMethods, db: db)
    // An account written as the main one takes the flag from every other, as a save of it
    // does (`ReferenceRepository.save`); of two written as main, the later one keeps it.
    if let main = rows.paymentMethods.last(where: \.isDefault) {
      try journal.takeMainFlag(for: main.id, db: db)
    }
    try journal.upsert(Self.parentsFirst(rows.categories), db: db)
    try journal.upsert(rows.events, db: db)
    try journal.upsert(rows.goals, db: db)
    try journal.upsert(rows.debts, db: db)
    try journal.upsert(rows.scheduled, db: db)
    try journal.upsert(rows.prices, db: db)
    try journal.upsert(rows.expected, db: db)
    try journal.upsert(rows.budgets, db: db)
    // New operations are written the way `TransactionRepository.insert` writes them: as new
    // rows, so an id or an `external_id` that is already there fails the change. Each is given
    // an account like any other (`TransactionRepository.assigningAccount`), and a refund is
    // held to the part it takes back from.
    let lookups = WriteLookups()
    var written: [TransactionEntry] = []
    for entry in change.created {
      let assigned = try TransactionRepository.assigningAccount(entry, lookups: lookups, db: db)
      try TransactionRepository.refuseUnsoundRefund(assigned, over: nil, db: db)
      try assigned.transaction.insert(db)
      for part in assigned.parts { try part.insert(db) }
      written.append(assigned)
    }
    let rewrites = try rewrite(change.rewritten, at: change.at, lookups: lookups, db: db)
    written += rewrites.written
    try Self.refuseMissingCharge(of: rows.debtEntries, db: db)
    try journal.upsert(rows.debtEntries, db: db)
    try journal.upsert(rows.expectedLinks, db: db)
    try journal.upsert(rows.transfers, db: db)
    try journal.upsert(rows.reconciliations, db: db)
    try journal.upsert(rows.reconciledBalances, db: db)

    let gone = change.delete
    try journal.delete(ReconciledBalance.self, ids: gone.reconciledBalances, db: db)
    try journal.delete(Reconciliation.self, ids: gone.reconciliations, db: db)
    try journal.delete(Transfer.self, ids: gone.transfers, db: db)
    try journal.delete(ExpectedIncomeLink.self, ids: gone.expectedLinks, db: db)
    try journal.delete(DebtEntry.self, ids: gone.debtEntries, db: db)
    try journal.delete(Budget.self, ids: gone.budgets, db: db)
    try journal.delete(ExpectedIncome.self, ids: gone.expected, db: db)
    try journal.delete(SubscriptionPrice.self, ids: gone.prices, db: db)
    try journal.delete(ScheduledPayment.self, ids: gone.scheduled, db: db)
    try journal.delete(Debt.self, ids: gone.debts, db: db)
    try journal.delete(Goal.self, ids: gone.goals, db: db)
    try journal.delete(Event.self, ids: gone.events, db: db)
    try journal.delete(
      CoreKit.Category.self, ids: Self.childrenFirst(gone.categories, db: db), db: db)
    try Self.deleteAccounts(gone.paymentMethods, journal: &journal, db: db)
    try journal.delete(AccountGroup.self, ids: gone.accountGroups, db: db)

    let deletion =
      change.softDeleted.isEmpty
      ? DeletionEffects.none
      : try TransactionRepository.softDelete(ids: change.softDeleted, at: change.at, db: db)

    var settingsBefore: [String: String?] = [:]
    for (key, value) in change.settings.sorted(by: { $0.key < $1.key }) {
      settingsBefore.updateValue(try Self.setting(key, db: db), forKey: key)
      try Self.setSetting(key, to: value, db: db)
    }
    return PlanningUndo(
      createdTransactionIds: change.created.map(\.id), inserted: journal.inserted,
      before: journal.before, settingsBefore: settingsBefore, rowIDs: journal.rowIDs,
      cleared: journal.cleared, rewrittenBefore: rewrites.before,
      removedLinks: rewrites.removedLinks, deletion: deletion,
      releasedRefunds: rewrites.releasedRefunds, written: written)
  }

  /// What `rewrite` did: the rows as they were — each one once, as it was before its first
  /// rewrite —, the money-back links of the parts the rewrites dropped, the refunds in the bin
  /// that let go of those parts, and the operations as written.
  private struct Rewrites {
    var before: [TransactionEntry] = []
    var removedLinks: [ReimbursementLink] = []
    var releasedRefunds: [UUID: UUID] = [:]
    var written: [TransactionEntry] = []
  }

  /// Writes each operation over the live row with its id, stamped as updated at `instant`.
  ///
  /// A rewrite is held to what refunds and money back that covered only some of a part lean
  /// on, as an edit is (`OperationEditRule.linkedRefusal`): a refunded part is not cut below
  /// its refunds, a partly returned part keeps its money. A refund is held to the part it takes
  /// back from. What a whole reimbursement settled is the caller's to keep: no planning action
  /// rewrites money back or what it wrote, and a part it closed that a rewrite drops comes back
  /// with its links on ⌘Z.
  private static func rewrite(
    _ entries: [TransactionEntry], at instant: Date, lookups: WriteLookups, db: Database
  ) throws -> Rewrites {
    var done = Rewrites()
    var seen: Set<UUID> = []
    for var entry in entries {
      guard let current = try TransactionRepository.entry(id: entry.id, db: db),
        !current.transaction.isDeleted,
        entry.parts.allSatisfy({ $0.transactionId == entry.id })
      else { throw DatabaseError.notFound }
      if let refusal = OperationEditRule.linkedRefusal(
        editing: current, into: entry,
        facts: try TransactionRepository.editFacts(current, entry, db: db))
      {
        throw refusal
      }
      let kept = Set(entry.parts.map(\.id))
      let dropped = current.parts.map(\.id).filter { !kept.contains($0) }
      if !dropped.isEmpty {
        done.removedLinks +=
          try ReimbursementLink
          .filter(dropped.map(\.uuidString).contains(Column("part_id")))
          .order(Column.rowID)
          .fetchAll(db)
      }
      entry.transaction.updatedAt = instant
      entry = try TransactionRepository.assigningAccount(
        entry, over: current, lookups: lookups, db: db)
      try TransactionRepository.refuseUnsoundRefund(entry, over: current, db: db)
      let released = try TransactionRepository.write(entry, over: current, db: db)
      done.releasedRefunds.merge(released) { first, _ in first }
      if seen.insert(entry.id).inserted { done.before.append(current) }
      done.written.removeAll { $0.id == entry.id }
      done.written.append(entry)
    }
    return done
  }

  /// Money borrowed or lent through the journal alone moves money on an account — the line's,
  /// or the main one —: a line with a moment whose account does not hold the debt's currency
  /// must say what the account moved, in a currency it holds, or the change is refused with
  /// `AccountWriteError.chargeMissing`. Lines written before accounts have no moment and are
  /// never asked.
  private static func refuseMissingCharge(of lines: [DebtEntry], db: Database) throws {
    var main: UUID??
    for line in lines
    where line.kind == .borrowed && line.transactionId == nil && line.occurredAt != nil {
      if main == nil { main = .some(try TransactionRepository.mainAccountId(db)) }
      guard let accountId = line.paymentMethodId ?? main ?? nil,
        let account = try PaymentMethod.fetchOne(db, key: accountId.uuidString),
        let debt = try Debt.fetchOne(db, key: line.debtId.uuidString),
        !account.holds(debt.currency)
      else { continue }
      if let charged = line.accountCurrency, line.accountAmountE4 != nil, account.holds(charged) {
        continue
      }
      throw AccountWriteError.chargeMissing
    }
  }

  /// Deletes accounts under the rules `AccountRepository.delete` keeps: the main account goes
  /// only while another live account is main, and a reconciliation of accounts its deletion
  /// leaves with no count at all goes with it — kept in the journal, so ⌘Z brings it back.
  private static func deleteAccounts(
    _ ids: [UUID], journal: inout UndoJournal, db: Database
  ) throws {
    guard !ids.isEmpty else { return }
    try AccountRepository.refuseDeletingTheMain(Set(ids), db: db)
    let marks = databaseQuestionMarks(count: ids.count)
    let counted = try String.fetchAll(
      db,
      sql: """
        SELECT DISTINCT reconciliation_id FROM reconciliation_balances
        WHERE payment_method_id IN (\(marks)) ORDER BY reconciliation_id
        """,
      arguments: StatementArguments(ids.map(\.uuidString)))
    try journal.delete(PaymentMethod.self, ids: ids, db: db)
    guard !counted.isEmpty else { return }
    let emptied = try String.fetchAll(
      db,
      sql: """
        SELECT id FROM reconciliations
        WHERE id IN (\(databaseQuestionMarks(count: counted.count))) AND kind <> ?
          AND NOT EXISTS (
            SELECT 1 FROM reconciliation_balances WHERE reconciliation_id = reconciliations.id)
        ORDER BY rowid
        """,
      arguments: StatementArguments(counted) + [ReconciliationKind.total.rawValue])
    try journal.delete(Reconciliation.self, ids: emptied.compactMap(UUID.init(uuidString:)), db: db)
  }

  /// Takes a change back in one transaction.
  ///
  /// The operations it deleted come back first, with everything their deletion took along
  /// (`TransactionRepository.restore(ids:at:effects:)`), and the operations it rewrote are
  /// written back as they were — their keys let go first, since the change may have moved one
  /// from one of them to another —, with the money-back links of the parts it dropped and the
  /// refunds in the bin that let go of those parts tied back to them. The
  /// operations it created go for good, with the journal lines
  /// and income links that point at them — deleted first, as `TransactionRepository.purge`
  /// does, since the foreign key would only clear a line's `transaction_id` and leave the debt
  /// moved by a payment that never happened. Then the rows it added go, in the reverse order
  /// of the foreign keys, and the rows it changed or removed are written back as they were, in
  /// the forward order, each at the rowid it had (`PlanningUndo.rowIDs`). The accounts and
  /// groups it added go only after that: a payment, a transfer or a journal line it moved onto
  /// a new account points at it until written back. The settings come last. `instant` stamps
  /// the operations brought back.
  ///
  /// A row changed elsewhere between the change and its undo is written back all the same.
  /// An operation made since that points at a row the change added — filed
  /// under a goal's new subcategory, tagged with a new event, paid from a new account — makes
  /// the undo fail and roll back (`PlanningWriteError.referencedByOperations`, or the schema's
  /// `RESTRICT`).
  public func revert(_ undo: PlanningUndo, at instant: Date = Date()) throws {
    try writer.write { db in try Self.revert(undo, at: instant, db: db) }
  }

  /// `revert` off the calling thread, awaited.
  public func revertInBackground(_ undo: PlanningUndo, at instant: Date = Date()) async throws {
    try await writer.write { db in try Self.revert(undo, at: instant, db: db) }
  }

  static func revert(_ undo: PlanningUndo, at instant: Date, db: Database) throws {
    if !undo.deletion.deletedIds.isEmpty {
      try TransactionRepository.restore(
        ids: undo.deletion.deletedIds, at: instant, effects: undo.deletion, db: db)
    }
    for chunk in undo.rewrittenBefore.map(\.id.uuidString)
      .chunked(by: TransactionRepository.chunkSize)
    {
      try db.execute(
        sql: """
          UPDATE transactions SET external_id = NULL
          WHERE external_id IS NOT NULL AND id IN (\(databaseQuestionMarks(count: chunk.count)))
          """,
        arguments: StatementArguments(Array(chunk)))
    }
    for before in undo.rewrittenBefore {
      // An operation purged since has nothing left to be written over.
      guard let current = try TransactionRepository.entry(id: before.id, db: db) else {
        continue
      }
      try TransactionRepository.write(before, over: current, db: db)
    }
    try TransactionRepository.relink(undo.releasedRefunds, db: db)
    for link in undo.removedLinks {
      // A link whose money back or part is gone since has nothing to come back to.
      guard try CoreKit.Transaction.exists(db, key: link.reimbursementTxId.uuidString),
        try TransactionPart.exists(db, key: link.partId.uuidString)
      else { continue }
      try link.save(db)
    }

    for chunk in undo.createdTransactionIds.map(\.uuidString)
      .chunked(by: TransactionRepository.chunkSize)
    {
      let ids = StatementArguments(Array(chunk))
      let marks = databaseQuestionMarks(count: chunk.count)
      try db.execute(
        sql: "DELETE FROM debt_entries WHERE transaction_id IN (\(marks))", arguments: ids)
      try db.execute(
        sql: "DELETE FROM expected_income_links WHERE transaction_id IN (\(marks))",
        arguments: ids)
      try db.execute(sql: "DELETE FROM transactions WHERE id IN (\(marks))", arguments: ids)
    }

    let added = undo.inserted
    try Self.deleteAll(ReconciledBalance.self, ids: added.reconciledBalances, db: db)
    try Self.deleteAll(Reconciliation.self, ids: added.reconciliations, db: db)
    try Self.deleteAll(Transfer.self, ids: added.transfers, db: db)
    try Self.deleteAll(ExpectedIncomeLink.self, ids: added.expectedLinks, db: db)
    try Self.deleteAll(DebtEntry.self, ids: added.debtEntries, db: db)
    try Self.deleteAll(Budget.self, ids: added.budgets, db: db)
    try Self.deleteAll(ExpectedIncome.self, ids: added.expected, db: db)
    try Self.deleteAll(SubscriptionPrice.self, ids: added.prices, db: db)
    try Self.deleteAll(ScheduledPayment.self, ids: added.scheduled, db: db)
    try Self.deleteAll(Debt.self, ids: added.debts, db: db)
    try Self.deleteAll(Goal.self, ids: added.goals, db: db)
    try Self.deleteAll(Event.self, ids: added.events, db: db)
    for id in try Self.childrenFirst(added.categories, db: db) {
      _ = try CoreKit.Category.deleteOne(db, key: id.uuidString)
    }

    let before = undo.before
    for row in before.accountGroups { try row.save(db) }
    for row in before.paymentMethods { try row.save(db) }
    for category in Self.parentsFirst(before.categories) { try category.save(db) }
    // Only where the link is still empty: the deletion did nothing else to these rows, and
    // a category given to one of them since is the owner's, not the deletion's.
    for reference in undo.cleared {
      try db.execute(
        sql: """
          UPDATE \(reference.table) SET \(reference.column) = ?
          WHERE id = ? AND \(reference.column) IS NULL
          """,
        arguments: [reference.categoryId.uuidString, reference.rowId])
    }
    for row in before.events { try row.save(db) }
    for row in before.goals { try row.save(db) }
    for row in before.debts { try row.save(db) }
    for row in before.scheduled { try row.save(db) }
    for row in before.prices { try row.save(db) }
    for row in before.expected { try row.save(db) }
    for row in before.budgets { try row.save(db) }
    for row in before.debtEntries { try row.save(db) }
    for row in before.expectedLinks { try row.save(db) }
    for row in before.transfers { try row.save(db) }
    for row in before.reconciliations { try row.save(db) }
    for row in before.reconciledBalances { try row.save(db) }
    // Nothing written back points at an account or a group the change added, while rows it
    // moved onto them did until now: they go here, still under the refusal of `apply`, and
    // before the rowids are put back, so a removed account gets back a rowid a new one took.
    try Self.deleteAll(PaymentMethod.self, ids: added.paymentMethods, db: db)
    try Self.deleteAll(AccountGroup.self, ids: added.accountGroups, db: db)
    try Self.restoreRowIDs(before.accountGroups, undo.rowIDs, db: db)
    try Self.restoreRowIDs(before.paymentMethods, undo.rowIDs, db: db)
    try Self.restoreRowIDs(before.categories, undo.rowIDs, db: db)
    try Self.restoreRowIDs(before.events, undo.rowIDs, db: db)
    try Self.restoreRowIDs(before.goals, undo.rowIDs, db: db)
    try Self.restoreRowIDs(before.debts, undo.rowIDs, db: db)
    try Self.restoreRowIDs(before.budgets, undo.rowIDs, db: db)
    try Self.restoreRowIDs(before.debtEntries, undo.rowIDs, db: db)
    try Self.restoreRowIDs(before.expectedLinks, undo.rowIDs, db: db)
    try Self.restoreRowIDs(before.prices, undo.rowIDs, db: db)
    try Self.restoreRowIDs(before.reconciliations, undo.rowIDs, db: db)
    try Self.restoreRowIDs(before.reconciledBalances, undo.rowIDs, db: db)
    try Self.restoreRowIDs(before.transfers, undo.rowIDs, db: db)
    try Self.restoreRowIDs(before.scheduled, undo.rowIDs, db: db)
    try Self.restoreRowIDs(before.expected, undo.rowIDs, db: db)

    for (key, value) in undo.settingsBefore.sorted(by: { $0.key < $1.key }) {
      try Self.setSetting(key, to: value, db: db)
    }
  }

  /// Moves rows written back by `revert` to the rowid they had. `save` inserts a removed
  /// row at a new rowid, which would put it last in every list read in rowid order. A rowid
  /// another row took in the meantime is left alone (`OR IGNORE`): the row then stays last,
  /// which is all that happens.
  ///
  /// Rows written back together can land at each other's rowids — two limits removed later
  /// one first come back at the first free rowids in that order — so every row that is not
  /// at its own is first moved past the last rowid, out of the way, and only then put back:
  /// otherwise each would find its place taken by the other and both would stay swapped.
  private static func restoreRowIDs<Record: PlanningRow>(
    _ rows: [Record], _ rowIDs: [UUID: Int64], db: Database
  ) throws {
    let table = Record.databaseTableName
    let moving = rows.compactMap { row in
      rowIDs[row.id].map { (id: row.id.uuidString, rowID: $0) }
    }
    for row in moving {
      try db.execute(
        sql: """
          UPDATE \(table) SET rowid = (SELECT MAX(rowid) + 1 FROM \(table))
          WHERE id = ? AND rowid <> ?
          """,
        arguments: [row.id, row.rowID])
    }
    for row in moving {
      try db.execute(
        sql: "UPDATE OR IGNORE \(table) SET rowid = ? WHERE id = ? AND rowid <> ?",
        arguments: [row.rowID, row.id, row.rowID])
    }
  }

  // MARK: Reading

  public func scheduled() throws -> [ScheduledPayment] {
    try writer.read { db in try Self.scheduled(db) }
  }

  public func budgets() throws -> [Budget] {
    try writer.read { db in try Self.budgets(db) }
  }

  public func expected() throws -> [ExpectedIncome] {
    try writer.read { db in try Self.expected(db) }
  }

  /// Oldest first.
  public func reconciliations() throws -> [Reconciliation] {
    try writer.read { db in try ReconciliationRepository.all(db) }
  }

  /// The whole planning book in one read — what `DatasetRepository.load` puts in the dataset.
  public func book() throws -> PlanningBook {
    try writer.read { db in try Self.book(db) }
  }

  /// The planning book inside a read the caller already holds. Debt journals come for every
  /// debt, the closed ones included, like the debts themselves; the balances counted on the
  /// accounts come in the order of their reconciliations.
  static func book(_ db: Database) throws -> PlanningBook {
    PlanningBook(
      scheduled: try scheduled(db),
      prices: try prices(db),
      expected: try expected(db),
      expectedLinks: try ExpectedIncomeLink.order(Column.rowID).fetchAll(db),
      budgets: try budgets(db),
      reconciliations: try ReconciliationRepository.all(db),
      debtEntries: try debtEntries(db),
      settings: try settings(db),
      reconciledBalances: try ReconciliationRepository.balances(db))
  }

  /// Each payment's prices by day.
  private static func prices(_ db: Database) throws -> [SubscriptionPrice] {
    try SubscriptionPrice.order(Column("payment_id"), Column("date"), Column.rowID).fetchAll(db)
  }

  /// Each debt's journal by day, undated lines first (SQLite sorts NULL first), lines of one
  /// day in the order they were written.
  private static func debtEntries(_ db: Database) throws -> [DebtEntry] {
    try DebtEntry.order(Column("debt_id"), Column("date"), Column.rowID).fetchAll(db)
  }

  private static func scheduled(_ db: Database) throws -> [ScheduledPayment] {
    try ScheduledPayment.order(Column("name"), Column.rowID).fetchAll(db)
  }

  private static func expected(_ db: Database) throws -> [ExpectedIncome] {
    try ExpectedIncome.order(Column("name"), Column.rowID).fetchAll(db)
  }

  /// In the order they were made.
  private static func budgets(_ db: Database) throws -> [Budget] {
    try Budget.order(Column.rowID).fetchAll(db)
  }

  static func settings(_ db: Database) throws -> PlanningSettings {
    let keys = PlanningSettings.storageKeys
    let marks = databaseQuestionMarks(count: keys.count)
    let rows = try Row.fetchAll(
      db, sql: "SELECT key, value FROM settings WHERE key IN (\(marks))",
      arguments: StatementArguments(keys))
    var values: [String: String] = [:]
    for row in rows {
      values[row["key"]] = row["value"]
    }
    return PlanningSettings(storedValues: values)
  }

  // MARK: Helpers

  private static func setting(_ key: String, db: Database) throws -> String? {
    try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
  }

  private static func setSetting(_ key: String, to value: String?, db: Database) throws {
    if let value {
      try db.execute(
        sql: """
          INSERT INTO settings (key, value) VALUES (?, ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value
          """,
        arguments: [key, value])
    } else {
      try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
    }
  }

  /// Rows undo takes away, under the same refusal as a deletion of `apply`.
  private static func deleteAll<Record: PlanningRow>(
    _ type: Record.Type, ids: [UUID], db: Database
  ) throws {
    guard !ids.isEmpty else { return }
    for id in ids { try Record.refuseDeletion(of: id, db: db) }
    _ = try Record.deleteAll(db, keys: ids.map(\.uuidString))
  }

  /// The table refers to itself: a parent is written before its subcategories.
  private static func parentsFirst(_ categories: [CoreKit.Category]) -> [CoreKit.Category] {
    categories.filter { $0.parentId == nil } + categories.filter { $0.parentId != nil }
  }

  /// …and a subcategory is deleted before its parent, which it would otherwise hold on to
  /// (`ON DELETE RESTRICT`). Ids of categories that are not there are left out.
  private static func childrenFirst(_ ids: [UUID], db: Database) throws -> [UUID] {
    guard !ids.isEmpty else { return [] }
    let rows = try CoreKit.Category.fetchAll(db, keys: ids.map(\.uuidString))
    return rows.filter { $0.parentId != nil }.map(\.id)
      + rows.filter { $0.parentId == nil }.map(\.id)
  }
}

// MARK: - Undo journal

/// A row the planning writes and undo puts back: where its list lives in `PlanningRows` and
/// in `PlanningRowIDs`, and what deleting it does besides.
protocol PlanningRow: FetchableRecord, PersistableRecord, Identifiable where ID == UUID {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { get }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { get }

  /// Throws when the row may not be deleted — by `apply`, nor by `revert` taking back a row
  /// it added.
  static func refuseDeletion(of id: UUID, db: Database) throws

  /// Right before `apply` deletes a row: reads into the journal the rows of the planning
  /// the schema cascades the deletion to, or clears a reference of.
  static func keepDependents(of id: UUID, journal: inout UndoJournal, db: Database) throws
}

extension PlanningRow {
  static func refuseDeletion(of id: UUID, db: Database) throws {}
  static func keepDependents(of id: UUID, journal: inout UndoJournal, db: Database) throws {}
}

/// What `apply` has seen of the rows it touched. The first sight of a row is the one that
/// counts: that is the row as it was before the change, whatever the change did to it later.
struct UndoJournal {
  private(set) var before = PlanningRows.empty
  private(set) var inserted = PlanningRowIDs.empty
  /// The rowid of every row kept in `before`, read before it could go.
  private(set) var rowIDs: [UUID: Int64] = [:]
  /// Links a deletion clears in tables the planning does not write.
  private(set) var cleared: [ClearedReference] = []
  private var seen: Set<RowKey> = []

  private struct RowKey: Hashable {
    var table: String
    var id: UUID
  }

  mutating func upsert<Record: PlanningRow>(_ rows: [Record], db: Database) throws {
    for row in rows {
      if firstSight(of: Record.self, id: row.id) {
        if let current = try Record.fetchOne(db, key: row.id.uuidString) {
          before[keyPath: Record.rows].append(current)
        } else {
          inserted[keyPath: Record.ids].append(row.id)
        }
      }
      try row.save(db)
    }
  }

  /// Ids that are not there are passed over.
  mutating func delete<Record: PlanningRow>(
    _ type: Record.Type, ids: [UUID], db: Database
  ) throws {
    for id in ids {
      guard let current = try Record.fetchOne(db, key: id.uuidString) else { continue }
      try Record.refuseDeletion(of: id, db: db)
      try Record.keepDependents(of: id, journal: &self, db: db)
      try keepRowID(of: current, db: db)
      keep(current)
      _ = try Record.deleteOne(db, key: id.uuidString)
    }
  }

  /// Rows of a table the planning does not write whose `column` points at `id`: the schema
  /// clears the link when `id` goes (`ON DELETE SET NULL`), and undo sets it back.
  mutating func keepReference(table: String, column: String, to id: UUID, db: Database) throws {
    let rows = try String.fetchAll(
      db, sql: "SELECT id FROM \(table) WHERE \(column) = ? ORDER BY rowid",
      arguments: [id.uuidString])
    cleared += rows.map {
      ClearedReference(table: table, column: column, rowId: $0, categoryId: id)
    }
  }

  /// Rows of `Record` whose `column` points at `id`, kept as they are now.
  mutating func keepRows<Record: PlanningRow>(
    _ type: Record.Type, where column: String, is id: UUID, db: Database
  ) throws {
    for row in try Record.filter(Column(column) == id.uuidString).fetchAll(db) {
      try keepRowID(of: row, db: db)
      keep(row)
    }
  }

  /// Takes the main flag from every account but `id`, the archived ones included, keeping
  /// each as it was, so ⌘Z gives the flag back to where it was.
  mutating func takeMainFlag(for id: UUID, db: Database) throws {
    let others =
      try PaymentMethod
      .filter(Column("is_default") == true && Column("id") != id.uuidString)
      .order(Column.rowID)
      .fetchAll(db)
    guard !others.isEmpty else { return }
    for row in others {
      try keepRowID(of: row, db: db)
      keep(row)
    }
    try db.execute(
      sql: "UPDATE payment_methods SET is_default = 0 WHERE is_default = 1 AND id <> ?",
      arguments: [id.uuidString])
  }

  private mutating func keepRowID<Record: PlanningRow>(of row: Record, db: Database) throws {
    guard rowIDs[row.id] == nil else { return }
    rowIDs[row.id] = try Int64.fetchOne(
      db, sql: "SELECT rowid FROM \(Record.databaseTableName) WHERE id = ?",
      arguments: [row.id.uuidString])
  }

  private mutating func keep<Record: PlanningRow>(_ row: Record) {
    guard firstSight(of: Record.self, id: row.id) else { return }
    before[keyPath: Record.rows].append(row)
  }

  private mutating func firstSight<Record: PlanningRow>(of type: Record.Type, id: UUID) -> Bool {
    seen.insert(RowKey(table: Record.databaseTableName, id: id)).inserted
  }
}

/// Refuses to delete a row that operations point at, deleted operations included: undo of
/// their deletion would bring them back pointing at nothing. `sql` names the row `:id`.
private func refuseIfOperations(_ sql: String, point id: UUID, db: Database) throws {
  let found = try Bool.fetchOne(
    db, sql: "SELECT EXISTS (\(sql))", arguments: ["id": id.uuidString])
  if found == true { throw PlanningWriteError.referencedByOperations(id) }
}

extension CoreKit.Category: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.categories }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.categories }

  /// Every row in `dependents` that points at the category, kept before it goes.
  static func keepDependents(of id: UUID, journal: inout UndoJournal, db: Database) throws {
    for (table, column) in dependents {
      switch table {
      case Goal.databaseTableName: try journal.keepRows(Goal.self, where: column, is: id, db: db)
      case Debt.databaseTableName: try journal.keepRows(Debt.self, where: column, is: id, db: db)
      case ScheduledPayment.databaseTableName:
        try journal.keepRows(ScheduledPayment.self, where: column, is: id, db: db)
      case ExpectedIncome.databaseTableName:
        try journal.keepRows(ExpectedIncome.self, where: column, is: id, db: db)
      case Budget.databaseTableName:
        try journal.keepRows(Budget.self, where: column, is: id, db: db)
      default: try journal.keepReference(table: table, column: column, to: id, db: db)
      }
    }
  }

  /// Every column of another table that points at a category and is not `RESTRICT`
  /// (operations are refused by the schema itself, `ON DELETE RESTRICT` on their parts).
  /// Limits on the category go with it; goals, debts, payments and expected income filed
  /// under it lose the reference; these rows of the planning are kept whole. The rest are
  /// not rows the planning writes — a template of the entry line, a mapping of the import, a
  /// correction of the model — and lose only the link (`ON DELETE SET NULL`), which is all
  /// that is kept and all undo sets back. A test holds this list against the foreign keys of
  /// the schema, so a column a later migration adds cannot be forgotten.
  static let dependents: [(table: String, column: String)] = [
    ("goals", "subcategory_id"), ("debts", "loans_subcategory_id"),
    ("scheduled_payments", "category_id"), ("expected_income", "category_id"),
    ("budgets", "category_id"), ("templates", "category_id"),
    ("import_mappings", "target_category_id"), ("category_feedback", "predicted_category_id"),
    ("category_feedback", "chosen_category_id"),
  ]
}

extension Event: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.events }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.events }

  static func refuseDeletion(of id: UUID, db: Database) throws {
    try refuseIfOperations(
      "SELECT 1 FROM transaction_parts WHERE event_id = :id", point: id, db: db)
  }
}

extension Goal: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.goals }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.goals }

  static func refuseDeletion(of id: UUID, db: Database) throws {
    try refuseIfOperations(
      "SELECT 1 FROM transaction_parts WHERE goal_id = :id", point: id, db: db)
  }
}

extension Debt: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.debts }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.debts }

  static func refuseDeletion(of id: UUID, db: Database) throws {
    try refuseIfOperations(
      "SELECT 1 FROM transactions WHERE debt_id = :id OR credit_debt_id = :id", point: id, db: db)
  }

  /// Its journal goes with it.
  static func keepDependents(of id: UUID, journal: inout UndoJournal, db: Database) throws {
    try journal.keepRows(DebtEntry.self, where: "debt_id", is: id, db: db)
  }
}

extension ScheduledPayment: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.scheduled }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.scheduled }

  /// Its price history goes with it.
  static func keepDependents(of id: UUID, journal: inout UndoJournal, db: Database) throws {
    try journal.keepRows(SubscriptionPrice.self, where: "payment_id", is: id, db: db)
  }
}

extension SubscriptionPrice: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.prices }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.prices }
}

extension ExpectedIncome: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.expected }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.expected }

  /// Its links to the income received go with it; the operations stay.
  static func keepDependents(of id: UUID, journal: inout UndoJournal, db: Database) throws {
    try journal.keepRows(ExpectedIncomeLink.self, where: "expected_income_id", is: id, db: db)
  }
}

extension ExpectedIncomeLink: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.expectedLinks }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.expectedLinks }
}

extension Budget: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.budgets }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.budgets }
}

extension DebtEntry: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.debtEntries }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.debtEntries }
}

extension Reconciliation: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.reconciliations }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.reconciliations }

  /// The balances it counted go with it.
  static func keepDependents(of id: UUID, journal: inout UndoJournal, db: Database) throws {
    try journal.keepRows(ReconciledBalance.self, where: "reconciliation_id", is: id, db: db)
  }
}

extension ReconciledBalance: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.reconciledBalances }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.reconciledBalances }
}

extension AccountGroup: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.accountGroups }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.accountGroups }

  /// The accounts filed under it lose the group (`ON DELETE SET NULL`); they are kept whole.
  static func keepDependents(of id: UUID, journal: inout UndoJournal, db: Database) throws {
    try journal.keepRows(PaymentMethod.self, where: "group_id", is: id, db: db)
  }
}

extension PaymentMethod: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.paymentMethods }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.paymentMethods }

  /// An account anything has moved money on, or will, is archived, never deleted: operations,
  /// deleted ones included, transfers, scheduled payments and lines of a debt journal.
  static func refuseDeletion(of id: UUID, db: Database) throws {
    try refuseIfOperations(
      """
      SELECT 1 FROM transactions WHERE payment_method_id = :id
      UNION ALL SELECT 1 FROM transfers
        WHERE from_payment_method_id = :id OR to_payment_method_id = :id
      UNION ALL SELECT 1 FROM scheduled_payments WHERE payment_method_id = :id
      UNION ALL SELECT 1 FROM debt_entries WHERE payment_method_id = :id
      """, point: id, db: db)
  }

  /// The balances counted on it go with it (`ON DELETE CASCADE`).
  static func keepDependents(of id: UUID, journal: inout UndoJournal, db: Database) throws {
    try journal.keepRows(ReconciledBalance.self, where: "payment_method_id", is: id, db: db)
  }
}

extension Transfer: PlanningRow {
  static var rows: WritableKeyPath<PlanningRows, [Self]> { \.transfers }
  static var ids: WritableKeyPath<PlanningRowIDs, [UUID]> { \.transfers }
}
