import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// One step of ⌘Z of the planning is the exact inverse of the change it takes back: changes
/// drawn at random over a history with accounts — accounts and groups made, edited and deleted,
/// the main flag moved, transfers, reconciliations with their counts, limits, payments, events,
/// goals, journal lines, settings, operations created, rewritten and deleted, several at once —
/// are applied and taken back, and the database is what it was, value for value, rowid for
/// rowid (the settings, read by their key, by value; the parts of an operation in the order of
/// its split). A change the repository refuses leaves the database as it was too.
///
/// The one value allowed to differ is `updated_at` of the operations a change deleted and ⌘Z
/// brought back, and of those whose parts it reopened: bringing a row back is an update of it,
/// stamped at the moment of the undo.
@Suite("A planning change and its undo are exact inverses")
struct PlanningUndoPropertyTests {
  /// A stack with half a year of history and its accounts layer: groups, accounts in several
  /// currencies, transfers, counts, refunds, partial money back.
  static func stack() throws -> DatabaseStack {
    let stack = try TestSupport.makeStack()
    let set = TestSupport.sample(months: 4).withAccounts(
      seed: 20_260_918, calendar: TestSupport.sampleCalendar, language: "en")
    try TransactionRepository(writer: stack.writer).insert(HistoryBatch(sample: set))
    return stack
  }

  /// Every table value for value and rowid for rowid — but `settings`, a table read by its
  /// key, whose rows compare by their values alone, and the parts, whose order counts inside
  /// their operation: the order of its split.
  static func contents(_ stack: DatabaseStack) throws -> [String: ExactTable] {
    var tables = try stack.writer.read { db in try ExactTables.read(db) }
    tables["settings"] = tables["settings"]?.byValue
    tables["transaction_parts"] = tables["transaction_parts"]?.inOrderWithin("transaction_id")
    return tables
  }

  /// The contents with `updated_at` of these operations masked.
  static func masking(
    _ tables: [String: ExactTable], updatedAtOf ids: Set<String>
  ) -> [String: ExactTable] {
    guard var operations = tables["transactions"],
      let idIndex = operations.columns.firstIndex(of: "id"),
      let stampIndex = operations.columns.firstIndex(of: "updated_at")
    else { return tables }
    operations.rows = operations.rows.map { row in
      var row = row
      if ids.contains(row[idIndex + 1]) { row[stampIndex + 1] = "masked" }
      return row
    }
    var result = tables
    result["transactions"] = operations
    return result
  }

  /// `quote()` of the ids an undo may stamp: the deleted operations, their companions and the
  /// operations of the parts their deletion reopened.
  static func stamped(by undo: PlanningUndo, db: Database) throws -> Set<String> {
    var ids = Set(
      (undo.deletion.deletedIds + undo.deletion.companionIds).map {
        "'\($0.uuidString)'"
      })
    for part in undo.deletion.reopenedPartIds {
      if let operation = try String.fetchOne(
        db, sql: "SELECT transaction_id FROM transaction_parts WHERE id = ?",
        arguments: [part.uuidString])
      {
        ids.insert("'\(operation)'")
      }
    }
    return ids
  }

  /// `quote()` of the ids of the operations a write changed — their row, or a row of one of
  /// their parts —, found by comparing the tables before and after it: an independent bound on
  /// what an undo may stamp. An undo that reported more would widen the mask without a word.
  static func operationsChanged(
    from before: [String: ExactTable], to after: [String: ExactTable]
  ) -> Set<String> {
    func rows(_ table: ExactTable?, key: String) -> [String: [String]] {
      guard let table, let index = table.columns.firstIndex(of: key) else { return [:] }
      return Dictionary(
        table.rows.map { ($0[index + 1], $0) }, uniquingKeysWith: { first, _ in first })
    }
    var changed: Set<String> = []
    let operationsBefore = rows(before["transactions"], key: "id")
    let operationsAfter = rows(after["transactions"], key: "id")
    for id in Set(operationsBefore.keys).union(operationsAfter.keys)
    where operationsBefore[id] != operationsAfter[id] {
      changed.insert(id)
    }
    let partsBefore = rows(before["transaction_parts"], key: "id")
    let partsAfter = rows(after["transaction_parts"], key: "id")
    let owner = before["transaction_parts"]?.columns.firstIndex(of: "transaction_id")
    for id in Set(partsBefore.keys).union(partsAfter.keys) where partsBefore[id] != partsAfter[id] {
      if let owner, let row = partsBefore[id] ?? partsAfter[id] { changed.insert(row[owner + 1]) }
    }
    return changed
  }

