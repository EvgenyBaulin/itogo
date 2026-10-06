import CoreAnalytics
import CoreKit
import Foundation

/// «В этом месяце больше платежей не будет»: a payment of a debt may say that no more money goes
/// to the due it was made for, and the due closes although the payment is smaller than the
/// monthly one (`DebtEntry.closesTerm`, `DebtDues`). Said only where it can matter.
public enum DebtTerms {
  /// Whether a payment of `amount` on `debt` may say it: the debt is one I owe, open, with a
  /// monthly payment and a payment day and something to pay, and the payment, with the money
  /// already paid toward the earliest unpaid due, does not cover that due — a percent short of
  /// it is covered (`DebtDues.tolerance`). `dues` is the state of the debt's dues; without it
  /// the monthly payment is the measure. What is left of the due is never more than is left of
  /// the debt (`DebtDueState.owed`): a payment of all of it pays the debt off, and there is no
  /// month after it for the word to speak of.
  public static func offersClosing(
    _ debt: Debt, paying amount: AmountE4, dues: DebtDueState?
  ) -> Bool {
    guard debt.direction == .iOwe, !debt.closed, amount.raw > 0,
      let monthly = debt.monthlyPaymentE4, monthly.raw > 0, debt.paymentDay != nil
    else { return false }
    var left = monthly
    if let dues {
      guard let due = dues.firstUnpaid else { return false }
      left = dues.owed(due, monthly: monthly)
    }
    return amount + DebtDues.tolerance(of: monthly) < left
  }

  /// What a payment of `debt` starts with: what is left of the earliest unpaid due — the monthly
  /// payment less the money already paid toward it —, else the monthly payment; zero for a debt
  /// with none.
  public static func amountToPay(_ debt: Debt, dues: DebtDueState?) -> AmountE4 {
    guard let monthly = debt.monthlyPaymentE4, monthly.raw > 0 else { return .zero }
    guard let dues, let due = dues.firstUnpaid else { return monthly }
    let left = dues.owed(due, monthly: monthly)
    return left.raw > 0 ? left : monthly
  }

  /// Whether a loan written today asks «Платёж за этот месяц уже сделан?»: it is one I already
  /// had, with a monthly payment and a payment day, and today is that day —
  /// the last day of a shorter month included —; the balance the owner entered is either what is
  /// left after the payment or before it, and only they know. A debt owed to me and a purchase on
  /// credit, which first owes a month after the purchase (`DebtStart`), ask nothing.
  public static func asksAboutThisMonth(_ debt: Debt, balance: AmountE4, today: DateOnly) -> Bool {
    guard debt.direction == .iOwe, debt.origin == .existing, balance.raw > 0,
      let monthly = debt.monthlyPaymentE4, monthly.raw > 0, let day = debt.paymentDay, day >= 1
    else { return false }
    return DebtDueState.payday(day, in: today.monthKey) == today
  }
}
