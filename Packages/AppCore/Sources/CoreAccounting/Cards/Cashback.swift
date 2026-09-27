import CoreKit
import Foundation

/// Whose cashback rules price an operation: a card, or an account paid from without a card.
public enum CashbackHolder: Hashable, Sendable {
  case card(UUID)
  case account(UUID)
}

/// Which holder's rules apply.
public enum CashbackHolders {
  /// The card the operation names — live or archived: its past purchases keep their rules —;
  /// else the only live card of its account; else the account itself. An operation that names
  /// no account is the main account's. With two cards and none named nothing is guessed: the
  /// account's own rules apply, which it usually has none of.
  public static func holder(
    accountId: UUID?, cardId: UUID?, cards: [PaymentCard], mainAccountId: UUID?
  ) -> CashbackHolder? {
    if let cardId { return .card(cardId) }
    guard let account = accountId ?? mainAccountId else { return nil }
    let live = cards.filter { $0.accountId == account && !$0.archived }
    if live.count == 1, let only = live.first { return .card(only.id) }
    return .account(account)
  }

  /// Where the rules of an account are edited now: each of its live cards, or the account
  /// itself while it has none.
  public static func editableHolders(of accountId: UUID, cards: [PaymentCard]) -> [CashbackHolder] {
    let live = CardRules.ordered(cards, of: accountId, locale: Locale(identifier: "en_US_POSIX"))
    return live.isEmpty ? [.account(accountId)] : live.map { .card($0.id) }
  }

  /// The account a holder belongs to.
  public static func account(of holder: CashbackHolder, cards: [PaymentCard]) -> UUID? {
    switch holder {
    case .account(let id): id
    case .card(let id): cards.first { $0.id == id }?.accountId
    }
  }
}

extension CashbackRule {
  /// The card of the rule, or its account when it has none.
  public var holder: CashbackHolder {
    cardId.map(CashbackHolder.card) ?? .account(accountId)
  }
}

/// Every rule of every holder, indexed once, and the order they are chosen in.
public struct CashbackRuleBook: Sendable {
  private struct Key: Hashable {
    var holder: CashbackHolder
    var month: MonthKey?
    var categoryId: UUID?
  }

  private let byKey: [Key: CashbackRule]
  private let byHolder: [CashbackHolder: [CashbackRule]]
  private let tree: CategoryTree

  public init(rules: [CashbackRule], tree: CategoryTree) {
    var byKey: [Key: CashbackRule] = [:]
    var byHolder: [CashbackHolder: [CashbackRule]] = [:]
    for rule in rules {
      let key = Key(holder: rule.holder, month: rule.month, categoryId: rule.categoryId)
      // The database keeps one rule per key; of two a hand edit left, the first stays.
      guard byKey[key] == nil else { continue }
      byKey[key] = rule
      byHolder[rule.holder, default: []].append(rule)
    }
    self.byKey = byKey
    self.byHolder = byHolder
    self.tree = tree
  }

  public var isEmpty: Bool { byKey.isEmpty }

  /// The rules of one holder, in the order they were given.
  public func rules(of holder: CashbackHolder) -> [CashbackRule] { byHolder[holder] ?? [] }

  /// The rule that prices a purchase of `categoryId` in `month`, the first found of: the month's
  /// rule of the subcategory, the month's of its category, the «always» of the subcategory, the
  /// «always» of the category, the month's «everything else», the «always» «everything else».
  /// The bank's categories of the month win over a standing rate on the same purchase, and
  /// «everything else» is the last word of both.
  public func rule(
    for holder: CashbackHolder, categoryId: UUID?, month: MonthKey
  ) -> CashbackRule? {
    guard byHolder[holder] != nil else { return nil }
    let path = categoryPath(categoryId)
    for scope in [month, nil] as [MonthKey?] {
      for category in path {
        if let rule = byKey[Key(holder: holder, month: scope, categoryId: category)] {
          return rule
        }
      }
    }
    for scope in [month, nil] as [MonthKey?] {
      if let rule = byKey[Key(holder: holder, month: scope, categoryId: nil)] { return rule }
    }
    return nil
  }