  /// Names the tables that differ and the first row that does, for a readable failure.
  static func difference(
    _ left: [String: ExactTable], _ right: [String: ExactTable]
  ) -> String {
    var lines: [String] = []
    for table in Set(left.keys).union(right.keys).sorted() where left[table] != right[table] {
      let old = left[table]?.rows ?? []
      let new = right[table]?.rows ?? []
      let first = zip(old, new).first { $0 != $1 }
      lines.append(
        "\(table): \(old.count) → \(new.count) rows; first difference: "
          + "\(first.map { "\($0.0) → \($0.1)" } ?? "in the count")")
    }
    return lines.joined(separator: "\n")
  }

  /// Seeds of single changes, each of one to five random actions.
  @Test(arguments: Array(UInt64(1)...UInt64(200)))
  func aChangeAndItsUndoLeaveTheDatabaseAsItWas(seed: UInt64) throws {
    let stack = try Self.stack()
    var drawer = ChangeDrawer(seed: seed)
    let before = try Self.contents(stack)
    let change = try drawer.change(in: stack, actions: 1...5)
    let planning = PlanningRepository(writer: stack.writer)

    let rawBefore = try stack.writer.read { db in try ExactTables.read(db) }
    let undo: PlanningUndo
    do {
      undo = try planning.apply(change)
    } catch {
      #expect(try Self.contents(stack) == before, "seed \(seed): a refused change wrote something")
      return
    }
    let stamped = try stack.writer.read { db in try Self.stamped(by: undo, db: db) }
    let changed = Self.operationsChanged(
      from: rawBefore, to: try stack.writer.read { db in try ExactTables.read(db) })
    #expect(
      stamped.isSubset(of: changed),
      "seed \(seed): the undo stamps operations the change never touched: \(stamped.subtracting(changed))"
    )
    try planning.revert(undo, at: Date(timeIntervalSince1970: 1_790_000_000))
    let after = try Self.contents(stack)
    let expected = Self.masking(before, updatedAtOf: stamped)
    let got = Self.masking(after, updatedAtOf: stamped)
    #expect(got == expected, "seed \(seed): \(drawer.log)\n\(Self.difference(expected, got))")
  }

  /// Several changes in a row, taken back one by one from the last, as ⌘Z does: the database
  /// is what it was before the first.
  @Test(arguments: Array(UInt64(1001)...UInt64(1060)))
  func aRowOfChangesUndoneFromTheLastLeavesTheDatabaseAsItWas(seed: UInt64) throws {
    let stack = try Self.stack()
    var drawer = ChangeDrawer(seed: seed)
    let before = try Self.contents(stack)
    let planning = PlanningRepository(writer: stack.writer)
    var undos: [PlanningUndo] = []
    var stamped: Set<String> = []
    for _ in 0..<6 {
      let change = try drawer.change(in: stack, actions: 1...3)
      let rawBefore = try stack.writer.read { db in try ExactTables.read(db) }
      guard let undo = try? planning.apply(change) else { continue }
      let these = try stack.writer.read { db in try Self.stamped(by: undo, db: db) }
      let changed = Self.operationsChanged(
        from: rawBefore, to: try stack.writer.read { db in try ExactTables.read(db) })
      #expect(these.isSubset(of: changed), "seed \(seed): \(these.subtracting(changed))")
      stamped.formUnion(these)
      undos.append(undo)
    }
    for undo in undos.reversed() {
      try planning.revert(undo, at: Date(timeIntervalSince1970: 1_790_000_000))
    }
    let expected = Self.masking(before, updatedAtOf: stamped)
    let got = Self.masking(try Self.contents(stack), updatedAtOf: stamped)
    #expect(
      got == expected,
      "seed \(seed), \(undos.count) changes: \(drawer.log)\n\(Self.difference(expected, got))")
  }

  /// A history whose unused categories have everything a category deletion reaches: a limit,
  /// a goal, a debt, a payment and an expected income filed under it, and — outside the planning
  /// — a template, a mapping of the import and a choice the owner made against the model.
  static func stackWithDependents() throws -> DatabaseStack {
    let stack = try stack()
    try stack.writer.write { db in
      let parent = try #require(
        try CoreKit.Category.filter(
          sql: "kind = 'expense' AND parent_id IS NULL AND system_role IS NULL"
        )
        .fetchOne(db))
      for index in 0..<4 {
        let category = CoreKit.Category(
          parentId: parent.id, kind: .expense, name: "Unused \(index)")
        try category.insert(db)
        try Budget(scope: .category, categoryId: category.id, amountE4: AmountE4(whole: 1_000))
          .insert(db)
        try Goal(name: "Filed \(index)", targetE4: AmountE4(whole: 10), subcategoryId: category.id)
          .insert(db)
        try Debt(
          direction: .iOwe, type: .loan, name: "Filed \(index)", loansSubcategoryId: category.id
        )
        .insert(db)
        try ScheduledPayment(
          name: "Filed \(index)", amountE4: AmountE4(whole: 5), categoryId: category.id
        )
        .insert(db)
        let id = category.id.uuidString
        try db.execute(
          sql: """
            INSERT INTO templates (id, text, category_id, pinned, use_count) VALUES (?, ?, ?, 0, 1);
            INSERT INTO import_mappings (id, source_kind, source_category, target_category_id,
              subcategory_is_place) VALUES (?, 'expense', ?, ?, 0);
            INSERT INTO category_feedback (id, text, predicted_category_id, chosen_category_id, at)
              VALUES (?, ?, ?, ?, '2026-09-01 10:00:00.000');
            """,
          arguments: [
            UUID().uuidString, "template \(index)", id, UUID().uuidString, "source \(index)", id,
            UUID().uuidString, "text \(index)", id, id,
          ])
      }
    }
    return stack
  }

  /// The actions on the books of the planning — categories edited and deleted with all they
  /// reach, goals and debts made and deleted with their journals, subscriptions with their
  /// prices, expected income with its links, reconciliations edited with their counts — alone
  /// and in rows, applied and taken back: the database is what it was.
  @Test(arguments: Array(UInt64(2001)...UInt64(2080)))
  func aChangeOfTheBooksAndItsUndoLeaveTheDatabaseAsItWas(seed: UInt64) throws {
    let stack = try Self.stackWithDependents()
    var drawer = ChangeDrawer(seed: seed, kinds: 22...30)
    let before = try Self.contents(stack)
    let planning = PlanningRepository(writer: stack.writer)
    var undos: [PlanningUndo] = []
    for _ in 0..<3 {
      let change = try drawer.change(in: stack, actions: 1...4)
      let written = try Self.contents(stack)
      do {
        undos.append(try planning.apply(change))
      } catch {
        #expect(
          try Self.contents(stack) == written, "seed \(seed): a refused change wrote something")
      }
    }
    for undo in undos.reversed() {
      try planning.revert(undo, at: Date(timeIntervalSince1970: 1_790_000_000))
    }
    let after = try Self.contents(stack)
    #expect(after == before, "seed \(seed): \(drawer.log)\n\(Self.difference(before, after))")
  }

  /// The actions on the books land often enough, and among them the deletions of categories
  /// that reach the rows outside the planning.
  @Test func mostChangesOfTheBooksAreWritten() throws {
    var written = 0
    var categoriesDeleted = 0
    let seeds = UInt64(2101)...UInt64(2140)
    for seed in seeds {
      let stack = try Self.stackWithDependents()
      var drawer = ChangeDrawer(seed: seed, kinds: 22...30)
      let change = try drawer.change(in: stack, actions: 1...3)
      if let undo = try? PlanningRepository(writer: stack.writer).apply(change) {
        written += 1
        if !undo.cleared.isEmpty { categoriesDeleted += 1 }
      }
    }
    #expect(written * 3 >= seeds.count * 2, "only \(written) of \(seeds.count) were written")
    #expect(categoriesDeleted >= 3, "only \(categoriesDeleted) deletions reached a template")
  }

  /// Enough of the drawn changes land for the property to say something: most of them are
  /// written, not refused.
  @Test func mostDrawnChangesAreWritten() throws {
    var written = 0
    let seeds = UInt64(501)...UInt64(530)
    for seed in seeds {
      let stack = try Self.stack()
      var drawer = ChangeDrawer(seed: seed)
      let change = try drawer.change(in: stack, actions: 1...3)
      if (try? PlanningRepository(writer: stack.writer).apply(change)) != nil { written += 1 }
    }
    #expect(written * 3 >= seeds.count * 2, "only \(written) of \(seeds.count) were written")
  }
}

