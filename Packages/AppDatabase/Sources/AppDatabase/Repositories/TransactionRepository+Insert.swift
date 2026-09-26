import AppCore
import CoreKit
import Foundation
import GRDB

/// A history together with every row it points at, written in one transaction: the
/// synthetic sample of the Debug menu, the data sets and the benchmark with its
/// planning, later an import. Each list may be empty.
public struct HistoryBatch: Sendable {
  /// The groups the accounts among `paymentMethods` are filed under.
  public var accountGroups: [AccountGroup]
  public var categories: [CoreKit.Category]
  public var people: [Person]
  public var places: [Place]
  public var paymentMethods: [PaymentMethod]
  public var events: [Event]
  public var templates: [Template]
  public var goals: [Goal]
  public var debts: [Debt]
  public var entries: [TransactionEntry]
  /// The journals of the debts; a line may point at one of `entries`.
  public var debtEntries: [DebtEntry]
  /// The links of the reimbursements among `entries` to the parts they closed.
  public var links: [ReimbursementLink]
  /// Scheduled payments and subscriptions, with the price history of the subscriptions.
  public var scheduled: [ScheduledPayment]
  public var prices: [SubscriptionPrice]
  /// Expected income, and the links of income among `entries` to it.
  public var expected: [ExpectedIncome]
  public var expectedLinks: [ExpectedIncomeLink]
  /// Monthly limits.
  public var budgets: [Budget]
  /// Transfers between the accounts; a fee among `entries` points at one of them.
  public var transfers: [Transfer]
  /// Reconciliations, and the balances of the accounts they counted; a balance may point at
  /// the operation among `entries` that recorded its difference.
  public var reconciliations: [Reconciliation]
  public var reconciledBalances: [ReconciledBalance]
  /// Settings that point into the batch — the cashback category of Analytics — set in the
  /// same write, so a history never lands without them. Always written over.
  public var settings: [String: String]

  public init(
    categories: [CoreKit.Category] = [],
    people: [Person] = [],
    places: [Place] = [],
    paymentMethods: [PaymentMethod] = [],
    events: [Event] = [],
    templates: [Template] = [],
    goals: [Goal] = [],
    debts: [Debt] = [],
    entries: [TransactionEntry] = [],
    debtEntries: [DebtEntry] = [],
    links: [ReimbursementLink] = [],
    scheduled: [ScheduledPayment] = [],
    prices: [SubscriptionPrice] = [],
    expected: [ExpectedIncome] = [],
    expectedLinks: [ExpectedIncomeLink] = [],
    budgets: [Budget] = [],
    settings: [String: String] = [:],
    accountGroups: [AccountGroup] = [],
    transfers: [Transfer] = [],
    reconciliations: [Reconciliation] = [],
    reconciledBalances: [ReconciledBalance] = []
  ) {
    self.accountGroups = accountGroups
    self.transfers = transfers
    self.reconciliations = reconciliations
    self.reconciledBalances = reconciledBalances
    self.categories = categories
    self.people = people
    self.places = places
    self.paymentMethods = paymentMethods
    self.events = events
    self.templates = templates
    self.goals = goals
    self.debts = debts
    self.entries = entries
    self.debtEntries = debtEntries
    self.links = links
    self.scheduled = scheduled
    self.prices = prices
    self.expected = expected
    self.expectedLinks = expectedLinks
    self.budgets = budgets
    self.settings = settings
  }

  /// A generated sample whole: the history, every row it points at, the planning built on it
  /// (`SampleDataSet.planning`), its cashback category, and what its accounts add — groups,
  /// transfers, counts and their settings — when it has them (`withAccounts`).
  ///
  /// A history without its accounts is written the way accounts keep it
  /// (`SampleDataSet.assigningAccounts`): every operation on an account, and a charge wherever
  /// the account does not hold the operation's currency. Nothing that was drawn changes, so it
  /// is still the history the generator made.
  public init(sample: SampleDataSet) {
    let set = sample.assigningAccounts()
    let planning = set.planning
    var settings = set.settings
    settings[AnalyticsSettings.cashbackCategoryKey] = set.cashbackCategoryId.uuidString
    self.init(
      categories: set.categories, people: set.people, places: set.places,
      paymentMethods: set.paymentMethods, events: set.events, templates: set.templates,
      goals: set.goals, debts: set.debts, entries: set.entries, debtEntries: set.debtEntries,
      links: set.links, scheduled: planning.scheduled, prices: planning.prices,
      expected: planning.expected, expectedLinks: planning.expectedLinks,
      budgets: planning.budgets, settings: settings, accountGroups: set.accountGroups,
      transfers: set.transfers, reconciliations: set.reconciliations,
      reconciledBalances: set.reconciledBalances)
  }
}

/// Writing many operations at once. One write per call, so twenty thousand operations are
/// one commit instead of twenty thousand — and the database never holds half of them.
extension TransactionRepository {
  /// New operations in one write: all of them land, or none does.
  ///
  /// Every operation must add up before anything is written. An id that is already there,
  /// or a reference to a row that is not, fails the write and rolls all of it back. Each is
  /// held to the rules of a single save: without an account it gets the main one, and it is
  /// refused when it moves money on an account that does not hold its currency without saying
  /// what the account was charged (`AccountWriteError.chargeMissing`), or when it is a refund
  /// its purchase cannot give (`RefundError`).
  public func insert(_ entries: [TransactionEntry]) throws {
    try insert(HistoryBatch(entries: entries))
  }