  /// The category and the categories above it, nearest first; empty without a category.
  private func categoryPath(_ categoryId: UUID?) -> [UUID] {
    guard let categoryId else { return [] }
    var path = [categoryId]
    var current = categoryId
    while let parent = tree.parent(of: current), !path.contains(parent.id), path.count < 8 {
      path.append(parent.id)
      current = parent.id
    }
    return path
  }
}

/// What the owner typed in the field «Кэшбэк»: an amount («45») or a percent («5%»).
public enum CashbackInput: Hashable, Sendable {
  /// In the currency that moves on the account; read like every typed amount (`TypedNumber`).
  case amount(AmountE4)
  /// Read like a rate (`DecimalMath.parse`): a lone comma is the decimal one, «1,5%» is 1.5 %.
  case percent(CashbackPercent)
  case unreadable(Problem)

  public enum Problem: Hashable, Sendable {
    case malformed
    case negative
    case percentAboveHundred
    case percentTooPrecise
    case tooLarge
  }

  /// `nil` for an empty field.
  public static func read(_ text: String) -> CashbackInput? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let last = trimmed.last, last == "%" || last == "％" {
      let number = trimmed.dropLast().trimmingCharacters(in: .whitespaces)
      guard let value = DecimalMath.parse(number) else { return .unreadable(.malformed) }
      if value < 0 { return .unreadable(.negative) }
      if value > 100 { return .unreadable(.percentAboveHundred) }
      guard let percent = CashbackPercent(decimal: value) else {
        return .unreadable(.percentTooPrecise)
      }
      return .percent(percent)
    }
    guard let reading = TypedNumber.read(trimmed) else {
      return .unreadable(TypedNumber.isTooLarge(trimmed) ? .tooLarge : .malformed)
    }
    if reading.value < 0 { return .unreadable(.negative) }
    guard let amount = try? AmountE4(decimal: reading.value), amount <= AmountE4.inputLimit else {
      return .unreadable(.tooLarge)
    }
    return .amount(amount)
  }
}

/// The cashback one operation is expected to earn.
public struct CashbackExpectation: Hashable, Sendable {
  public enum Source: Hashable, Sendable {
    /// The rules that priced it, each once, in the order of the parts.
    case rules([UUID])
    /// The figure the owner typed for the operation.
    case override
  }

  /// In the currency that moved on the account, to the kopeck; below zero for a refund of no
  /// purchase, which takes cashback back.
  public var money: Money
  /// The same in rubles, at the operation's own rate.
  public var rubles: AmountE4
  public var holder: CashbackHolder?
  public var source: Source

  public init(money: Money, rubles: AmountE4, holder: CashbackHolder?, source: Source) {
    self.money = money
    self.rubles = rubles
    self.holder = holder
    self.source = source
  }
}

/// How much cashback to expect. An expectation only: received cashback is income in the
/// cashback category, and nothing here ever becomes income.
public enum CashbackMath {
  /// Whether an operation can earn cashback at all: a purchase, or a refund of no purchase
  /// (it takes back what its money had earned). Not income, not money back, not a contribution
  /// to a goal, not a purchase on credit — the lender paid —, not what the app writes to keep
  /// the books, not the fee of a transfer.
  public static func earns(_ entry: TransactionEntry, tree: CategoryTree) -> Bool {
    let transaction = entry.transaction
    switch transaction.kind {
    case .expense: break
    case .refund:
      guard !entry.parts.contains(where: { $0.refundOfPartId != nil }) else { return false }
    case .income, .reimbursement: return false
    }
    guard transaction.creditDebtId == nil, !KindFields.isGoalOnly(entry, tree: tree) else {
      return false
    }
    switch OperationLink(externalId: transaction.externalId) {
    case .some(.transferFee): return false
    case .some(let link) where link.isBookkeeping: return false
    default: return true
    }
  }

