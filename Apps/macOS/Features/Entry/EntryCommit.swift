import AppCore
import AppDatabase
import Foundation

/// What saving the entry line writes besides the operation itself, as one change of planning
/// and so one step of ⌘Z: a debt opened for a purchase on credit and its first line — both
/// pointing at the purchase, so ⌘Z takes them away with it instead of leaving the debt
/// behind — the line a debt payment moves its debt by, and the link of income to what was
/// expected. `nil` when the operation is all there is: then the store saves it the usual way.
enum EntryCommit {
  /// The debt is kept in another currency than the operation: its journal counts its own
  /// units, and rubles are never taken for dollars (review of the app, 19.09).
  struct CurrencyMismatch: Error {}

  /// What the entry line says when saving threw. The line has been read and its expression
  /// calculated by then, so nothing thrown here is «the expression cannot be calculated»: an
  /// amount too large for rubles says so, and a failure nobody foresaw says the operation was
  /// not saved — and goes to the journal by its type, which the words on screen do not name.
  static func errorKey(of error: any Error) -> String {
    switch error {
    case is CurrencyMismatch: return "entry.error.debtCurrency"
    case MoneyConversionError.rateMissing: return "entry.error.rateMissing"
    case CoreError.divisionByZero: return "entry.error.divisionByZero"
    case CoreError.amountOutOfRange: return "entry.error.amountTooLarge"
    default:
      AppLog.error(
        "entry.saveFailed", .db, "the entry line could not save an operation",
        [LogPair("error", .error(error))])
      return "entry.error.notSaved"
    }
  }

  static func change(
    entry: TransactionEntry, openedCredit: Debt?, creditIsNew: Bool = true, paidDebt: Debt?,
    expectedIncomeId: UUID?, day: DateOnly
  ) throws -> PlanningChange? {
    var rows = PlanningRows.empty
    let note = entry.transaction.note
    if let debt = openedCredit {
      guard debt.currency == entry.transaction.currency else { throw CurrencyMismatch() }
      if creditIsNew { rows.debts = [debt] }
      rows.debtEntries.append(
        try DebtRules.creditPurchaseOpening(
          on: debt, amountE4: entry.transaction.amountE4, date: day, transactionId: entry.id,
          description: note))
    }
    if let debt = paidDebt {
      guard debt.currency == entry.transaction.currency else { throw CurrencyMismatch() }
      if DebtRules.operationGrows(entry.transaction.kind, debt) {
        // Money I gave on a debt owed to me — I lent more — or money I got on a debt I owe —
        // I borrowed more: the debt grows. Only money that flows the paying way pays it.
        rows.debtEntries.append(
          DebtRules.makeEntry(
            debtId: debt.id, kind: .borrowed, amountE4: entry.transaction.amountE4, date: day,
            description: note, transactionId: entry.id))
      } else {
        let outcome = try DebtRules.payment(
          on: debt, amountE4: entry.transaction.amountE4, date: day, transactionId: entry.id,
          description: note)
        rows.debtEntries.append(outcome.entry)
      }
    }
    if let expectedIncomeId, entry.transaction.kind == .income {
      rows.expectedLinks = [
        ExpectedIncomeLink(expectedIncomeId: expectedIncomeId, transactionId: entry.id)
      ]
    }
    guard rows != .empty else { return nil }
    return PlanningChange(created: [entry], upsert: rows)
  }
}
