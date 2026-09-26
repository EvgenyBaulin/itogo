import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Merging one account into another, on random histories: the merge is carried out the way the
/// storage layer carries it out — same-currency transfers between the two deleted, everything
/// of the source pointed at the target, the target counted at the plan's opening and the source
/// at zero — and the money is compared before and after.
@Suite("Merging accounts keeps the money")
struct AccountMergePropertyTests {
  static let kzt = CurrencyCode("KZT")
  let categories = StartingCategories()
  let source = PaymentMethod(
    id: id(1), name: "Source", currency: .rub, isDefault: true, otherCurrencies: [.usd])
  let target = PaymentMethod(id: id(2), name: "Target", currency: .rub, otherCurrencies: [kzt])
  let other = PaymentMethod(id: id(3), name: "Other", currency: .rub)
  let start = moment("2026-03-01")
  /// The merge is made on day 40, the balances are read on day 60.
  var mergedAt: Date { start.addingTimeInterval(40 * 86_400 + 3600) }
  var now: Date { start.addingTimeInterval(60 * 86_400) }

  struct History {
    var entries: [TransactionEntry] = []
    var transfers: [Transfer] = []
    var reconciliations: [Reconciliation] = []
    var counted: [ReconciledBalance] = []
  }

  func history(seed: UInt64) -> History {
    var dice = MoneyDice(seed: seed)
    var history = History()
    var number = 1000
    let accounts = [source, target, other]
    func key(_ account: PaymentMethod, _ dice: inout MoneyDice) -> BalanceKey {
      BalanceKey(accountId: account.id, currency: dice.pick(account.currencies))
    }
    for _ in 0..<dice.int(20...70) {
      number += 1
      let at = start.addingTimeInterval(TimeInterval(dice.below(60 * 1440) * 60))
      if dice.chance(30) {
        let from = key(dice.pick(accounts), &dice)
        var to = key(dice.pick(accounts), &dice)
        if to == from { to = BalanceKey(accountId: other.id, currency: .rub) }
        if to == from { continue }
        let sent = dice.amount(upTo: 20_000)
        history.transfers.append(
          Transfer(
            id: id(number), occurredAt: at, fromAccountId: from.accountId,
            fromCurrency: from.currency, fromAmountE4: sent, toAccountId: to.accountId,
            toCurrency: to.currency,
            toAmountE4: from.currency == to.currency ? sent : dice.amount(upTo: 90_000)))
        continue
      }
      let spot = key(dice.pick(accounts), &dice)
      let amount = dice.amount(upTo: 9000)
      let kind = dice.pick([TransactionKind.expense, .expense, .income, .refund])
      history.entries.append(
        TransactionEntry(
          transaction: Transaction(
            id: id(number), kind: kind, occurredAt: at, currency: spot.currency,
            amountE4: amount, paymentMethodId: spot.accountId, createdAt: at, updatedAt: at),
          parts: [
            TransactionPart(
              id: id(number * 10), transactionId: id(number), categoryId: categories.groceries,
              amountE4: amount)
          ]))
    }
    // Counts made before the merge, of some keys.
    for index in 0..<dice.int(0...3) {
      let at = start.addingTimeInterval(TimeInterval(dice.below(39 * 1440) * 60))
      let reconciliation = Reconciliation(
        id: id(700 + index), date: CalendarContext.utc.day(of: at), reconciledAt: at,
        actualTotalRubE4: .zero, kind: .accounts)
      history.reconciliations.append(reconciliation)
      for account in accounts {
        for currency in account.currencies where dice.chance(60) {
          history.counted.append(
            ReconciledBalance(
              id: id(80_000 + history.counted.count), reconciliationId: reconciliation.id,
              accountId: account.id, currency: currency, actualE4: dice.amount(upTo: 200_000)))
        }
      }
    }
    history.reconciliations.sort { ($0.reconciledAt ?? start) < ($1.reconciledAt ?? start) }
    let order = Dictionary(
      uniqueKeysWithValues: history.reconciliations.enumerated().map { ($1.id, $0) })
    history.counted.sort { (order[$0.reconciliationId] ?? 0) < (order[$1.reconciliationId] ?? 0) }
    return history
  }