  /// The cashback a saved operation is expected to earn, or `nil` when it earns none or its
  /// holder has no rule for any of its parts.
  ///
  /// The base is the money that moved on the account, the whole receipt with the parts paid for
  /// others: the bank pays on what the card was charged. It is spread over the parts in their
  /// proportions; what refunds took back from a part (`refunded`, in the operation's currency)
  /// makes that part cheaper. Each part takes the rule of its own category; the sum is rounded
  /// once, to the kopeck, half away from zero. A figure the owner typed wins over the rules and
  /// shrinks with the refunds the same way.
  public static func expected(
    _ entry: TransactionEntry, holder: CashbackHolder?, book: CashbackRuleBook,
    tree: CategoryTree, calendar: CalendarContext, refunded: (UUID) -> AmountE4
  ) -> CashbackExpectation? {
    guard earns(entry, tree: tree) else { return nil }
    let transaction = entry.transaction
    let moved = transaction.movedMoney
    let total = transaction.amountE4
    let sign: Decimal = transaction.kind == .refund ? -1 : 1
    let weights = entry.parts.map(\.amountE4)
    let bases = moved.amount.allocated(proportionallyTo: weights, outOf: total)

    if let typed = transaction.keptCashback {
      let refundedTotal = AmountE4.sum(entry.parts.map { refunded($0.id) })
      let kept = total.isZero ? 1 : max(0, (total - refundedTotal).decimal / total.decimal)
      return expectation(
        sign * typed.amount.decimal * kept, of: transaction, holder: holder, source: .override)
    }
    guard let holder else { return nil }
    let month = calendar.day(of: transaction.occurredAt).monthKey
    var value = Decimal(0)
    var used: [UUID] = []
    for (part, base) in zip(entry.parts, bases) {
      guard let rule = book.rule(for: holder, categoryId: part.categoryId, month: month) else {
        continue
      }
      if !used.contains(rule.id) { used.append(rule.id) }
      let amount = part.amountE4.decimal
      let left =
        amount.isZero ? Decimal(0) : max(0, (amount - refunded(part.id).decimal) / amount)
      value += base.decimal * left * rule.percent.fraction
    }
    guard !used.isEmpty else { return nil }
    return expectation(sign * value, of: transaction, holder: holder, source: .rules(used))
  }

  /// The same for the ↓ panel, before anything is saved: nothing refunded yet, the typed
  /// figure taken from the draft.
  public static func expected(
    _ draft: TransactionDraft, holder: CashbackHolder?, book: CashbackRuleBook,
    tree: CategoryTree, calendar: CalendarContext
  ) -> CashbackExpectation? {
    guard let entry = entry(of: draft) else { return nil }
    return expected(
      entry, holder: holder, book: book, tree: tree, calendar: calendar, refunded: { _ in .zero })
  }

  /// A typed percent of the draft's base — the money that moves on the account —, to the kopeck.
  public static func amount(of percent: CashbackPercent, on draft: TransactionDraft) -> Money? {
    let moved = movedMoney(of: draft)
    let value = DecimalMath.round(moved.amount.decimal.magnitude * percent.fraction, scale: 2)
    guard let amount = try? AmountE4(decimal: value) else { return nil }
    return Money(amount: amount, currency: moved.currency)
  }

  /// What moves on the account for a draft: its «Списано со счёта», else its own amount.
  public static func movedMoney(of draft: TransactionDraft) -> Money {
    if let currency = draft.accountCurrency, let amount = draft.accountAmount {
      return Money(amount: amount, currency: currency)
    }
    return Money(amount: draft.amount, currency: draft.currency)
  }

  private static func entry(of draft: TransactionDraft) -> TransactionEntry? {
    var draft = draft
    if draft.parts.isEmpty { draft.normalizeSinglePart() }
    let rate = draft.currency == .rub ? Decimal(1) : draft.rate
    return try? draft.materialize(
      id: UUID(), now: Date(timeIntervalSince1970: 0),
      rublesConverter: { amount in
        guard let rate else { return amount }
        return try AmountE4(decimal: amount.decimal * rate)
      })
  }

  private static func expectation(
    _ value: Decimal, of transaction: Transaction, holder: CashbackHolder?,
    source: CashbackExpectation.Source
  ) -> CashbackExpectation? {
    let moved = transaction.movedMoney
    let rounded = DecimalMath.round(value, scale: 2)
    guard let amount = try? AmountE4(decimal: rounded) else { return nil }
    let rubles: AmountE4
    if moved.currency == .rub {
      rubles = amount
    } else if moved.amount.isZero {
      rubles = .zero
    } else {
      let exact =
        rounded * transaction.amountRubE4.decimal / moved.amount.decimal
      rubles = (try? AmountE4(decimal: DecimalMath.round(exact, scale: 2))) ?? .zero
    }
    return CashbackExpectation(
      money: Money(amount: amount, currency: moved.currency), rubles: rubles, holder: holder,
      source: source)
  }
}
