import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Merging one account into another")
struct AccountMergeTests {
  let categories = StartingCategories()
  let kzt = CurrencyCode("KZT")

  var source: PaymentMethod {
    PaymentMethod(
      id: id(1), name: "Old card", currency: .rub, isDefault: true, otherCurrencies: [.usd])
  }
  var target: PaymentMethod {
    PaymentMethod(id: id(2), name: "New card", currency: .rub, otherCurrencies: [kzt])
  }

  func key(_ account: UUID, _ currency: CurrencyCode) -> BalanceKey {
    BalanceKey(accountId: account, currency: currency)
  }

  func spend(
    _ number: Int, _ amount: Int, _ currency: CurrencyCode, on account: UUID
  )
    -> TransactionEntry
  {
    TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: .expense, occurredAt: moment("2026-03-05"), currency: currency,
        amountE4: money(amount), paymentMethodId: account),
      parts: [TransactionPart(transactionId: id(number), amountE4: money(amount))])
  }

  func balances(
    _ entries: [TransactionEntry], transfers: [Transfer] = [], counted: [(BalanceKey, Int)]
  ) -> AccountBalances {
    let reconciliation = Reconciliation(
      id: id(90), date: day("2026-03-01"), reconciledAt: moment("2026-03-01"),
      actualTotalRubE4: .zero, kind: .opening)
    return AccountBalances.build(
      entries: entries, transfers: transfers, debtEntries: [], debts: [:],
      reconciliations: [reconciliation],
      balances: counted.map {
        ReconciledBalance(
          reconciliationId: id(90), accountId: $0.0.accountId, currency: $0.0.currency,
          actualE4: money($0.1))
      },
      accounts: [source, target], tree: categories.tree, now: moment("2026-03-31"),
      calendar: .utc)
  }

  @Test func theTargetTakesTheCurrenciesAndTheMainFlagOfBoth() {
    let result = AccountMerge.plan(
      source: source, target: target, transfers: [], balances: balances([], counted: []),
      at: moment("2026-03-20"))
    #expect(result.plan.target.currencies == [.rub, kzt, .usd])
    #expect(result.plan.target.isDefault)
    #expect(result.plan.sourceId == id(1))
  }

  @Test func theBalancesAreAddedUpAndTheSourceIsCountedAtZero() {
    let known = balances(
      [spend(3, 100, .rub, on: id(1)), spend(4, 50, .rub, on: id(2))],
      counted: [(key(id(1), .rub), 1000), (key(id(2), .rub), 500), (key(id(1), .usd), 20)])
    let result = AccountMerge.plan(
      source: source, target: target, transfers: [], balances: known, at: moment("2026-03-20"))
    #expect(result.plan.opening[key(id(2), .rub)] == money(1350))
    #expect(result.plan.opening[key(id(2), .usd)] == money(20))
    #expect(result.plan.opening[key(id(2), kzt)] == nil)
    #expect(result.needsBalance.isEmpty)
    #expect(result.plan.sourceZero == [key(id(1), .rub), key(id(1), .usd)].sorted())
    #expect(result.plan.hadAnchor.contains(key(id(2), .rub)))
    #expect(result.plan.hadAnchor.contains(key(id(1), .usd)))
    #expect(!result.plan.hadAnchor.contains(key(id(2), .usd)))
  }

  /// A key that moved but was never counted cannot be added up: the dialog asks for it.
  @Test func aBalanceNobodyKnowsIsAskedFor() {
    let partly = balances(
      [spend(3, 100, .rub, on: id(1)), spend(4, 50, .rub, on: id(2))],
      counted: [(key(id(2), .rub), 500)])
    let result = AccountMerge.plan(
      source: source, target: target, transfers: [], balances: partly, at: moment("2026-03-20"))
    #expect(result.needsBalance == [key(id(2), .rub)])
    #expect(result.plan.opening[key(id(2), .rub)] == nil)
  }

  @Test func transfersBetweenTheTwoInOneCurrencyGoAndExchangesStay() {
    let same = Transfer(
      id: id(70), occurredAt: moment("2026-03-03"), fromAccountId: id(1), fromCurrency: .rub,
      fromAmountE4: money(100), toAccountId: id(2), toCurrency: .rub, toAmountE4: money(100))
    let exchange = Transfer(
      id: id(71), occurredAt: moment("2026-03-03"), fromAccountId: id(1), fromCurrency: .rub,
      fromAmountE4: money(100), toAccountId: id(2), toCurrency: kzt, toAmountE4: money(550))
    let elsewhere = Transfer(
      id: id(72), occurredAt: moment("2026-03-03"), fromAccountId: id(1), fromCurrency: .rub,
      fromAmountE4: money(100), toAccountId: id(3), toCurrency: .rub, toAmountE4: money(100))
    let result = AccountMerge.plan(
      source: source, target: target, transfers: [same, exchange, elsewhere],
      balances: balances([], counted: []), at: moment("2026-03-20"))
    #expect(result.plan.deletedTransferIds == [id(70)])
  }
}
