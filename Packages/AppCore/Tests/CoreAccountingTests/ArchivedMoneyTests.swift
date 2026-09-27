import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// An account in the archive stays at zero: what an edit, a deletion or the archive itself
/// would leave on it is moved to a live account by a transfer.
@Suite("Money left on an archived account")
struct ArchivedMoneyTests {
  let categories = StartingCategories()
  let sber = PaymentMethod(
    id: id(2), name: "Sber", currency: .rub, isDefault: true, otherCurrencies: [.usd])
  let wallet = PaymentMethod(id: id(3), name: "Wallet", currency: .rub)
  var cash: PaymentMethod {
    PaymentMethod(
      id: id(1), name: "Cash", currency: .rub, archived: true, otherCurrencies: [.usd])
  }
  var cashRub: BalanceKey { BalanceKey(accountId: id(1), currency: .rub) }
  var cashUsd: BalanceKey { BalanceKey(accountId: id(1), currency: .usd) }
  var sberRub: BalanceKey { BalanceKey(accountId: id(2), currency: .rub) }

  /// 26.09 at `hour` UTC.
  func at(_ hour: Double) -> Date { moment("2026-09-26").addingTimeInterval(hour * 3600) }

  func purchase(_ number: Int, _ amount: Int, on account: UUID, at moment: Date) -> TransactionEntry
  {
    TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: .expense, occurredAt: moment, currency: .rub,
        amountE4: money(amount), paymentMethodId: account),
      parts: [TransactionPart(transactionId: id(number), amountE4: money(amount))])
  }

  func balances(
    entries: [TransactionEntry] = [], transfers: [Transfer] = [],
    counted: [(BalanceKey, Int)] = [(BalanceKey(accountId: id(1), currency: .rub), 5_000)],
    now: Date? = nil
  ) -> AccountBalances {
    let count = Reconciliation(
      id: id(90), date: day("2026-09-26"), reconciledAt: at(6), actualTotalRubE4: .zero,
      kind: .accounts)
    return AccountBalances.build(
      entries: entries, transfers: transfers, debtEntries: [], debts: [:],
      reconciliations: [count],
      balances: counted.enumerated().map { index, row in
        ReconciledBalance(
          id: id(900 + index), reconciliationId: count.id, accountId: row.0.accountId,
          currency: row.0.currency, actualE4: money(row.1))
      },
      accounts: [sber, wallet, cash], tree: categories.tree, now: now ?? at(12),
      calendar: .utc)
  }

  func movement(_ entry: TransactionEntry) -> [AccountMovement] {
    AccountBalances.movement(of: entry, mainId: sber.id, tree: categories.tree).map { [$0] } ?? []
  }

  /// «Наличные» counted 5,000 at 06:00, a purchase of 5,000 at 07:00, archived at 0.
  /// The purchase edited to 4,000 would leave 1,000 on it.
  @Test func anEditLeavingMoneyAsksForACounterpart() {
    let old = purchase(10, 5_000, on: cash.id, at: at(7))
    var new = old
    new.transaction.amountE4 = money(4_000)
    new.parts[0].amountE4 = money(4_000)
    let books = balances(entries: [old])
    #expect(books[cashRub]?.amountE4 == .zero)
    let check = ArchivedMoney.leftovers(
      removing: movement(old), adding: movement(new), balances: books,
      accounts: [sber, wallet, cash])
    #expect(check.unknown.isEmpty)
    #expect(
      check.leftovers == [ArchivedLeftover(key: cashRub, amount: money(1_000), latest: at(7))])
  }

  /// A transfer «Сбер → Наличные» of 1,000 after the count, deleted: «Наличные» would fall to
  /// −1,000, so 1,000 is brought in from a live account.
  @Test func deletingATransferIntoAnArchivedAccountTakesItBelowZero() {
    let transfer = Transfer(
      id: id(20), occurredAt: at(8), fromAccountId: sber.id, fromCurrency: .rub,
      fromAmountE4: money(1_000), toAccountId: cash.id, toCurrency: .rub,
      toAmountE4: money(1_000))
    let books = balances(transfers: [transfer], counted: [(cashRub, 0), (sberRub, 10_000)])
    let check = ArchivedMoney.leftovers(
      removing: ArchivedMoney.movements(of: transfer), adding: [], balances: books,
      accounts: [sber, wallet, cash])
    #expect(check.leftovers.map(\.key) == [cashRub])
    #expect(check.leftovers.first?.amount == money(-1_000))
    let settling = ArchivedMoney.settlingTransfer(
      check.leftovers[0], counterpart: sber.id, now: at(12), note: "n", id: id(30))
    #expect(settling.fromAccountId == sber.id && settling.toAccountId == cash.id)
    #expect(settling.fromAmountE4 == money(1_000) && settling.toAmountE4 == money(1_000))
    #expect(settling.occurredAt == at(12))
  }

  /// A change dated before the archived account's latest count changes that count's
  /// difference, not its balance: nothing is left on it.
  @Test func aChangeInsideACountWindowLeavesNothing() {
    let old = purchase(10, 500, on: cash.id, at: at(5))
    var new = old
    new.transaction.amountE4 = money(300)
    new.parts[0].amountE4 = money(300)
    let check = ArchivedMoney.leftovers(
      removing: movement(old), adding: movement(new), balances: balances(entries: [old]),
      accounts: [sber, wallet, cash])
    #expect(check.leftovers.isEmpty)
    #expect(check.unknown.isEmpty)
    // And a comment changes nothing at all.
    var noted = old
    noted.transaction.note = "lunch"
    #expect(
      ArchivedMoney.leftovers(
        removing: movement(old), adding: movement(noted), balances: balances(entries: [old]),
        accounts: [sber, wallet, cash]
      ).leftovers.isEmpty)
  }

  /// The transfer written with the change brings the key back to zero, and the live account
  /// gets the money.
  @Test func theSettlingTransferBringsTheKeyBackToZero() {
    let old = purchase(10, 5_000, on: cash.id, at: at(7))
    var new = old
    new.transaction.amountE4 = money(4_000)
    new.parts[0].amountE4 = money(4_000)
    let books = balances(entries: [old], counted: [(cashRub, 5_000), (sberRub, 10_000)])
    let check = ArchivedMoney.leftovers(
      removing: movement(old), adding: movement(new), balances: books,
      accounts: [sber, wallet, cash])
    let settling = ArchivedMoney.settlingTransfer(
      check.leftovers[0], counterpart: sber.id, now: at(12), note: nil, id: id(30))
    let after = balances(
      entries: [new], transfers: [settling], counted: [(cashRub, 5_000), (sberRub, 10_000)],
      now: at(13))
    #expect(after[cashRub]?.amountE4 == .zero)
    #expect(after[sberRub]?.amountE4 == money(11_000))
  }

  /// A change dated after now: the transfer is dated no earlier than the change, or the money
  /// would sit on the archived account from then on.
  @Test func aFutureChangeDatesItsTransferAfterIt() {
    let future = purchase(10, 700, on: cash.id, at: at(30))
    let check = ArchivedMoney.leftovers(
      removing: movement(future), adding: [], balances: balances(entries: [future]),
      accounts: [sber, wallet, cash])
    let settling = ArchivedMoney.settlingTransfer(
      check.leftovers[0], counterpart: sber.id, now: at(12), note: nil, id: id(30))
    #expect(settling.occurredAt == at(30))
  }

  /// Only live accounts that hold the currency take the money, in the order of every menu:
  /// the main account first.
  @Test func counterpartsHoldTheCurrency() {
    let accounts = [wallet, cash, sber]
    let rub = ArchivedMoney.counterparts(
      for: cashRub, accounts: accounts, locale: Locale(identifier: "en"))
    #expect(rub.map(\.id) == [sber.id, wallet.id])
    let usd = ArchivedMoney.counterparts(
      for: cashUsd, accounts: accounts, locale: Locale(identifier: "en"))
    #expect(usd.map(\.id) == [sber.id])
    let kzt = BalanceKey(accountId: cash.id, currency: CurrencyCode("KZT"))
    #expect(
      ArchivedMoney.counterparts(for: kzt, accounts: accounts, locale: Locale(identifier: "en"))
        .isEmpty)
  }

  /// «В архив» on an account with 3,000 ₽ and 50 $: both are moved; a credit card at −30,000
  /// is covered from a live account.
  @Test func archivingMovesEveryCountedCurrency() {
    var live = cash
    live.archived = false
    let books = balances(counted: [(cashRub, 3_000), (cashUsd, 50)])
    let result = ArchivedMoney.balancesToMove(of: live, balances: books)
    #expect(result.unknown.isEmpty)
    #expect(result.leftovers.map(\.key) == [cashRub, cashUsd].sorted())
    #expect(Set(result.leftovers.map(\.amount)) == [money(3_000), money(50)])

    let credit = balances(counted: [(cashRub, -30_000)])
    let owed = ArchivedMoney.balancesToMove(of: live, balances: credit)
    #expect(owed.leftovers.map(\.amount) == [money(-30_000)])
    let settling = ArchivedMoney.settlingTransfer(
      owed.leftovers[0], counterpart: sber.id, now: at(12), note: nil, id: id(31))
    #expect(settling.fromAccountId == sber.id && settling.toAccountId == cash.id)
    #expect(settling.fromAmountE4 == money(30_000))
  }

  /// «Наличные» holds 12,000 now, and rent of 30,000 is typed ahead, three days on. Archived
  /// today with only the 12,000 moved, it would fall to −30,000 once the rent is paid and leave
  /// «Всего» 30,000 too high; with one transfer of −18,000 dated with the rent, its 12,000 would
  /// sit on the archive, in no total, until then. So it is settled in two legs: the 12,000 it
  /// holds now go to «Сбер» now, and the 30,000 of the rent come back from «Сбер» with the rent.
  /// A key at zero now with the rent ahead holds money too, and so does one whose money now the
  /// rent takes back to zero.
  @Test func archivingCountsMoneyTypedAhead() {
    var live = cash
    live.archived = false
    let rent = purchase(10, 30_000, on: cash.id, at: at(84))
    let books = balances(entries: [rent], counted: [(cashRub, 12_000), (sberRub, 50_000)])
    #expect(books[cashRub]?.amountE4 == money(12_000), "the balance now leaves the rent out")
    let check = ArchivedMoney.balancesToMove(of: live, balances: books)
    #expect(check.unknown.isEmpty)
    #expect(
      check.leftovers == [
        ArchivedLeftover(
          key: cashRub, amount: money(-18_000), latest: at(84), heldNow: money(12_000))
      ])
    #expect(check.leftovers[0].shownAmount == money(12_000), "the question names the money now")
    var next = 30
    let settling = ArchivedMoney.settlingTransfers(
      check.leftovers[0], counterpart: sber.id, now: at(12), note: nil,
      ids: {
        next += 1
        return id(next)
      })
    #expect(settling.map(\.occurredAt) == [at(12), at(84)])
    #expect(settling[0].fromAccountId == cash.id && settling[0].toAccountId == sber.id)
    #expect(settling[0].fromAmountE4 == money(12_000))
    #expect(settling[1].fromAccountId == sber.id && settling[1].toAccountId == cash.id)
    #expect(settling[1].toAmountE4 == money(30_000))
    #expect(Set(settling.map(\.id)).count == 2)
    let after = balances(
      entries: [rent], transfers: settling, counted: [(cashRub, 12_000), (sberRub, 50_000)],
      now: at(96))
    #expect(after[cashRub]?.amountE4 == .zero)
    #expect(after[sberRub]?.amountE4 == money(32_000))
    let meanwhile = balances(
      entries: [rent], transfers: settling, counted: [(cashRub, 12_000), (sberRub, 50_000)],
      now: at(13))
    #expect(meanwhile[cashRub]?.amountE4 == .zero, "no money sits on it before the rent either")
    #expect(meanwhile[sberRub]?.amountE4 == money(62_000))

    var archived = live
    archived.archived = true
    let atZero = balances(entries: [rent], counted: [(cashRub, 0)])
    #expect(atZero[cashRub]?.amountE4 == .zero)
    #expect(
      AccountRules.validate(
        archived, previous: live, balances: atZero, enabled: [.rub, .usd], others: [sber, wallet]
      ) == [.archivesWithMoney])
    let owed = ArchivedMoney.balancesToMove(of: live, balances: atZero).leftovers
    #expect(owed.map(\.amount) == [money(-30_000)])
    let onRentDay = ArchivedMoney.settlingTransfers(
      owed[0], counterpart: sber.id, now: at(12), note: nil)
    #expect(onRentDay.map(\.occurredAt) == [at(84)], "nothing to move now: one leg, with the rent")

    let paidAhead = balances(entries: [rent], counted: [(cashRub, 30_000), (sberRub, 50_000)])
    #expect(
      AccountRules.validate(
        archived, previous: live, balances: paidAhead, enabled: [.rub, .usd],
        others: [sber, wallet]) == [.archivesWithMoney],
      "30,000 now is money, though the rent takes it back to zero")
    let both = ArchivedMoney.balancesToMove(of: live, balances: paidAhead).leftovers
    #expect(both.map(\.amount) == [.zero])
    #expect(both.map(\.shownAmount) == [money(30_000)])
    let legs = ArchivedMoney.settlingTransfers(
      both[0], counterpart: sber.id, now: at(12), note: nil)
    #expect(legs.map(\.occurredAt) == [at(12), at(84)])
    let emptied = balances(
      entries: [rent], transfers: legs, counted: [(cashRub, 30_000), (sberRub, 50_000)],
      now: at(13))
    #expect(emptied[cashRub]?.amountE4 == .zero)
    #expect(emptied[sberRub]?.amountE4 == money(80_000))
    let paid = balances(
      entries: [rent], transfers: legs, counted: [(cashRub, 30_000), (sberRub, 50_000)],
      now: at(96))
    #expect(paid[cashRub]?.amountE4 == .zero)
    #expect(paid[sberRub]?.amountE4 == money(50_000))

    // Money held now and nothing typed ahead: one transfer, dated now, as before.
    let plain = balances(counted: [(cashRub, 1_000)])
    let one = ArchivedMoney.balancesToMove(of: live, balances: plain).leftovers
    #expect(
      ArchivedMoney.settlingTransfers(one[0], counterpart: sber.id, now: at(12), note: nil)
        .map(\.occurredAt) == [at(12)])
  }

  /// A key that moved but was never counted: nobody knows its balance, so nothing is moved
  /// for it and it is named apart.
  @Test func aNeverCountedKeyIsUnknown() {
    let spend = purchase(10, 200, on: cash.id, at: at(7))
    let books = balances(entries: [spend], counted: [])
    let check = ArchivedMoney.leftovers(
      removing: movement(spend), adding: [], balances: books, accounts: [sber, wallet, cash])
    #expect(check.leftovers.isEmpty)
    #expect(check.unknown == [cashRub])
    var live = cash
    live.archived = false
    #expect(ArchivedMoney.balancesToMove(of: live, balances: books).unknown == [cashRub])
  }

  /// In a base from 1.1, «Наличные» went to the archive at +1,000 before 1.2 asked. The
  /// leftover is offered as it is.
  @Test func aLeftoverFromOnePointOneIsOffered() {
    let books = balances(counted: [(cashRub, 1_000)])
    let result = ArchivedMoney.balancesToMove(of: cash, balances: books)
    #expect(
      result.leftovers == [
        ArchivedLeftover(key: cashRub, amount: money(1_000), latest: at(12), heldNow: money(1_000))
      ])
  }

  /// A live account is never asked about: only archived keys have leftovers.
  @Test func aLiveAccountLeavesNothing() {
    let old = purchase(10, 500, on: sber.id, at: at(7))
    let check = ArchivedMoney.leftovers(
      removing: movement(old), adding: [], balances: balances(entries: [old]),
      accounts: [sber, wallet, cash])
    #expect(check.leftovers.isEmpty && check.unknown.isEmpty)
  }
}