/// Draws a `PlanningChange` of random actions over what the database holds now.
struct ChangeDrawer {
  var random: SeededRandom
  /// What was drawn, for the message of a failure.
  private(set) var log: [String] = []

  /// The kinds of action drawn from: every one by default.
  private let kinds: ClosedRange<Int>

  init(seed: UInt64, kinds: ClosedRange<Int> = 0...30) {
    var mixer = SeededRandom(seed: seed)
    random = SeededRandom(seed: mixer.next())
    self.kinds = kinds
  }

  private mutating func pick<T>(_ values: [T]) -> T? {
    values.isEmpty ? nil : values[random.int(in: 0..<values.count)]
  }

  private mutating func chance(_ numerator: Int, _ denominator: Int) -> Bool {
    random.chance(numerator, outOf: denominator)
  }

  private mutating func amount() -> AmountE4 {
    AmountE4(raw: Int64(random.int(in: 1...90_000)) * 10_000)
  }

  private mutating func moment() -> Date {
    Date(timeIntervalSince1970: 1_780_000_000 + Double(random.int(in: 0...9_000_000)))
  }

  /// The state the draw reads.
  private struct State {
    var groups: [AccountGroup]
    var accounts: [PaymentMethod]
    var transfers: [Transfer]
    var reconciliations: [Reconciliation]
    var budgets: [Budget]
    var scheduled: [ScheduledPayment]
    var events: [Event]
    var goals: [Goal]
    var debts: [Debt]
    var lines: [DebtEntry]
    var categories: [CoreKit.Category]
    var live: [TransactionEntry]
    var settings: [String]
    /// Categories a part points at, in the bin too, or that have subcategories: the schema
    /// refuses to delete them.
    var heldCategories: Set<UUID>
    /// Goals and debts operations point at: the planning refuses to delete them.
    var heldGoals: Set<UUID>
    var heldDebts: Set<UUID>
    var expected: [ExpectedIncome]
    var balances: [ReconciledBalance]
    /// Categories another row is filed under — a limit, a goal, a debt, a payment, an expected
    /// income, a template, a mapping, a choice of the model: what a deletion reaches.
    var filedCategories: Set<UUID>
  }

