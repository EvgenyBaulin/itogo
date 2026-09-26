import CoreKit
import Foundation

/// One account merged into another, worked out before anything is written.
public enum AccountMerge {
  /// The merge of `source` into `target` at `at`:
  ///
  /// * the target holds its own currencies, in its order, then those of the source it lacks;
  /// * it is the main account when either of the two was;
  /// * the transfers between the two in one currency go — they would move money from the
  ///   account to itself; an exchange between them stays, inside the merged account;
  /// * the target is counted in every currency at what the two held together at `at`, when
  ///   both are known, or when only one of them was ever counted or ever moved; otherwise the
  ///   key goes into `needsBalance`, which the merge dialog asks for — a key left unanswered
  ///   stays uncounted;
  /// * the source is counted at zero in every currency it holds or has money in: its money now
  ///   lives in the target, and bringing the source back from the archive must not count it
  ///   twice;
  /// * a key counted before compares, with no difference; any other is a starting point.
  public static func plan(
    source: PaymentMethod, target: PaymentMethod, transfers: [Transfer],
    balances: AccountBalances, at: Date
  ) -> (plan: AccountMergePlan, needsBalance: [BalanceKey]) {
    var merged = target
    var others = Array(target.currencies.dropFirst())
    for currency in source.currencies where !target.holds(currency) && !others.contains(currency) {
      others.append(currency)
    }
    merged.otherCurrencies = others
    merged.isDefault = target.isDefault || source.isDefault
    merged.archived = false

    let pair: Set<UUID> = [source.id, target.id]
    let deleted =
      transfers.filter {
        !$0.isExchange && pair.contains($0.fromAccountId) && pair.contains($0.toAccountId)
          && $0.fromAccountId != $0.toAccountId
      }.map(\.id)

    var sourceCurrencies = source.currencies
    for key in balances.keys where key.accountId == source.id {
      if !sourceCurrencies.contains(key.currency) { sourceCurrencies.append(key.currency) }
    }
    var currencies = merged.currencies
    for currency in sourceCurrencies where !currencies.contains(currency) {
      currencies.append(currency)
    }

    var opening: [BalanceKey: AmountE4] = [:]
    var needsBalance: [BalanceKey] = []
    var hadAnchor: Set<BalanceKey> = []
    for currency in currencies {
      let into = BalanceKey(accountId: target.id, currency: currency)
      let from = BalanceKey(accountId: source.id, currency: currency)
      let intoKnown = balances.balance(into, at: at)
      let fromKnown = balances.balance(from, at: at)
      let intoHistory = balances.hasHistory(into)
      let fromHistory = balances.hasHistory(from)
      if balances.latestAnchor(into) != nil { hadAnchor.insert(into) }
      if balances.latestAnchor(from) != nil { hadAnchor.insert(from) }
      switch (intoHistory, fromHistory) {
      case (false, false):
        continue
      case (true, false):
        if let intoKnown { opening[into] = intoKnown } else { needsBalance.append(into) }
      case (false, true):
        if let fromKnown { opening[into] = fromKnown } else { needsBalance.append(into) }
      case (true, true):
        if let intoKnown, let fromKnown {
          opening[into] = intoKnown + fromKnown
        } else {
          needsBalance.append(into)
        }
      }
    }
    let sourceZero = sourceCurrencies.map { BalanceKey(accountId: source.id, currency: $0) }
      .sorted()
    let plan = AccountMergePlan(
      sourceId: source.id, target: merged, deletedTransferIds: deleted, opening: opening, at: at,
      sourceZero: sourceZero, hadAnchor: hadAnchor)
    return (plan, needsBalance.sorted())
  }
}
