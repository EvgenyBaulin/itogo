import AppCore
import AppDatabase
import Foundation
import SwiftUI

/// What saving the entry line writes besides the operation itself, as one change of planning
/// and so one step of ⌘Z: a debt opened for a purchase on credit and its first line — both
/// pointing at the purchase, so ⌘Z takes them away with it instead of leaving the debt
/// behind — the line a debt payment moves its debt by, and the link of income to what was
/// expected. `nil` when the operation is all there is: then the store saves it the usual way.
enum EntryCommit {
  /// The debt is kept in another currency than the operation: its journal counts its own
  /// units, and rubles are never taken for dollars (review of the app, 19.09).
  struct CurrencyMismatch: Error {}

  /// A debt opened «on credit» for anything but a purchase: an income or a refund buys
  /// nothing, and a debt for it would be paid off by nothing.
  struct CreditNotPurchase: Error {}

  /// What the entry line says when saving threw. The line has been read and its expression
  /// calculated by then, so nothing thrown here is «the expression cannot be calculated»: an
  /// amount too large for rubles says so, and a failure nobody foresaw says the operation was
  /// not saved — and goes to the journal by its type, which the words on screen do not name.
  static func errorKey(of error: any Error) -> String {
    switch error {
    case is CurrencyMismatch: return "entry.error.debtCurrency"
    case is CreditNotPurchase: return "entry.error.creditNotPurchase"
    case MoneyConversionError.rateMissing: return "entry.error.rateMissing"
    // A refund of a purchase: more than is left of it — another refund came meanwhile — or a
    // purchase that can no longer be refunded.
    case RefundError.exceedsRemaining: return "entry.error.refundExceedsRemaining"
    case RefundError.notPositive: return "entry.error.amountNotPositive"
    case RefundError.otherCurrency: return "entry.error.refundOtherCurrency"
    case RefundError.notRefundable, RefundError.purchaseHasRefunds:
      return "entry.error.refundNotRefundable"
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
      guard entry.transaction.kind.canBeBoughtOnCredit else { throw CreditNotPurchase() }
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

/// «Это было до сверки в 14:05?» — asked when an operation is saved after the latest count of a
/// balance it moves and dated on that count's day (`EntryDraftModel.countToAskAbout`). The
/// answer dates it before or after the count (`EntryDraftModel.answerCount`) and the save goes
/// on; closing the question saves nothing.
struct BeforeTheCountQuestion: Identifiable, Hashable {
  /// The moment of the count.
  let count: Date
  var id: Date { count }
}

/// The question as a dialog of whatever view saves: «Да» and «Нет» answer it, and `answered`
/// gets the count and whether the operation was before it.
struct BeforeTheCountDialog: ViewModifier {
  @Dependency(\.environment) private var environment
  @Binding var question: BeforeTheCountQuestion?
  let answered: (_ count: Date, _ wasBefore: Bool) -> Void

  func body(content: Content) -> some View {
    content.confirmationDialog(
      title, isPresented: isPresented, titleVisibility: .visible, presenting: question
    ) { question in
      Button(t("entry.beforeCount.yes")) { answered(question.count, true) }
      Button(t("entry.beforeCount.no")) { answered(question.count, false) }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: { _ in
      Text(verbatim: t("entry.beforeCount.message"))
    }
  }

  private var title: String {
    guard let question else { return "" }
    return environment.language.format(
      "entry.beforeCount.title", table: "Entry", environment.dates.time(question.count))
  }

  private var isPresented: Binding<Bool> {
    Binding(
      get: { question != nil },
      set: { isShown in
        if !isShown { question = nil }
      })
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Entry") }
}

extension View {
  /// Asks «Это было до сверки в 14:05?» while `question` is set.
  func beforeTheCountQuestion(
    _ question: Binding<BeforeTheCountQuestion?>,
    answered: @escaping (_ count: Date, _ wasBefore: Bool) -> Void
  ) -> some View {
    modifier(BeforeTheCountDialog(question: question, answered: answered))
  }
}
