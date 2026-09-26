import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

@Suite("Many operations at once: one write, one undo")
struct BatchTests {
  private let instant = Date(timeIntervalSince1970: 1_790_000_000)

  private func makeRepository() throws -> (DatabaseStack, TransactionRepository) {
    let stack = try TestSupport.makeStack()
    return (stack, TransactionRepository(writer: stack.writer))
  }

  /// Thousands of operations in one write, the way an import would land them.
  private func insert(_ count: Int, into stack: DatabaseStack) throws -> [UUID] {
    let entries = try (0..<count).map { number in
      try TestSupport.makeEntry(amount: 1_000_000, note: "row \(number)")
    }
    try stack.writer.write { db in
      for entry in entries {
        try entry.transaction.insert(db)
        for part in entry.parts { try part.insert(db) }
      }
    }
    return entries.map(\.id)
  }

  private func renamed(_ entry: TransactionEntry, _ note: String) -> TransactionEntry {
    var changed = entry
    changed.transaction.note = note
    return changed
  }

  // MARK: modify

  @Test func aChangeReturnsTheOperationsAsTheyWereBefore() throws {
    let (_, repository) = try makeRepository()
    let first = try TestSupport.makeEntry(note: "coffee")
    let second = try TestSupport.makeEntry(note: "tea")
    let untouched = try TestSupport.makeEntry(note: "water")
    for entry in [first, second, untouched] { try repository.save(entry) }
    // SQLite keeps dates to the millisecond, so the stored row is the one to compare with.
    let stored = try #require(try repository.entry(id: first.id))

    let before = try repository.modify(ids: [first.id, second.id, first.id], at: instant) {
      self.renamed($0, "changed")
    }

    #expect(Set(before.map(\.transaction.note)) == ["coffee", "tea"])
    let after = try repository.entries(ids: [first.id, second.id, untouched.id])
    let byId = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
    #expect(byId[first.id]?.transaction.note == "changed")
    #expect(byId[first.id]?.transaction.updatedAt == instant)
    #expect(byId[first.id]?.transaction.createdAt == stored.transaction.createdAt)
    #expect(byId[untouched.id]?.transaction.note == "water")
  }