  func balances(_ history: History, accounts: [PaymentMethod]) -> AccountBalances {
    AccountBalances.build(
      entries: history.entries, transfers: history.transfers, debtEntries: [], debts: [:],
      reconciliations: history.reconciliations, balances: history.counted, accounts: accounts,
      tree: categories.tree, now: now, calendar: .utc)
  }

  /// The merge as the storage layer writes it.
  func merged(_ history: History, plan: AccountMergePlan) -> History {
    var after = history
    let gone = Set(plan.deletedTransferIds)
    after.transfers = history.transfers.filter { !gone.contains($0.id) }.map { transfer in
      var moved = transfer
      if moved.fromAccountId == source.id { moved.fromAccountId = target.id }
      if moved.toAccountId == source.id { moved.toAccountId = target.id }
      return moved
    }
    after.entries = history.entries.map { entry in
      var moved = entry
      if moved.transaction.paymentMethodId == source.id {
        moved.transaction.paymentMethodId = target.id
      }
      return moved
    }
    let opening = Reconciliation(
      id: id(999), date: CalendarContext.utc.day(of: plan.at), reconciledAt: plan.at,
      actualTotalRubE4: .zero, kind: .opening)
    after.reconciliations.append(opening)
    for (index, row) in plan.opening.sorted(by: { $0.key < $1.key }).enumerated() {
      after.counted.append(
        ReconciledBalance(
          id: id(990_000 + index), reconciliationId: opening.id, accountId: row.key.accountId,
          currency: row.key.currency, actualE4: row.value))
    }
    for (index, key) in plan.sourceZero.enumerated() where plan.opening[key] == nil {
      after.counted.append(
        ReconciledBalance(
          id: id(995_000 + index), reconciliationId: opening.id, accountId: key.accountId,
          currency: key.currency, actualE4: .zero))
    }
    return after
  }

  /// Every currency of the merged account holds what the two held together — at the moment of
  /// the merge and after it, what moved on the source since landing on the target —, the source
  /// holds nothing, the third account is untouched, and the plan asks only for what nobody
  /// knows.
  @Test(arguments: Array(1...60) as [UInt64])
  func theMergedAccountHoldsWhatTheTwoHeld(seed: UInt64) {
    let history = history(seed: seed)
    let before = balances(history, accounts: [source, target, other])
    let (plan, needs) = AccountMerge.plan(
      source: source, target: target, transfers: history.transfers, balances: before,
      at: mergedAt)
    var archived = source
    archived.archived = true
    archived.isDefault = false
    let after = balances(merged(history, plan: plan), accounts: [archived, plan.target, other])

    #expect(plan.target.isDefault, "seed \(seed): the main flag passes to the target")
    #expect(Set(plan.target.currencies) == Set([CurrencyCode.rub, .usd, Self.kzt]), "seed \(seed)")
    for currency in plan.target.currencies {
      let into = BalanceKey(accountId: target.id, currency: currency)
      let from = BalanceKey(accountId: source.id, currency: currency)
      let known = [into, from].filter { before.hasHistory($0) }
      let amounts = known.map { before.balance($0, at: now) }
      if known.isEmpty {
        #expect(!needs.contains(into), "seed \(seed), \(currency)")
        continue
      }
      if amounts.contains(nil) {
        #expect(needs.contains(into), "seed \(seed), \(currency): nobody knows it, so it is asked")
        continue
      }
      #expect(!needs.contains(into), "seed \(seed), \(currency)")
      let together = AmountE4.sum(amounts.compactMap { $0 })
      #expect(after[into]?.amountE4 == together, "seed \(seed), \(currency)")
      let atMerge = AmountE4.sum(known.compactMap { before.balance($0, at: mergedAt) })
      #expect(after.balance(into, at: mergedAt) == atMerge, "seed \(seed), \(currency)")
    }
    for key in plan.sourceZero {
      #expect(after[key]?.amountE4 == .zero, "seed \(seed), \(key): the source holds nothing")
    }
    for currency in other.currencies {
      let key = BalanceKey(accountId: other.id, currency: currency)
      #expect(after[key]?.amountE4 == before[key]?.amountE4, "seed \(seed)")
    }
    let deleted = Set(plan.deletedTransferIds)
    for transfer in history.transfers {
      let between =
        Set([transfer.fromAccountId, transfer.toAccountId]) == Set([source.id, target.id])
      #expect(
        deleted.contains(transfer.id) == (between && !transfer.isExchange), "seed \(seed)")
    }
  }
}
