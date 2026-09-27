import CoreKit
import Foundation

/// Money a change would leave on a key of an account in the archive.
public struct ArchivedLeftover: Hashable, Sendable {
  public var key: BalanceKey
  /// Plus: money left on the archived key, to be moved off to a live account. Minus: the key
  /// taken below its count, to be brought back from one.
  public var amount: AmountE4
  /// The latest moment the change puts on this key: the transfer that settles it is dated no
  /// earlier, or the money would sit on the archived account from then on.
  public var latest: Date
  /// For the whole balance of a key (`ArchivedMoney.balancesToMove`): what it holds now. When
  /// money typed ahead of now makes `amount` another figure, the key is settled in two legs —
  /// what it holds now by a transfer dated now, the rest by one dated `latest` —, so it is at
  /// zero in between too, when no total would count the money it held. `nil` for what a change
  /// leaves.
  public var heldNow: AmountE4?

  public init(key: BalanceKey, amount: AmountE4, latest: Date, heldNow: AmountE4? = nil) {
    self.key = key
    self.amount = amount
    self.latest = latest
    self.heldNow = heldNow
  }

  /// The money the question about the key names: what it holds now when that is not zero —
  /// the transfer dated now moves it —, else `amount`.
  public var shownAmount: AmountE4 {
    if let heldNow, !heldNow.isZero { return heldNow }
    return amount
  }
}

/// What a change leaves on archived accounts: the leftovers to move, and the keys that moved
/// but were never counted — nobody knows their balance, so nothing is moved for them.
public struct ArchivedMoneyCheck: Hashable, Sendable {
  public var leftovers: [ArchivedLeftover]
  public var unknown: [BalanceKey]

  public init(leftovers: [ArchivedLeftover] = [], unknown: [BalanceKey] = []) {
    self.leftovers = leftovers
    self.unknown = unknown
  }

  public static let none = ArchivedMoneyCheck()
}

/// An account in the archive stays at zero. No total counts it, so money left on it would
/// leave «Всего» for good, and money taken from it would be made out of nothing. An edit or a
/// deletion that would do either — or the archive of an account that still holds money — is
/// paired with a transfer between the archived key and a live account of the same currency,
/// dated now — or with the latest money on the key typed ahead of now —, so the archived key is
/// back at zero and the live account holds the real money. An account archived with money now
/// and other money typed ahead is settled in two legs, now and then.
///
/// Only what moves the balance counts: a change dated at or before the archived key's latest
/// count changes that count's difference, not its balance, and a money-neutral edit (a comment,
/// a category, a place) moves nothing at all.
public enum ArchivedMoney {
  /// What the change — `old` movements taken away, `new` ones put in — leaves on every key of
  /// an archived account among `accounts`, per key, the non-zero ones only, in key order. A key
  /// that moves but was never counted goes to `unknown`.
  public static func leftovers(
    removing old: [AccountMovement], adding new: [AccountMovement], balances: AccountBalances,
    accounts: [PaymentMethod]
  ) -> ArchivedMoneyCheck {
    let archived = Set(accounts.filter(\.archived).map(\.id))
    var sums: [BalanceKey: AmountE4] = [:]
    var latest: [BalanceKey: Date] = [:]
    var unknown: Set<BalanceKey> = []
    func add(_ movement: AccountMovement, sign: Int64) {
      guard archived.contains(movement.key.accountId), !movement.amountE4.isZero else { return }
      guard let effect = balances.effectAfterLatestCount(movement) else {
        unknown.insert(movement.key)
        return
      }
      guard !effect.isZero else { return }
      sums[movement.key, default: .zero] += sign > 0 ? effect : -effect
      latest[movement.key] = max(latest[movement.key] ?? movement.at, movement.at)
    }
    for movement in old { add(movement, sign: -1) }
    for movement in new { add(movement, sign: 1) }
    let leftovers = sums.keys.sorted().compactMap { key -> ArchivedLeftover? in
      guard let amount = sums[key], !amount.isZero else { return nil }
      return ArchivedLeftover(key: key, amount: amount, latest: latest[key] ?? balances.now)
    }
    return ArchivedMoneyCheck(leftovers: leftovers, unknown: unknown.sorted())
  }