  private func state(_ stack: DatabaseStack) throws -> State {
    try stack.writer.read { db in
      State(
        groups: try AccountGroup.order(Column.rowID).fetchAll(db),
        accounts: try PaymentMethod.order(Column.rowID).fetchAll(db),
        transfers: try Transfer.order(Column.rowID).fetchAll(db),
        reconciliations: try Reconciliation.order(Column.rowID).fetchAll(db),
        budgets: try Budget.order(Column.rowID).fetchAll(db),
        scheduled: try ScheduledPayment.order(Column.rowID).fetchAll(db),
        events: try Event.order(Column.rowID).fetchAll(db),
        goals: try Goal.order(Column.rowID).fetchAll(db),
        debts: try Debt.order(Column.rowID).fetchAll(db),
        lines: try DebtEntry.order(Column.rowID).fetchAll(db),
        categories: try CoreKit.Category.order(Column.rowID).fetchAll(db),
        live: try TransactionRepository.entries(
          where: "deleted_at IS NULL", arguments: [], order: "rowid", db: db),
        settings: try String.fetchAll(db, sql: "SELECT key FROM settings ORDER BY key"),
        heldCategories: Set(
          try String.fetchAll(
            db,
            sql: """
              SELECT category_id FROM transaction_parts WHERE category_id IS NOT NULL
              UNION SELECT parent_id FROM categories WHERE parent_id IS NOT NULL
              """
          ).compactMap(UUID.init(uuidString:))),
        heldGoals: Set(
          try String.fetchAll(
            db, sql: "SELECT goal_id FROM transaction_parts WHERE goal_id IS NOT NULL"
          ).compactMap(UUID.init(uuidString:))),
        heldDebts: Set(
          try String.fetchAll(
            db,
            sql: """
              SELECT debt_id FROM transactions WHERE debt_id IS NOT NULL
              UNION SELECT credit_debt_id FROM transactions WHERE credit_debt_id IS NOT NULL
              """
          ).compactMap(UUID.init(uuidString:))),
        expected: try ExpectedIncome.order(Column.rowID).fetchAll(db),
        balances: try ReconciledBalance.order(Column.rowID).fetchAll(db),
        filedCategories: Set(
          try String?.fetchAll(
            db,
            sql: """
              SELECT category_id FROM budgets UNION SELECT subcategory_id FROM goals
              UNION SELECT loans_subcategory_id FROM debts
              UNION SELECT category_id FROM scheduled_payments
              UNION SELECT category_id FROM expected_income UNION SELECT category_id FROM templates
              UNION SELECT target_category_id FROM import_mappings
              UNION SELECT chosen_category_id FROM category_feedback
              UNION SELECT predicted_category_id FROM category_feedback
              """
          ).compactMap { $0.flatMap(UUID.init(uuidString:)) }))
    }
  }

