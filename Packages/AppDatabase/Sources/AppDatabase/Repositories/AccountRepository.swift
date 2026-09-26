import AppCore
import CoreKit
import Foundation
import GRDB

/// What points at an account: everything that keeps it from being deleted.
public struct AccountUsage: Hashable, Sendable {
  /// Operations on it, the deleted ones in the bin included: undoing their deletion would
  /// bring them back on an account that is not there.
  public var operations: Int
  /// Transfers from it or to it.
  public var transfers: Int
  public var scheduled: Int
  /// Lines of debt journals that moved money on it.
  public var debtEntries: Int

  public init(operations: Int = 0, transfers: Int = 0, scheduled: Int = 0, debtEntries: Int = 0) {
    self.operations = operations
    self.transfers = transfers
    self.scheduled = scheduled
    self.debtEntries = debtEntries
  }

  public var isUsed: Bool { operations + transfers + scheduled + debtEntries > 0 }
}

/// What `AccountRepository.ensureMainAccount()` put right, for the journal.
public struct MainAccountRepair: Hashable, Sendable {
  /// The one live main account now.
  public var mainId: UUID
  /// It was not flagged main before.
  public var madeMain: Bool
  /// How many other accounts lost the flag, archived ones included.
  public var cleared: Int

  public init(mainId: UUID, madeMain: Bool, cleared: Int) {
    self.mainId = mainId
    self.madeMain = madeMain
    self.cleared = cleared
  }
}

/// Why a write of the accounts was not made. Nothing is written then.
public enum AccountWriteError: Error, Equatable, Sendable {
  /// The account is used (`AccountUsage`): it can be archived or merged, not deleted.
  case inUse(AccountUsage)
  /// It is the main account, and no other live account has taken that over.
  case isMain
  /// Accounts are filed under the group, archived ones included.
  case groupInUse
  /// The accounts would need more currencies switched on than the ten allowed.
  case tooManyCurrencies
  /// An operation that moves money on an account that does not hold its currency, saved
  /// without what the account moved (`Transaction.accountCurrency`/`accountAmountE4`).
  case chargeMissing
  /// The account or the group is not there.
  case notFound
}