  /// A whole history in one write, as new rows, all or nothing — the same rules as
  /// `insert(_:)` for its operations.
  public func insert(_ batch: HistoryBatch) throws {
    try write(batch, overExistingRows: false)
  }

  /// The same, written over any row with the same id, the way `save(_:)` writes one
  /// operation. The Debug menu generates from a fixed seed, so a second run meets its own
  /// rows; they are replaced, as they were when every row was a write of its own.
  ///
  /// An operation of the batch also takes its key (`external_id`, unique) over from another
  /// operation holding it, which goes (`takeKeyOver`): a history of another length, or one
  /// generated after the month has turned, has new operations paying the rent on the due
  /// dates an earlier one paid, and each date is paid once.
  public func save(_ batch: HistoryBatch) throws {
    try write(batch, overExistingRows: true)
  }

  /// Rows go in the order their foreign keys need: the groups of the accounts before the
  /// accounts, the reference books (parents before their subcategories, since the table
  /// refers to itself), debts after the people and categories they name, the planning after
  /// the categories, people and cards it names, operations after everything they point at,
  /// the journals and links after the operations they point at, then the transfers, the
  /// reconciliations and the balances they counted, and the settings last.
  ///
  /// A limit is unique to its target (`idx_budgets_target`). Written over existing rows, a
  /// limit whose target another limit already holds — one the owner set on bad spending,
  /// say — is left out, and the owner's stays; written as new rows, it fails the write.
  ///
  /// Every operation names its account, as every other write does: one without gets the live
  /// main account — the batch's own, written before the operations, or the database's — and one
  /// that moves money on an account that does not hold its currency must say what the account
  /// was charged. Each is asked as a new one, even over a row with its id: a history written
  /// again is written whole again. A refund is held to its purchase part as the rows are inside
  /// the write, so the purchases go before their refunds, as they do in time.
  private func write(_ batch: HistoryBatch, overExistingRows: Bool) throws {
    guard batch.entries.allSatisfy(\.isBalanced) else { throw DatabaseError.unbalancedParts }
    try writer.write { db in
      let lookups = WriteLookups()
      func put(_ record: some PersistableRecord) throws {
        if overExistingRows { try record.save(db) } else { try record.insert(db) }
      }
      for group in batch.accountGroups { try put(group) }
      for category in batch.categories where category.parentId == nil { try put(category) }
      for category in batch.categories where category.parentId != nil { try put(category) }
      for person in batch.people { try put(person) }
      for place in batch.places { try put(place) }
      for method in batch.paymentMethods { try put(method) }
      for event in batch.events { try put(event) }
      for template in batch.templates { try put(template) }
      for goal in batch.goals { try put(goal) }
      for debt in batch.debts { try put(debt) }
      for payment in batch.scheduled { try put(payment) }
      for price in batch.prices { try put(price) }
      for income in batch.expected { try put(income) }
      for budget in batch.budgets {
        if overExistingRows, try Self.isTargetTaken(of: budget, db: db) { continue }
        try put(budget)
      }
      for given in batch.entries {
        let entry = try Self.assigningAccount(given, lookups: lookups, db: db)
        try Self.refuseUnsoundRefund(entry, over: nil, db: db)
        if overExistingRows {
          try Self.takeKeyOver(for: entry.transaction, db: db)
          try entry.transaction.save(db)
          try Self.replaceParts(of: entry, db: db)
        } else {
          try entry.transaction.insert(db)
          for part in entry.parts { try part.insert(db) }
        }
      }
      for line in batch.debtEntries { try put(line) }
      for link in batch.links { try put(link) }
      for link in batch.expectedLinks { try put(link) }
      for transfer in batch.transfers { try put(transfer) }
      for reconciliation in batch.reconciliations { try put(reconciliation) }
      for balance in batch.reconciledBalances { try put(balance) }
      for (key, value) in batch.settings.sorted(by: { $0.key < $1.key }) {
        try SettingsRepository.set(key, to: value, in: db)
      }
    }
  }

  /// Removes any other operation holding the key of `transaction` — the index counts deleted
  /// rows too — with its debt lines, the way `purge(id:)` removes one; its parts and links
  /// go with it (`ON DELETE CASCADE`).
  private static func takeKeyOver(for transaction: CoreKit.Transaction, db: Database) throws {
    guard let key = transaction.externalId else { return }
    let holders = try String.fetchAll(
      db, sql: "SELECT id FROM transactions WHERE external_id = ? AND id <> ?",
      arguments: [key, transaction.id.uuidString])
    for holder in holders {
      try db.execute(sql: "DELETE FROM debt_entries WHERE transaction_id = ?", arguments: [holder])
      try db.execute(sql: "DELETE FROM transactions WHERE id = ?", arguments: [holder])
    }
  }

  /// Another limit holds the target of `budget`: the same scope, category and «for whom».
  private static func isTargetTaken(of budget: Budget, db: Database) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: """
        SELECT EXISTS (
          SELECT 1 FROM budgets
          WHERE scope = ? AND COALESCE(category_id, '') = ? AND COALESCE(for_whom, '') = ?
            AND id <> ?)
        """,
      arguments: [
        budget.scope.rawValue, budget.categoryId?.uuidString ?? "",
        budget.forWhom?.rawValue ?? "", budget.id.uuidString,
      ]) ?? false
  }
}