  /// What archiving `account` leaves — or what an account already in the archive still holds:
  /// every counted key of it with money now or once everything written on it has happened, plus
  /// or minus, in key order (`AccountBalances.balanceAhead`), with what it holds now
  /// (`ArchivedLeftover.heldNow`). An operation typed ahead of now counts: left out, it would
  /// take the archived key off zero on its day. The money of now is then settled now and the
  /// rest with the latest movement (`settlingTransfers`). A key that moved but was never counted
  /// goes to `unknown`.
  public static func balancesToMove(
    of account: PaymentMethod, balances: AccountBalances
  ) -> ArchivedMoneyCheck {
    var keys = Set(account.currencies.map { BalanceKey(accountId: account.id, currency: $0) })
    for key in balances.keys where key.accountId == account.id { keys.insert(key) }
    var check = ArchivedMoneyCheck()
    for key in keys.sorted() {
      if let amount = balances.balanceAhead(key) {
        let now = balances.balance(key, at: balances.now)
        guard !amount.isZero || !(now ?? .zero).isZero else { continue }
        check.leftovers.append(
          ArchivedLeftover(
            key: key, amount: amount, latest: balances.momentAhead(key), heldNow: now))
      } else if balances.hasHistory(key) {
        check.unknown.append(key)
      }
    }
    return check
  }

  /// The live accounts that hold the key's currency and can take its money, in the order of
  /// every menu (the main account first). Never the archived account itself.
  public static func counterparts(
    for key: BalanceKey, accounts: [PaymentMethod], locale: Locale
  ) -> [PaymentMethod] {
    AccountRules.ordered(
      accounts.filter { !$0.archived && $0.id != key.accountId && $0.holds(key.currency) },
      locale: locale)
  }

  /// The transfer that brings the key back to zero: money left on it goes from it to
  /// `counterpart`, money taken below its count comes from `counterpart` to it — the whole
  /// amount, in the key's currency, dated `now` or the change's latest moment when that is
  /// later.
  public static func settlingTransfer(
    _ leftover: ArchivedLeftover, counterpart: UUID, now: Date, note: String?, id: UUID
  ) -> Transfer {
    transfer(
      leftover.amount, of: leftover.key, counterpart: counterpart,
      at: max(now, leftover.latest), now: now, note: note, id: id)
  }

  /// The transfers that keep the key at zero from now on. What a change leaves goes by one
  /// (`settlingTransfer`). A whole balance goes by what it holds now, dated `now`, and by the
  /// rest money typed ahead makes of it, dated with the latest movement ahead: one leg or two,
  /// the ones that are not zero.
  public static func settlingTransfers(
    _ leftover: ArchivedLeftover, counterpart: UUID, now: Date, note: String?,
    ids: () -> UUID = { UUID() }
  ) -> [Transfer] {
    let later = max(now, leftover.latest)
    guard let held = leftover.heldNow, later > now else {
      return [
        settlingTransfer(leftover, counterpart: counterpart, now: now, note: note, id: ids())
      ]
    }
    var legs: [(AmountE4, Date)] = []
    if !held.isZero { legs.append((held, now)) }
    let rest = leftover.amount - held
    if !rest.isZero { legs.append((rest, later)) }
    return legs.map { amount, at in
      transfer(
        amount, of: leftover.key, counterpart: counterpart, at: at, now: now, note: note,
        id: ids())
    }
  }

  /// `amount` between the key and `counterpart`: plus leaves the key, minus comes to it.
  private static func transfer(
    _ amount: AmountE4, of key: BalanceKey, counterpart: UUID, at moment: Date, now: Date,
    note: String?, id: UUID
  ) -> Transfer {
    let other = BalanceKey(accountId: counterpart, currency: key.currency)
    let (from, to) = amount.raw > 0 ? (key, other) : (other, key)
    return Transfer(
      id: id, occurredAt: moment, fromAccountId: from.accountId, fromCurrency: from.currency,
      fromAmountE4: amount.magnitude, toAccountId: to.accountId, toCurrency: to.currency,
      toAmountE4: amount.magnitude, note: note, createdAt: now, updatedAt: now)
  }

  /// The two legs of a transfer as the balances see them: money out of one key, into another.
  public static func movements(of transfer: Transfer) -> [AccountMovement] {
    [
      AccountMovement(
        key: transfer.from, at: transfer.occurredAt, amountE4: -transfer.fromAmountE4,
        source: .transferOut(transfer.id)),
      AccountMovement(
        key: transfer.to, at: transfer.occurredAt, amountE4: transfer.toAmountE4,
        source: .transferIn(transfer.id)),
    ]
  }
}

extension AccountBalances {
  /// What `movement` does to its key's balance from its latest count on: its whole amount when
  /// it is after that count, by the rule of the balances; zero when it is at or before it —
  /// then it changes the count's difference, not the balance — and for a journal line dated
  /// only by the count's day or not dated at all. `nil` when the key was never counted: its
  /// balance is not known. A movement dated after now counts too: it will move the balance.
  public func effectAfterLatestCount(_ movement: AccountMovement) -> AmountE4? {
    guard let anchor = latestAnchor(movement.key) else { return nil }
    switch movement.timing {
    case .undated:
      return .zero
    case .day(let day):
      if day == self.day(of: anchor.at) { return .zero }
    case .moment:
      break
    }
    return movement.at > anchor.at ? movement.amountE4 : .zero
  }
}