  mutating func change(
    in stack: DatabaseStack, actions: ClosedRange<Int>
  ) throws -> PlanningChange {
    let state = try state(stack)
    var change = PlanningChange(at: Date(timeIntervalSince1970: 1_789_500_000))
    var touched: Set<UUID> = []
    for _ in 0..<random.int(in: actions) {
      draw(into: &change, state: state, touched: &touched)
    }
    return change
  }

  private mutating func draw(
    into change: inout PlanningChange, state: State, touched: inout Set<UUID>
  ) {
    let live = state.accounts.filter { !$0.archived }
    let expenses = state.categories.filter { $0.kind == .expense && $0.parentId != nil }
    switch random.int(in: kinds) {
    case 0:
      let group = AccountGroup(
        name: "Group \(random.int(in: 1...999))", inSummary: chance(1, 2),
        sort: random.int(in: 0...5))
      change.upsert.accountGroups.append(group)
      log.append("new group")
    case 1:
      guard var group = pick(state.groups), touched.insert(group.id).inserted else { return }
      group.inSummary.toggle()
      group.sort = random.int(in: 0...9)
      change.upsert.accountGroups.append(group)
      log.append("edit group")
    case 2:
      guard let group = pick(state.groups), touched.insert(group.id).inserted else { return }
      change.delete.accountGroups.append(group.id)
      log.append("delete group")
    case 3:
      let currencies: [CurrencyCode] = [.rub, .usd, CurrencyCode("KZT"), .eur]
      let main = pick(currencies) ?? .rub
      let account = PaymentMethod(
        name: "Account \(random.int(in: 1...999))",
        kind: pick([.card, .cash, .account, .other]) ?? .card, currency: main,
        isDefault: chance(1, 4), groupId: chance(1, 2) ? pick(state.groups)?.id : nil,
        sort: random.int(in: 0...5),
        otherCurrencies: currencies.filter { $0 != main && chance(1, 3) })
      change.upsert.paymentMethods.append(account)
      log.append("new account\(account.isDefault ? " as main" : "")")
    case 4:
      guard var account = pick(state.accounts), touched.insert(account.id).inserted else {
        return
      }
      switch random.int(in: 0...3) {
      case 0: account.name += " (renamed)"
      case 1: account.sort = random.int(in: 1...20)
      case 2: account.isDefault = true
      default: account.groupId = pick(state.groups)?.id
      }
      change.upsert.paymentMethods.append(account)
      log.append("edit account")
    case 5:
      guard let account = pick(state.accounts), touched.insert(account.id).inserted else {
        return
      }
      change.delete.paymentMethods.append(account.id)
      log.append("delete account")
    case 6, 7:
      guard let from = pick(live), let to = pick(live) else { return }
      let fromCurrency = pick(from.currencies) ?? .rub
      let toCurrency = pick(to.currencies) ?? .rub
      guard from.id != to.id || fromCurrency != toCurrency else { return }
      let sent = amount()
      let transfer = Transfer(
        occurredAt: moment(), fromAccountId: from.id, fromCurrency: fromCurrency,
        fromAmountE4: sent, toAccountId: to.id, toCurrency: toCurrency,
        toAmountE4: fromCurrency == toCurrency ? sent : amount(),
        note: chance(1, 2) ? "moved" : nil, createdAt: moment(), updatedAt: moment())
      change.upsert.transfers.append(transfer)
      log.append("new transfer")
      if chance(1, 3), let category = pick(expenses) {
        // Its fee: an expense on the account it was sent from, keyed to the transfer.
        let id = UUID()
        let fee = AmountE4(whole: Int64(random.int(in: 1...300)))
        change.created.append(
          TransactionEntry(
            transaction: Transaction(
              id: id, kind: .expense, occurredAt: transfer.occurredAt, currency: fromCurrency,
              amountE4: fee, rate: fromCurrency == .rub ? nil : 90,
              rateSource: fromCurrency == .rub ? nil : .manual,
              amountRubE4: fromCurrency == .rub ? fee : AmountE4(raw: fee.raw * 90),
              note: "fee", paymentMethodId: from.id,
              externalId: OperationLink.transferFee(transfer.id).externalId,
              createdAt: transfer.occurredAt, updatedAt: transfer.occurredAt),
            parts: [
              TransactionPart(
                transactionId: id, categoryId: category.id, amountE4: fee,
                amountRubE4: fromCurrency == .rub ? fee : AmountE4(raw: fee.raw * 90))
            ]))
        log.append("with a fee")
      }
    case 8:
      guard var transfer = pick(state.transfers), touched.insert(transfer.id).inserted else {
        return
      }
      transfer.note = "edited"
      transfer.occurredAt = moment()
      if transfer.isExchange { transfer.toAmountE4 = amount() }
      change.upsert.transfers.append(transfer)
      log.append("edit transfer")
    case 9:
      guard let transfer = pick(state.transfers), touched.insert(transfer.id).inserted else {
        return
      }
      change.delete.transfers.append(transfer.id)
      log.append("delete transfer")
    case 10:
      let at = moment()
      let reconciliation = Reconciliation(
        date: DateOnly(year: 2026, month: 8, day: random.int(in: 1...28)), reconciledAt: at,
        actualTotalRubE4: amount(), kind: .accounts)
      change.upsert.reconciliations.append(reconciliation)
      var keys: Set<BalanceKey> = []
      for _ in 0..<random.int(in: 1...3) {
        guard let account = pick(live), let currency = pick(account.currencies) else { continue }
        let key = BalanceKey(accountId: account.id, currency: currency)
        guard keys.insert(key).inserted else { continue }
        change.upsert.reconciledBalances.append(
          ReconciledBalance(
            reconciliationId: reconciliation.id, accountId: account.id, currency: currency,
            actualE4: amount()))
      }
      log.append("new reconciliation")
    case 11:
      guard let reconciliation = pick(state.reconciliations),
        touched.insert(reconciliation.id).inserted
      else { return }
      change.delete.reconciliations.append(reconciliation.id)
      log.append("delete reconciliation")
    case 12:
      guard var budget = pick(state.budgets), touched.insert(budget.id).inserted else { return }
      budget.amountE4 = amount()
      budget.rollover.toggle()
      change.upsert.budgets.append(budget)
      log.append("edit limit")
    case 13:
      guard let budget = pick(state.budgets), touched.insert(budget.id).inserted else { return }
      change.delete.budgets.append(budget.id)
      log.append("delete limit")
    case 14:
      guard var payment = pick(state.scheduled), touched.insert(payment.id).inserted else {
        return
      }
      payment.amountE4 = amount()
      payment.name += " (edited)"
      change.upsert.scheduled.append(payment)
      log.append("edit payment")
    case 15:
      guard let payment = pick(state.scheduled), touched.insert(payment.id).inserted else {
        return
      }
      change.delete.scheduled.append(payment.id)
      log.append("delete payment")
    case 16:
      if chance(1, 2), let event = pick(state.events), touched.insert(event.id).inserted {
        change.delete.events.append(event.id)
        log.append("delete event")
      } else {
        let day = DateOnly(year: 2026, month: 10, day: random.int(in: 1...28))
        change.upsert.events.append(
          Event(
            name: "Event \(random.int(in: 1...99))", kind: .other, startDate: day, endDate: day,
            budgetE4: chance(1, 2) ? amount() : nil))
        log.append("new event")
      }
    case 17:
      guard var goal = pick(state.goals), touched.insert(goal.id).inserted else { return }
      goal.monthlyPlanE4 = amount()
      goal.archived.toggle()
      change.upsert.goals.append(goal)
      log.append("edit goal")
    case 18:
      if chance(1, 2), let line = pick(state.lines), touched.insert(line.id).inserted {
        change.delete.debtEntries.append(line.id)
        log.append("delete journal line")
      } else if let debt = pick(state.debts) {
        change.upsert.debtEntries.append(
          DebtEntry(
            debtId: debt.id, date: DateOnly(year: 2026, month: 9, day: random.int(in: 1...28)),
            amountE4: chance(1, 2) ? amount() : -amount(), kind: .adjustment,
            note: "drawn"))
        log.append("new journal line")
      }
    case 19:
      if chance(1, 2), let key = pick(state.settings) {
        change.settings.updateValue(nil, forKey: key)
        log.append("delete setting \(key)")
      } else {
        change.settings.updateValue(
          String(random.int(in: 1...60)), forKey: PlanningSettings.reconcileEveryDaysKey)
        log.append("set setting")
      }
    case 20:
      guard let account = pick(live), let category = pick(expenses) else { return }
      let id = UUID()
      let amount = amount()
      let at = moment()
      change.created.append(
        TransactionEntry(
          transaction: Transaction(
            id: id, kind: .expense, occurredAt: at, currency: account.mainCurrency,
            amountE4: amount, rate: account.mainCurrency == .rub ? nil : 90,
            rateSource: account.mainCurrency == .rub ? nil : .manual,
            amountRubE4: account.mainCurrency == .rub ? amount : AmountE4(raw: amount.raw * 90),
            note: "drawn", paymentMethodId: account.id, createdAt: at, updatedAt: at),
          parts: [
            TransactionPart(
              transactionId: id, categoryId: category.id, amountE4: amount,
              amountRubE4: account.mainCurrency == .rub ? amount : AmountE4(raw: amount.raw * 90))
          ]))
      log.append("new operation")
    case 22:
      // A category renamed, its quality or its archive changed.
      guard var category = pick(state.categories), touched.insert(category.id).inserted else {
        return
      }
      category.name += " (renamed)"
      if category.parentId == nil, category.kind == .expense {
        category.quality = pick([.good, .neutral, .bad])
      } else {
        category.archived.toggle()
      }
      change.upsert.categories.append(category)
      log.append("edit category")
    case 23:
      // A category nothing holds: its limits go with it, the planning rows filed under it
      // and the templates, mappings and choices of the model lose the link.
      let free = state.categories.filter { !state.heldCategories.contains($0.id) }
      let filed = free.filter { state.filedCategories.contains($0.id) }
      let candidates = chance(1, 2) && !filed.isEmpty ? filed : free
      guard let category = pick(candidates), touched.insert(category.id).inserted else { return }
      change.delete.categories.append(category.id)
      log.append("delete category")
    case 24:
      // A goal with the subcategory it owns under the system goals category.
      guard let parent = state.categories.first(where: { $0.systemRole == .goals }) else { return }
      let subcategory = CoreKit.Category(
        parentId: parent.id, kind: .expense, name: "Goal \(random.int(in: 1...999))")
      change.upsert.categories.append(subcategory)
      change.upsert.goals.append(
        Goal(
          name: subcategory.name, targetE4: amount(), monthlyPlanE4: chance(1, 2) ? amount() : nil,
          subcategoryId: subcategory.id, currency: pick([.rub, .usd]) ?? .rub))
      log.append("new goal")
    case 25:
      let free = state.goals.filter { !state.heldGoals.contains($0.id) }
      guard let goal = pick(free), touched.insert(goal.id).inserted else { return }
      change.delete.goals.append(goal.id)
      log.append("delete goal")
    case 26:
      // A debt with its journal.
      let debt = Debt(
        direction: pick([.iOwe, .owedToMe]) ?? .iOwe, type: pick([.loan, .personal]) ?? .loan,
        name: "Debt \(random.int(in: 1...999))", monthlyPaymentE4: chance(1, 2) ? amount() : nil)
      change.upsert.debts.append(debt)
      for day in 1...random.int(in: 1...3) {
        change.upsert.debtEntries.append(
          DebtEntry(
            debtId: debt.id, date: DateOnly(year: 2026, month: 9, day: day), amountE4: amount(),
            kind: .adjustment, note: "opened"))
      }
      log.append("new debt")
    case 27:
      // A debt no operation points at, its journal going with it.
      let free = state.debts.filter { !state.heldDebts.contains($0.id) }
      guard let debt = pick(free), touched.insert(debt.id).inserted else { return }
      change.delete.debts.append(debt.id)
      log.append("delete debt")
    case 28:
      // A subscription with the history of its price.
      let payment = ScheduledPayment(
        name: "Subscription \(random.int(in: 1...999))", kind: .subscription, amountE4: amount(),
        categoryId: pick(expenses)?.id, paymentMethodId: chance(1, 2) ? pick(live)?.id : nil,
        nextDate: DateOnly(year: 2026, month: 10, day: random.int(in: 1...28)))
      change.upsert.scheduled.append(payment)
      for month in 1...random.int(in: 1...3) {
        change.upsert.prices.append(
          SubscriptionPrice(
            paymentId: payment.id, date: DateOnly(year: 2026, month: month, day: 1),
            amountE4: amount()))
      }
      log.append("new subscription with prices")
    case 29:
      // Expected income: made with links to income received, edited, or deleted with its links.
      let incomes = state.live.filter { $0.transaction.kind == .income }
      if chance(1, 3), let income = pick(state.expected), touched.insert(income.id).inserted {
        change.delete.expected.append(income.id)
        log.append("delete expected income")
      } else if chance(1, 2), var income = pick(state.expected), touched.insert(income.id).inserted
      {
        income.totalE4 = amount()
        income.name += " (edited)"
        change.upsert.expected.append(income)
        if let received = pick(incomes) {
          change.upsert.expectedLinks.append(
            ExpectedIncomeLink(expectedIncomeId: income.id, transactionId: received.id))
        }
        log.append("edit expected income")
      } else {
        let income = ExpectedIncome(
          name: "Expected \(random.int(in: 1...999))", kind: .oneOff, totalE4: amount(),
          dueDate: DateOnly(year: 2026, month: 10, day: random.int(in: 1...28)))
        change.upsert.expected.append(income)
        for _ in 0..<random.int(in: 0...2) {
          guard let received = pick(incomes) else { break }
          change.upsert.expectedLinks.append(
            ExpectedIncomeLink(expectedIncomeId: income.id, transactionId: received.id))
        }
        log.append("new expected income")
      }
    case 30:
      // A reconciliation edited, and the starting points it counted with it.
      guard var reconciliation = pick(state.reconciliations),
        touched.insert(reconciliation.id).inserted
      else { return }
      reconciliation.actualTotalRubE4 = amount()
      change.upsert.reconciliations.append(reconciliation)
      for var balance in state.balances
      where balance.reconciliationId == reconciliation.id && balance.expectedE4 == nil {
        balance.actualE4 = chance(1, 2) ? amount() : -amount()
        change.upsert.reconciledBalances.append(balance)
      }
      log.append("edit reconciliation")
    default:
      let splits = state.live.filter { $0.parts.count > 1 }
      // Operations with ties to others: paid due dates, fees, money back and what it wrote,
      // differences of a count — the ones whose deletion takes something along.
      let tied = state.live.filter {
        $0.transaction.externalId != nil || $0.transaction.kind == .reimbursement
      }
      let candidates: [TransactionEntry]
      switch random.int(in: 0...2) {
      case 0 where !splits.isEmpty: candidates = splits
      case 1 where !tied.isEmpty: candidates = tied
      default: candidates = state.live
      }
      guard var entry = pick(candidates), touched.insert(entry.id).inserted else { return }
      if chance(1, 3) {
        change.softDeleted.append(entry.id)
        log.append("delete operation \(entry.transaction.kind.rawValue)")
      } else {
        entry.transaction.note = "rewritten"
        if entry.parts.count > 1, chance(1, 2) {
          // The first part goes; its money moves to the next one.
          let dropped = entry.parts.removeFirst()
          entry.parts[0].amountE4 += dropped.amountE4
          entry.parts[0].amountRubE4 += dropped.amountRubE4
          log.append("rewrite operation dropping a part")
        } else {
          log.append("rewrite operation")
        }
        change.rewritten.append(entry)
      }
    }
  }
}