/// The accounts and their groups: reading them, and the writes that cannot be undone — the
/// setup of the accounts, a merge, a deletion. Everything else about an account (a new one, a
/// rename, the archive, the order, a group) is a `PlanningChange`, one step of ⌘Z.
///
/// A write of this repository is no step of ⌘Z, and a step taken before it may name what it
/// deleted or moved: taking that step back would fail on an account that is gone, or put rows
/// back on an account merged away. So the caller forgets the ⌘Z history after each one
/// (`TransactionsStore.forgetUndoHistory()`), as after recording money back.
public struct AccountRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  // MARK: Reading

  /// By name; the order of the lists is the core's (the main account first, then the order
  /// the owner chose).
  public func accounts(includeArchived: Bool = false) throws -> [PaymentMethod] {
    try writer.read { db in
      var request = PaymentMethod.all()
      if !includeArchived { request = request.filter(Column("archived") == false) }
      return try request.order(Column("name"), Column.rowID).fetchAll(db)
    }
  }

  /// In the owner's order, then by name.
  public func groups(includeArchived: Bool = false) throws -> [AccountGroup] {
    try writer.read { db in
      var request = AccountGroup.all()
      if !includeArchived { request = request.filter(Column("archived") == false) }
      return try request.order(Column("sort"), Column("name")).fetchAll(db)
    }
  }

  public func usage(of accountId: UUID) throws -> AccountUsage {
    try writer.read { db in try Self.usage(of: accountId, db: db) }
  }

  static func usage(of accountId: UUID, db: Database) throws -> AccountUsage {
    func count(_ sql: String) throws -> Int {
      try Int.fetchOne(db, sql: sql, arguments: ["id": accountId.uuidString]) ?? 0
    }
    return AccountUsage(
      operations: try count("SELECT COUNT(*) FROM transactions WHERE payment_method_id = :id"),
      transfers: try count(
        """
        SELECT COUNT(*) FROM transfers
        WHERE from_payment_method_id = :id OR to_payment_method_id = :id
        """),
      scheduled: try count(
        "SELECT COUNT(*) FROM scheduled_payments WHERE payment_method_id = :id"),
      debtEntries: try count("SELECT COUNT(*) FROM debt_entries WHERE payment_method_id = :id"))
  }

  // MARK: Deleting

  /// Deletes an account nothing points at, for good. The balances counted on it go with it,
  /// and so does a reconciliation of accounts left with no balance at all; a total of the
  /// time before accounts is history and stays. The main account goes only once another live
  /// account is main.
  ///
  /// Throws `AccountWriteError.inUse`, `.isMain` or `.notFound`; nothing is written then.
  /// Forget the ⌘Z history after it (see the type).
  public func delete(_ accountId: UUID) throws {
    try writer.write { db in
      guard try PaymentMethod.exists(db, key: accountId.uuidString) else {
        throw AccountWriteError.notFound
      }
      let usage = try Self.usage(of: accountId, db: db)
      guard !usage.isUsed else { throw AccountWriteError.inUse(usage) }
      try Self.refuseDeletingTheMain([accountId], db: db)
      let reconciliations = try String.fetchAll(
        db,
        sql: """
          SELECT DISTINCT reconciliation_id FROM reconciliation_balances
          WHERE payment_method_id = ?
          """,
        arguments: [accountId.uuidString])
      _ = try PaymentMethod.deleteOne(db, key: accountId.uuidString)
      for id in reconciliations {
        try db.execute(
          sql: """
            DELETE FROM reconciliations
            WHERE id = ? AND kind <> ?
              AND NOT EXISTS (
                SELECT 1 FROM reconciliation_balances WHERE reconciliation_id = reconciliations.id)
            """,
          arguments: [id, ReconciliationKind.total.rawValue])
      }
    }
  }

  /// Deletes a group no account is filed under, archived accounts included, for good.
  /// Throws `AccountWriteError.groupInUse` or `.notFound`.
  public func deleteGroup(_ id: UUID) throws {
    try writer.write { db in
      guard try AccountGroup.exists(db, key: id.uuidString) else {
        throw AccountWriteError.notFound
      }
      let used =
        try Bool.fetchOne(
          db, sql: "SELECT EXISTS (SELECT 1 FROM payment_methods WHERE group_id = ?)",
          arguments: [id.uuidString]) ?? false
      guard !used else { throw AccountWriteError.groupInUse }
      _ = try AccountGroup.deleteOne(db, key: id.uuidString)
    }
  }

  // MARK: Merging

  /// Merges one account into another in one write, for good (a merge is not undone, as with
  /// every other merge of the reference books). The plan is worked out beforehand
  /// (`AccountMergePlan`): the repository only writes it.
  ///
  /// 1. The transfers of `deletedTransferIds` go: between the two accounts in one currency
  ///    they would be transfers of an account to itself. Their fees stay, as ordinary
  ///    expenses.
  /// 2. Whatever pointed at the source points at the target (`ReferenceRepository.repoint`);
  ///    the balances counted on the source stay its history.
  /// 3. The target is written as the plan has it — the currencies of both — and is the main
  ///    account when the plan makes it so or when the source or the target was main before:
  ///    a merge never leaves the accounts without a main one. Then no other account is main.
  /// 4. The source goes to the archive, no longer main.
  /// 5. One reconciliation of kind `opening`, at `at`, counts the target in every currency of
  ///    `opening` and the source at zero in every currency of `sourceZero`, so bringing the
  ///    source back never counts its money twice. A key counted before (`hadAnchor`) compares,
  ///    with no difference; any other is a starting point. With nothing to count there is no
  ///    such reconciliation.
  ///
  /// The fees of the deleted transfers lose their key `transfer:<id>:fee` in the same write:
  /// the transfer they pointed at is gone. `calendar` gives the reconciliation its day.
  /// Forget the ⌘Z history after it (see the type).
  public func merge(_ plan: AccountMergePlan, calendar: CalendarContext) throws {
    guard plan.sourceId != plan.target.id else { return }
    try writer.write { db in
      guard try PaymentMethod.exists(db, key: plan.sourceId.uuidString),
        try PaymentMethod.exists(db, key: plan.target.id.uuidString)
      else { throw AccountWriteError.notFound }
      let wasMain =
        try Bool.fetchOne(
          db,
          sql: """
            SELECT EXISTS (
              SELECT 1 FROM payment_methods
              WHERE is_default = 1 AND archived = 0 AND id IN (?, ?))
            """,
          arguments: [plan.sourceId.uuidString, plan.target.id.uuidString]) ?? false
      for transferId in plan.deletedTransferIds {
        try db.execute(
          sql: "UPDATE transactions SET external_id = NULL WHERE external_id = ?",
          arguments: [OperationLink.transferFee(transferId).externalId])
      }
      _ = try Transfer.deleteAll(db, keys: plan.deletedTransferIds.map(\.uuidString))
      try ReferenceRepository.repoint(
        "payment_methods", from: plan.sourceId, to: plan.target.id, db: db)
      var target = plan.target
      target.isDefault = target.isDefault || wasMain
      try ReferenceRepository.save(target, db: db)
      try db.execute(
        sql: "UPDATE payment_methods SET archived = 1, is_default = 0 WHERE id = ?",
        arguments: [plan.sourceId.uuidString])

      var counts: [(key: BalanceKey, actual: AmountE4, compares: Bool)] = []
      for (key, amount) in plan.opening.sorted(by: { $0.key < $1.key }) {
        counts.append((key, amount, plan.hadAnchor.contains(key)))
      }
      for key in plan.sourceZero.sorted() where plan.opening[key] == nil {
        counts.append((key, .zero, plan.hadAnchor.contains(key)))
      }
      guard !counts.isEmpty else { return }
      try Self.writeOpening(
        at: plan.at, calendar: calendar,
        balances: counts.map { count in
          (count.key, count.actual, count.compares ? count.actual : nil)
        },
        db: db)
    }
  }

  // MARK: Setup

  /// Writes the setup of the accounts in one write, for good:
  ///
  /// 1. the groups and 2. the accounts, as the plan has them;
  /// 3. the main account, and no other;
  /// 4. one reconciliation of kind `opening` at `at` with the balances counted — the starting
  ///    point of each account and currency, or, for a key a reconciliation had already
  ///    counted (`expected`), a count compared with what was expected, whose difference is
  ///    shown and never written as an operation;
  /// 5. every currency an account holds, and the default one, switched on — refused with
  ///    `AccountWriteError.tooManyCurrencies` beyond ten;
  /// 6. the default currency, when the plan chose one;
  /// 7. the setup marked done;
  /// 8. every operation without an account given the main one.
  ///
  /// `calendar` gives the reconciliation its day. Forget the ⌘Z history after it (see the
  /// type).
  public func finishSetup(_ plan: AccountSetupPlan, calendar: CalendarContext) throws {
    try writer.write { db in
      for group in plan.groups { try group.save(db) }
      for account in plan.accounts { try account.save(db) }
      guard try PaymentMethod.exists(db, key: plan.mainAccountId.uuidString) else {
        throw AccountWriteError.notFound
      }
      try Self.makeMain(plan.mainAccountId, db: db)

      let balances = plan.openingBalances.sorted { $0.key < $1.key }.map { key, amount in
        (key, amount, plan.expected[key])
      }
      if !balances.isEmpty {
        try Self.writeOpening(at: plan.at, calendar: calendar, balances: balances, db: db)
      }

      var held: [CurrencyCode] = []
      for account in try PaymentMethod.filter(Column("archived") == false).fetchAll(db) {
        for currency in account.currencies where !held.contains(currency) {
          held.append(currency)
        }
      }
      let defaultCurrency = try plan.defaultCurrency ?? SettingsRepository.defaultCurrency(db)
      do {
        try SettingsRepository.enableAlso(held + [defaultCurrency], db: db)
      } catch SettingsWriteError.tooManyCurrencies {
        throw AccountWriteError.tooManyCurrencies
      }
      if let chosen = plan.defaultCurrency {
        try SettingsRepository.set(AccountSettings.defaultCurrencyKey, to: chosen.code, in: db)
      }
      try SettingsRepository.set(
        AccountSettings.setupKey, to: AccountSettings.Setup.done.rawValue, in: db)
      try Self.assignUnassigned(to: plan.mainAccountId, db: db)
    }
  }

  /// «Позже»: the setup is put off, and the operations still need an account. When no live
  /// account is main, one is made — named `mainAccountName`, a bank account in
  /// `defaultCurrency` — and every operation without an account gets the main one, in the
  /// same write. `at` is when the owner put it off. Forget the ⌘Z history after it (see the
  /// type).
  public func postponeSetup(
    mainAccountName: String, defaultCurrency: CurrencyCode, at: Date
  ) throws {
    try writer.write { db in
      let main: UUID
      if let existing = try String.fetchOne(
        db,
        sql: """
          SELECT id FROM payment_methods WHERE is_default = 1 AND archived = 0
          ORDER BY rowid LIMIT 1
          """
      ).flatMap(UUID.init(uuidString:)) {
        main = existing
      } else {
        let account = PaymentMethod(
          name: mainAccountName, kind: .account, currency: defaultCurrency, isDefault: true)
        try ReferenceRepository.save(account, db: db)
        main = account.id
      }
      try Self.assignUnassigned(to: main, db: db)
      try SettingsRepository.set(
        AccountSettings.setupKey, to: AccountSettings.Setup.later.rawValue, in: db)
    }
  }

  // MARK: The main account

  /// Exactly one live account is main. Two left flagged by a write cut short, an archived one
  /// still flagged, or none among live accounts are put right in one write, by the rule of the
  /// update of an older database (`AccountsMigration.repair`): the most used of the live
  /// accounts flagged main, else of all live accounts, the one written first on a tie — chosen
  /// among the accounts in the summary whenever there is one, since the money of the main
  /// account always counts. Nothing is made: with no live account at all, the setup of the
  /// accounts makes the first one.
  ///
  /// The app runs it on every open, before anything reads the accounts. Returns `nil` when
  /// nothing needed to change. Not a step of ⌘Z: it restores what every step assumes.
  @discardableResult
  public func ensureMainAccount() throws -> MainAccountRepair? {
    try writer.write { db in
      var ids: [UUID: String] = [:]
      var accounts: [MigratingAccount] = []
      // An account whose group is gone counts as in no group, as everywhere else.
      for row in try Row.fetchAll(
        db,
        sql: """
          SELECT p.rowid AS rowid, p.id AS id, p.name AS name, p.archived AS archived,
            p.is_default AS is_default, COALESCE(g.in_summary, 1) AS in_summary
          FROM payment_methods p LEFT JOIN account_groups g ON g.id = p.group_id
          """)
      {
        // An account without an id, or one that is no UUID — a hand edit, another program —
        // cannot be chosen; a flag that is no number stops the repair as it stops every read.
        guard let text: String = row["id"], let id = UUID(uuidString: text) else { continue }
        ids[id] = text
        accounts.append(
          MigratingAccount(
            id: id, name: row["name"] ?? "",
            archived: try RowMapping.flag(row, "archived", fallback: false),
            isDefault: try RowMapping.flag(row, "is_default", fallback: false), rowid: row["rowid"],
            inSummary: try RowMapping.flag(row, "in_summary", fallback: true)))
      }
      var live: [UUID: Int] = [:]
      for row in try Row.fetchAll(
        db,
        sql: """
          SELECT payment_method_id, COUNT(*) FROM transactions
          WHERE deleted_at IS NULL AND payment_method_id IS NOT NULL
          GROUP BY payment_method_id
          """)
      {
        guard let text: String = row[0], let id = UUID(uuidString: text) else { continue }
        live[id, default: 0] += row[1]
      }
      guard let repair = AccountsMigration.repair(accounts: accounts, liveOperations: live),
        let main = ids[repair.mainId]
      else { return nil }
      try db.execute(
        sql: "UPDATE payment_methods SET is_default = 0 WHERE is_default = 1 AND id <> ?",
        arguments: [main])
      let cleared = db.changesCount
      try db.execute(
        sql: "UPDATE payment_methods SET is_default = 1 WHERE id = ? AND is_default = 0",
        arguments: [main])
      return MainAccountRepair(
        mainId: repair.mainId, madeMain: db.changesCount > 0, cleared: cleared)
    }
  }

  // MARK: Helpers

  /// Refuses, with `AccountWriteError.isMain`, to delete these accounts when one of them is
  /// flagged main and no other live account is: the accounts are never left without a main
  /// one.
  static func refuseDeletingTheMain(_ ids: Set<UUID>, db: Database) throws {
    guard !ids.isEmpty else { return }
    let marks = databaseQuestionMarks(count: ids.count)
    let arguments = StatementArguments(ids.map(\.uuidString).sorted())
    let deletesMain =
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS (
            SELECT 1 FROM payment_methods WHERE is_default = 1 AND id IN (\(marks)))
          """,
        arguments: arguments) ?? false
    guard deletesMain else { return }
    let anotherMain =
      try Bool.fetchOne(
        db,
        sql: """
          SELECT EXISTS (
            SELECT 1 FROM payment_methods
            WHERE is_default = 1 AND archived = 0 AND id NOT IN (\(marks)))
          """,
        arguments: arguments) ?? false
    guard anotherMain else { throw AccountWriteError.isMain }
  }

  private static func makeMain(_ id: UUID, db: Database) throws {
    try db.execute(
      sql: "UPDATE payment_methods SET is_default = 0 WHERE is_default = 1 AND id <> ?",
      arguments: [id.uuidString])
    try db.execute(
      sql: "UPDATE payment_methods SET is_default = 1 WHERE id = ?", arguments: [id.uuidString])
  }

  /// Operations without an account, deleted ones included, go to `main`. When they were
  /// written is theirs: `updated_at` stays, since my last rating of a description is read by
  /// it.
  private static func assignUnassigned(to main: UUID, db: Database) throws {
    try db.execute(
      sql: "UPDATE transactions SET payment_method_id = ? WHERE payment_method_id IS NULL",
      arguments: [main.uuidString])
  }

  /// One reconciliation of kind `opening` at `instant`, with a balance for each count: the
  /// counted amount and, when it compares, the amount expected — the difference follows.
  /// Its ruble columns stay at zero: they are for a total, and this one counts accounts.
  private static func writeOpening(
    at instant: Date, calendar: CalendarContext,
    balances: [(key: BalanceKey, actual: AmountE4, expected: AmountE4?)], db: Database
  ) throws {
    let reconciliation = Reconciliation(
      date: calendar.day(of: instant), reconciledAt: instant, actualTotalRubE4: .zero,
      kind: .opening)
    try reconciliation.insert(db)
    for balance in balances {
      try ReconciledBalance(
        reconciliationId: reconciliation.id, accountId: balance.key.accountId,
        currency: balance.key.currency, actualE4: balance.actual, expectedE4: balance.expected,
        differenceE4: balance.expected.map { balance.actual - $0 }
      ).insert(db)
    }
  }
}