  /// All or nothing: one operation that no longer adds up stops the whole change, even when
  /// it sits in the third chunk of ids.
  @Test func aChangeThatFailsAnywhereLeavesEverythingAsItWas() throws {
    let (stack, repository) = try makeRepository()
    let ids = try insert(1_200, into: stack)
    let broken = ids[1_100]

    #expect(throws: DatabaseError.unbalancedParts) {
      try repository.modify(ids: ids, at: instant) { entry in
        var changed = self.renamed(entry, "changed")
        if entry.id == broken { changed.parts[0].amountE4 = AmountE4(raw: 1) }
        return changed
      }
    }
    let notes = try repository.entries(ids: ids).map(\.transaction.note)
    #expect(!notes.contains("changed"))
  }

  /// The list the change was chosen from can lag behind the database. A part written off
  /// after the list was read stays written off when the category of its operation changes.
  @Test func aPartWrittenOffAfterTheListWasReadStaysWrittenOff() throws {
    let (stack, repository) = try makeRepository()
    let references = ReferenceRepository(writer: stack.writer)
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    let fuel = CoreKit.Category(kind: .expense, name: "Fuel", quality: .neutral)
    try references.save(groceries)
    try references.save(fuel)
    var dinner = TransactionDraft(amount: AmountE4(whole: 1_000), note: "dinner")
    dinner.parts = [
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 400)),
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 600), reimbursable: true),
    ]
    let saved = try dinner.materialize()
    try repository.save(saved)
    let listed = try repository.entries(ids: [saved.id])

    try repository.writeOffPart(id: saved.parts[1].id)
    let tree = CategoryTree([groceries, fuel])
    let before = try repository.modify(ids: listed.map(\.id), at: instant) { fresh in
      BulkEditRule.apply(.category(fuel.id), to: fresh, tree: tree).changedEntry
    }

    let stored = try #require(try repository.entry(id: saved.id))
    #expect(stored.parts.map(\.categoryId) == [fuel.id, fuel.id])
    #expect(stored.parts[1].reimbursementStatus == .writtenOff)
    // The snapshot for undo is the row as it was inside the write, not the stale copy.
    #expect(before.first?.parts[1].reimbursementStatus == .writtenOff)
  }

  // MARK: 40 000 ids

  /// Far past the limit on bound parameters: every method sends ids in chunks.
  @Test func fortyThousandOperationsAreChangedDeletedAndRestored() throws {
    let (stack, repository) = try makeRepository()
    let ids = try insert(40_000, into: stack)

    #expect(try repository.entries(ids: ids).count == 40_000)
    let before = try repository.modify(ids: ids, at: instant) { self.renamed($0, "changed") }
    #expect(before.count == 40_000)

    let effects = try repository.softDelete(ids: ids, at: instant)
    #expect(effects.deletedIds.count == 40_000)
    #expect(try repository.count() == 0)

    try repository.restore(ids: effects.deletedIds, at: instant, effects: effects)
    #expect(try repository.count() == 40_000)
  }

  // MARK: Off the calling thread

  /// The twins that await do the work of the synchronous calls: a change hands back both
  /// sides of every operation it rewrote, and deleting and restoring land the same way.
  @Test func theBackgroundTwinsChangeDeleteAndRestoreLikeTheOthers() async throws {
    let (stack, repository) = try makeRepository()
    let ids = try insert(1_200, into: stack)

    let modified = try await repository.modifyInBackground(
      ids: ids + [ids[0]], at: instant
    ) { entry in
      var changed = entry
      changed.transaction.note = "changed"
      return changed
    }

    #expect(modified.count == 1_200)
    #expect(modified.allSatisfy { $0.before.transaction.note?.hasPrefix("row ") == true })
    #expect(modified.allSatisfy { $0.after.transaction.note == "changed" })
    #expect(modified.allSatisfy { $0.after.transaction.updatedAt == instant })
    let read = try await repository.entriesInBackground(ids: ids)
    #expect(read.count == 1_200)
    #expect(read.allSatisfy { $0.transaction.note == "changed" })

    let effects = try await repository.softDeleteInBackground(ids: ids, at: instant)
    #expect(effects.deletedIds.count == 1_200)
    #expect(try repository.count() == 0)

    try await repository.restoreInBackground(
      ids: effects.deletedIds, at: instant, effects: effects)
    #expect(try repository.count() == 1_200)
  }

  /// A deletion off the calling thread chooses what goes inside its own write, from the
  /// rows as the database holds them then: the caller's rule sees a change made after the
  /// list was read, and what the rule leaves out stays. Reading and deleting in one write
  /// also queues the whole deletion at once, so nothing lands between the choice and it.
  @Test func aBackgroundDeletionChoosesWhatGoesInsideItsWrite() async throws {
    let (stack, repository) = try makeRepository()
    let ids = try insert(3, into: stack)
    try repository.modify(ids: [ids[2]], at: instant) { renamed($0, "keep") }

    let effects = try await repository.softDeleteInBackground(ids: ids, at: instant) { rows in
      rows.filter { $0.transaction.note != "keep" }.map(\.id)
    }

    #expect(Set(effects.deletedIds) == [ids[0], ids[1]])
    #expect(try repository.count() == 1)
    #expect(try repository.entry(id: ids[2])?.transaction.isDeleted == false)
  }

  /// The same on the calling thread: the app deletes up to a thousand operations there, and
  /// its choice is made inside the write as well — never on rows read in a transaction of
  /// their own, which a write landing in between could have changed.
  @Test func aDeletionChoosesWhatGoesInsideItsWrite() throws {
    let (stack, repository) = try makeRepository()
    let ids = try insert(3, into: stack)
    try repository.modify(ids: [ids[2]], at: instant) { renamed($0, "keep") }
    var seen: [UUID] = []

    let effects = try repository.softDelete(ids: ids, at: instant) { rows in
      seen = rows.map(\.id)
      return rows.filter { $0.transaction.note != "keep" }.map(\.id)
    }

    #expect(Set(seen) == Set(ids))
    #expect(Set(effects.deletedIds) == [ids[0], ids[1]])
    #expect(try repository.entry(id: ids[2])?.transaction.isDeleted == false)
  }

  // MARK: Deleting a reimbursement

  private struct Ledger {
    var income: AmountE4
    var mine: AmountE4
    var owed: AmountE4
  }

  private func ledger(_ repository: TransactionRepository) throws -> Ledger {
    let all = try repository.entries(from: .distantPast, to: .distantFuture)
    let totals = RowTotals(entries: all)
    return Ledger(
      income: totals.income, mine: totals.myExpenses,
      owed: MyExpensesRule.totalOwedToMe(entries: all))
  }

  /// A dinner: 400 mine, 600 for a friend, plus a salary so income is not empty.
  private func dinnerForAFriend(
    _ stack: DatabaseStack, _ repository: TransactionRepository
  ) throws -> (groceries: CoreKit.Category, surcharges: CoreKit.Category, owed: [OwedPart]) {
    let references = ReferenceRepository(writer: stack.writer)
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    let surcharges = CoreKit.Category(kind: .income, name: "Surcharges", systemRole: .surcharges)
    try references.save(groceries)
    try references.save(surcharges)

    var salary = TransactionDraft(kind: .income, amount: AmountE4(whole: 5_000), note: "salary")
    salary.normalizeSinglePart()
    try repository.save(try salary.materialize())
    var dinner = TransactionDraft(amount: AmountE4(whole: 1_000), note: "dinner")
    dinner.parts = [
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 400)),
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 600), reimbursable: true),
    ]
    try repository.save(try dinner.materialize())
    return (groceries, surcharges, try repository.owedParts())
  }

  /// Records a reimbursement the way the sheet does: the operation, the links and the
  /// surplus or shortfall with the key that points back at it.
  private func reimburse(
    _ received: Int64, closing owed: [OwedPart], surcharges: UUID,
    repository: TransactionRepository, at instant: Date = Date()
  ) throws -> UUID {
    let reimbursementId = UUID()
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: reimbursementId, amountE4: AmountE4(whole: received),
      closing: owed.map(\.inRubles))
    var draft = TransactionDraft(kind: .reimbursement, amount: AmountE4(whole: received))
    draft.normalizeSinglePart()
    var extra: [TransactionEntry] = []
    if let surplus = outcome.surplus {
      var income = TransactionDraft(kind: .income, amount: surplus.amountE4)
      income.parts = [PartDraft(categoryId: surcharges, amount: surplus.amountE4)]
      var entry = try income.materialize()
      entry.transaction.externalId = ReimbursementCompanions.surplusKey(of: reimbursementId)
      extra.append(entry)
    }
    for shortfall in outcome.shortfalls {
      var expense = TransactionDraft(amount: shortfall.amountE4)
      expense.parts = [PartDraft(categoryId: shortfall.categoryId, amount: shortfall.amountE4)]
      var entry = try expense.materialize()
      entry.transaction.externalId = ReimbursementCompanions.shortfallKey(
        of: reimbursementId, partId: shortfall.partId)
      extra.append(entry)
    }
    try repository.apply(
      outcome, reimbursement: try draft.materialize(id: reimbursementId), extra: extra,
      at: instant)
    return reimbursementId
  }

  /// How far a part has come back is a fact about its operation: closing it, reopening it
  /// by deleting the reimbursement, closing it again by ⌘Z and writing it off all stamp the
  /// purchase's `updated_at`, which the export and the transfer archive carry.
  @Test func aPartsStatusStampsItsOperationAsUpdated() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    let part = setup.owed[0]
    func updated() throws -> Date? {
      try repository.entry(id: part.transactionId)?.transaction.updatedAt
    }

    let reimbursementId = try reimburse(
      600, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository,
      at: instant)
    #expect(try updated() == instant)

    let deletedAt = instant.addingTimeInterval(60)
    let effects = try repository.softDelete(ids: [reimbursementId], at: deletedAt)
    #expect(try updated() == deletedAt)

    let restoredAt = instant.addingTimeInterval(120)
    try repository.restore(ids: effects.deletedIds, at: restoredAt, effects: effects)
    #expect(try updated() == restoredAt)

    try repository.softDelete(ids: [reimbursementId], at: instant.addingTimeInterval(180))
    let writtenOffAt = instant.addingTimeInterval(240)
    try repository.writeOffPart(id: part.partId, at: writtenOffAt)
    #expect(try updated() == writtenOffAt)
  }

  @Test func deletingAReimbursementWithASurplusPutsEverythingBack() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    let original = try ledger(repository)
    #expect(original.income == AmountE4(whole: 5_000))
    #expect(original.mine == AmountE4(whole: 400))
    #expect(original.owed == AmountE4(whole: 600))

    let reimbursementId = try reimburse(
      700, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    let reimbursed = try ledger(repository)
    #expect(reimbursed.income == AmountE4(whole: 5_100))
    #expect(reimbursed.owed == .zero)

    let effects = try repository.softDelete(ids: [reimbursementId], at: instant)
    #expect(effects.deletedIds == [reimbursementId])
    #expect(effects.companionIds.count == 1)
    #expect(effects.reopenedPartIds == setup.owed.map(\.partId))
    let deleted = try ledger(repository)
    #expect(deleted.income == original.income)
    #expect(deleted.mine == original.mine)
    #expect(deleted.owed == original.owed)

    try repository.restore(ids: effects.deletedIds, at: instant, effects: effects)
    let restored = try ledger(repository)
    #expect(restored.income == reimbursed.income)
    #expect(restored.mine == reimbursed.mine)
    #expect(restored.owed == .zero)
  }

  @Test func deletingAReimbursementWithAShortfallPutsEverythingBack() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    let original = try ledger(repository)

    let reimbursementId = try reimburse(
      500, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    let reimbursed = try ledger(repository)
    // The 100 that never came back is my spending now.
    #expect(reimbursed.mine == AmountE4(whole: 500))
    #expect(reimbursed.owed == .zero)

    let effects = try repository.softDelete(ids: [reimbursementId], at: instant)
    #expect(effects.companionIds.count == 1)
    let deleted = try ledger(repository)
    #expect(deleted.income == original.income)
    #expect(deleted.mine == original.mine)
    #expect(deleted.owed == original.owed)

    try repository.restore(ids: effects.deletedIds, at: instant, effects: effects)
    let restored = try ledger(repository)
    #expect(restored.mine == reimbursed.mine)
    #expect(restored.owed == .zero)
    #expect(try repository.owedParts().isEmpty)
  }

  /// A part two reimbursements closed together stays closed while the live one still covers
  /// it: its link gives back all of the part.
  @Test func aPartStaysClosedWhileLiveMoneyBackStillCoversIt() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    let first = try reimburse(
      600, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    let second = try TestSupport.makeEntry(amount: 6_000_000, kind: .reimbursement, note: nil)
    try repository.save(second)
    try stack.writer.write { db in
      try ReimbursementLink(
        reimbursementTxId: second.id, partId: setup.owed[0].partId,
        amountE4: AmountE4(whole: 600)
      ).insert(db)
    }

    let effects = try repository.softDelete(ids: [first], at: instant)
    #expect(effects.reopenedPartIds.isEmpty)
    #expect(try repository.owedParts().isEmpty)

    let both = try repository.softDelete(ids: [second.id], at: instant)
    #expect(both.reopenedPartIds == [setup.owed[0].partId])
    #expect(try repository.owedParts().map(\.partId) == [setup.owed[0].partId])
  }

  // MARK: A reimbursement against a part that stopped waiting

  /// The sheet reads the parts once, when it opens. The purchase can be deleted meanwhile —
  /// from the Transactions window, which the sheet does not block — and a link to its part
  /// would count the money as returned with nothing behind it.
  @Test func aReimbursementIsRefusedForAPartOfADeletedPurchase() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    let part = setup.owed[0]
    try repository.softDelete(ids: [part.transactionId], at: instant)
    let count = try repository.count()

    #expect(throws: ReimbursementError.partNoLongerOwed(part.partId)) {
      try reimburse(
        600, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    }
    #expect(try repository.count() == count)
    #expect(try stack.writer.read { try ReimbursementLink.fetchCount($0) } == 0)
    #expect(
      try stack.writer.read { try TransactionPart.fetchOne($0, key: part.partId.uuidString) }?
        .reimbursementStatus != .returned)
  }

  /// ⌘Z of the purchase's save purges it: the reimbursement is refused in words of its own,
  /// not by the foreign key of the link.
  @Test func aReimbursementIsRefusedForAPartOfAPurgedPurchase() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    let part = setup.owed[0]
    try repository.purge(id: part.transactionId)
    let count = try repository.count()

    #expect(throws: ReimbursementError.partNoLongerOwed(part.partId)) {
      try reimburse(
        600, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    }
    #expect(try repository.count() == count)
  }

  /// Written off, or closed by a reimbursement recorded in another sheet: the part is not
  /// closed a second time.
  @Test func aReimbursementIsRefusedForAPartWrittenOffOrClosedMeanwhile() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    let part = setup.owed[0]
    try repository.writeOffPart(id: part.partId)
    #expect(throws: ReimbursementError.partNoLongerOwed(part.partId)) {
      try reimburse(
        600, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    }

    try stack.writer.write { db in
      try db.execute(
        sql: "UPDATE transaction_parts SET reimbursement_status = ? WHERE id = ?",
        arguments: [ReimbursementStatus.expected.rawValue, part.partId.uuidString])
    }
    _ = try reimburse(
      600, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    let count = try repository.count()
    #expect(throws: ReimbursementError.partNoLongerOwed(part.partId)) {
      try reimburse(
        600, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    }
    #expect(try repository.count() == count)
    #expect(try stack.writer.read { try ReimbursementLink.fetchCount($0) } == 1)
  }

  /// «Write off» in the sheet acts on the list read when the sheet opened. A part closed by
  /// a reimbursement since keeps its status — flipping it would leave the link counting
  /// money for a part given up on — and so does one written off, or one whose purchase went.
  @Test func aPartNoLongerWaitingIsNotWrittenOff() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    let part = setup.owed[0]
    func status() throws -> ReimbursementStatus? {
      try stack.writer.read { try TransactionPart.fetchOne($0, key: part.partId.uuidString) }?
        .reimbursementStatus
    }

    let reimbursementId = try reimburse(
      600, closing: setup.owed, surcharges: setup.surcharges.id, repository: repository)
    #expect(throws: ReimbursementError.partNoLongerOwed(part.partId)) {
      try repository.writeOffPart(id: part.partId)
    }
    #expect(try status() == .returned)

    try repository.softDelete(ids: [reimbursementId], at: instant)
    try repository.writeOffPart(id: part.partId)
    #expect(try status() == .writtenOff)
    #expect(throws: ReimbursementError.partNoLongerOwed(part.partId)) {
      try repository.writeOffPart(id: part.partId)
    }

    try repository.softDelete(ids: [part.transactionId], at: instant)
    #expect(throws: ReimbursementError.partNoLongerOwed(part.partId)) {
      try repository.writeOffPart(id: part.partId)
    }
  }

  // MARK: Why a write failed

  /// An undo that would take away a category an operation was filed under since fails on the
  /// schema's `RESTRICT`: the owner is told that rows are tied, not that the database broke.
  @Test func aForeignKeyRefusalIsTiedToOtherRows() throws {
    let (stack, repository) = try makeRepository()
    let setup = try dinnerForAFriend(stack, repository)
    var thrown: (any Error)?
    do {
      try stack.writer.write { db in
        _ = try CoreKit.Category.deleteOne(db, key: setup.groceries.id.uuidString)
      }
    } catch {
      thrown = error
    }
    let error = try #require(thrown)
    #expect(WriteFailureCause(of: error) == .tiedToOtherRows)
    #expect(
      WriteFailureCause(of: PlanningWriteError.referencedByOperations(UUID()))
        == .tiedToOtherRows)
    #expect(WriteFailureCause(of: DatabaseError.unbalancedParts) == .other)
  }

  // MARK: Deleting a debt payment

  @Test func deletingADebtPaymentTakesItsMovementOffTheDebtAndUndoPutsItBack() throws {
    let (stack, repository) = try makeRepository()
    let references = ReferenceRepository(writer: stack.writer)
    let loan = Debt(direction: .iOwe, type: .loan, name: "Bank loan", paymentsAreExpenses: true)
    try references.save(loan)
    var draft = TransactionDraft(amount: AmountE4(whole: 7_000), note: "loan", debtId: loan.id)
    draft.normalizeSinglePart()
    let payment = try draft.materialize()
    try repository.save(payment)
    let movement = DebtEntry(
      debtId: loan.id, date: DateOnly(year: 2026, month: 9, day: 1),
      amountE4: AmountE4(whole: -7_000), kind: .payment, transactionId: payment.id)
    try references.save(movement)

    let effects = try repository.softDelete(ids: [payment.id], at: instant)
    #expect(effects.removedDebtEntries == [movement])
    #expect(try references.debtEntries(debtId: loan.id).isEmpty)

    try repository.restore(ids: effects.deletedIds, at: instant, effects: effects)
    #expect(try references.debtEntries(debtId: loan.id) == [movement])
    #expect(try repository.count() == 1)
  }

  /// Undo brings back what the deletion deleted — not an operation that had been deleted
  /// before and was only named again.
  @Test func anOperationDeletedEarlierIsNotBroughtBackByALaterUndo() throws {
    let (_, repository) = try makeRepository()
    let old = try TestSupport.makeEntry(note: "old")
    let new = try TestSupport.makeEntry(note: "new")
    try repository.save(old)
    try repository.save(new)
    try repository.softDelete(id: old.id)

    let effects = try repository.softDelete(ids: [old.id, new.id], at: instant)
    #expect(effects.deletedIds == [new.id])
    try repository.restore(ids: effects.deletedIds, at: instant, effects: effects)
    #expect(try repository.entry(id: old.id)?.transaction.isDeleted == true)
    #expect(try repository.entry(id: new.id)?.transaction.isDeleted == false)
  }
}
