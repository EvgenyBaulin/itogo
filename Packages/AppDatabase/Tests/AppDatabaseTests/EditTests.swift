import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// One operation edited on its own (the inspector, the edit sheet): one write with what hangs
/// on it, and one revert that puts every piece back.
@Suite("One operation edited: what hangs on it follows, and undo puts it all back")
struct EditTests {
  private let instant = Date(timeIntervalSince1970: 1_790_000_000)
  private let day = DateOnly(year: 2026, month: 9, day: 18)

  /// A debt with three lines of one day — the opening, a payment written with an operation,
  /// and an adjustment after it — and that operation.
  private func payment() throws -> (
    stack: DatabaseStack, repository: TransactionRepository, debt: Debt,
    operation: TransactionEntry
  ) {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(day).addingTimeInterval(12 * 3600),
      amount: AmountE4(whole: 8_500), note: "loan", debtId: fixture.debt.id)
    draft.normalizeSinglePart()
    let operation = try draft.materialize()
    try repository.save(operation)
    try stack.writer.write { db in
      try DebtRules.opening(of: fixture.debt, balance: AmountE4(whole: 100_000), date: day)
        .insert(db)
      try DebtRules.payment(
        on: fixture.debt, amountE4: AmountE4(whole: 8_500), date: day,
        transactionId: operation.id
      ).entry.insert(db)
      try DebtRules.adjustment(
        on: fixture.debt, from: .zero, to: AmountE4(whole: 100), date: day
      ).insert(db)
    }
    return (stack, repository, fixture.debt, try #require(try repository.entry(id: operation.id)))
  }

  /// The lines of the debt in the order its journal shows them: by day, then as written.
  private func journal(_ stack: DatabaseStack, _ debt: Debt) throws -> [DebtEntry] {
    try stack.writer.read { db in
      try DebtEntry.filter(Column("debt_id") == debt.id.uuidString)
        .order(Column("date"), Column.rowID)
        .fetchAll(db)
    }
  }

  @Test func theLineOfAPaymentFollowsItsAmountAndComesBackOnRevert() throws {
    let (stack, repository, debt, operation) = try payment()
    let before = try journal(stack, debt)

    let result = try repository.edit(id: operation.id, at: instant, calendar: .utc) { fresh in
      var changed = fresh
      changed.transaction.amountE4 = AmountE4(whole: 8_000)
      changed.transaction.amountRubE4 = AmountE4(whole: 8_000)
      changed.parts[0].amountE4 = AmountE4(whole: 8_000)
      changed.parts[0].amountRubE4 = AmountE4(whole: 8_000)
      return changed
    }
    guard case .edited(let edited) = result else {
      Issue.record("the edit was not written: \(result)")
      return
    }
    #expect(edited.movedDebts)
    #expect(edited.after.transaction.updatedAt == instant)
    #expect(
      try journal(stack, debt).map(\.amountE4).map(\.raw)
        == [1_000_000_000, -80_000_000, 1_000_000])

    try repository.revert(edited)
    #expect(try journal(stack, debt) == before)
    #expect(try repository.entry(id: operation.id)?.transaction.amountE4 == AmountE4(whole: 8_500))
  }

  /// The debt taken off the operation takes the line away; undo gives it back in its place
  /// among the lines of its day, not after the adjustment written later.
  @Test func aLineTakenAwayComesBackInItsPlace() throws {
    let (stack, repository, debt, operation) = try payment()
    let before = try journal(stack, debt)

    let result = try repository.edit(id: operation.id, at: instant, calendar: .utc) { fresh in
      var changed = fresh
      changed.transaction.debtId = nil
      return changed
    }
    guard case .edited(let edited) = result else {
      Issue.record("the edit was not written: \(result)")
      return
    }
    #expect(try journal(stack, debt).count == 2)

    try repository.revert(edited)
    #expect(try journal(stack, debt) == before)
  }

  @Test func anEditThatMovesNoMoneyLeavesTheJournalAlone() throws {
    let (stack, repository, debt, operation) = try payment()
    let before = try journal(stack, debt)

    let result = try repository.edit(id: operation.id, at: instant, calendar: .utc) { fresh in
      var changed = fresh
      changed.transaction.note = "another note"
      return changed
    }
    guard case .edited(let edited) = result else {
      Issue.record("the edit was not written: \(result)")
      return
    }
    #expect(!edited.movedDebts)
    #expect(try journal(stack, debt) == before)
  }

  @Test func aDeletedOperationIsGoneAndAnUnchangedOneIsNotWritten() throws {
    let (_, repository, _, operation) = try payment()
    #expect(try repository.edit(id: operation.id, at: instant, calendar: .utc) { $0 } == .unchanged)
    #expect(try repository.entry(id: operation.id)?.transaction.updatedAt != instant)

    try repository.softDelete(id: operation.id)
    #expect(try repository.edit(id: operation.id, at: instant, calendar: .utc) { $0 } == .gone)
  }
}
