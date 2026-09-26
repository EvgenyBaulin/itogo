import CoreKit
import Foundation

/// One movement of money on one account in one currency.
public struct AccountMovement: Hashable, Sendable {
  public enum Source: Hashable, Sendable {
    case operation(UUID)
    case transferOut(UUID)
    case transferIn(UUID)
    /// A line of a debt journal: money borrowed or lent through the journal alone.
    case journal(UUID)

    /// A text that orders movements of one moment the same way on every platform.
    var sortKey: String {
      switch self {
      case .operation(let id): "0:" + id.uuidString
      case .transferOut(let id): "1:" + id.uuidString
      case .transferIn(let id): "2:" + id.uuidString
      case .journal(let id): "3:" + id.uuidString
      }
    }
  }

  /// How much of its moment a movement knows.
  public enum Timing: Hashable, Sendable {
    /// `at` is the moment it happened.
    case moment
    /// Only its day is known, and `at` is the start of that day: it is after a count made on an
    /// earlier day and before one made on a later day, but of a count made that very day
    /// nothing can be said.
    case day(DateOnly)
    /// Neither: a journal line written without a date.
    case undated
  }

  public var key: BalanceKey
  public var at: Date
  /// Signed, in the currency of `key`: plus came in, minus went out.
  public var amountE4: AmountE4
  public var source: Source
  public var timing: Timing

  public init(
    key: BalanceKey, at: Date, amountE4: AmountE4, source: Source, timing: Timing = .moment
  ) {
    self.key = key
    self.at = at
    self.amountE4 = amountE4
    self.source = source
    self.timing = timing
  }
}

/// The balance of one account in one currency: the latest count of it and what moved since.
public struct AccountBalance: Hashable, Sendable {
  public var key: BalanceKey
  /// The latest count of the key, or `nil` when it was never counted.
  public var anchor: ReconciledBalance?
  /// The moment of that count.
  public var anchorAt: Date?
  /// Σ of `movements`.
  public var movedSinceAnchor: AmountE4
  /// What moved after the count and up to now, oldest first; with no count, everything up to
  /// now.
  public var movements: [AccountMovement]
  /// Journal lines dated only by the day of the count: whether they were before it or after
  /// is not known, so they are left out and counted here.
  public var journalLinesOnAnchorDay: Int
  /// Journal lines with no date at all, left out.
  public var undatedJournalLines: Int

  public init(
    key: BalanceKey, anchor: ReconciledBalance? = nil, anchorAt: Date? = nil,
    movedSinceAnchor: AmountE4 = .zero, movements: [AccountMovement] = [],
    journalLinesOnAnchorDay: Int = 0, undatedJournalLines: Int = 0
  ) {
    self.key = key
    self.anchor = anchor
    self.anchorAt = anchorAt
    self.movedSinceAnchor = movedSinceAnchor
    self.movements = movements
    self.journalLinesOnAnchorDay = journalLinesOnAnchorDay
    self.undatedJournalLines = undatedJournalLines
  }

  /// The money on the key now; `nil` while it was never counted — a balance is never guessed.
  public var amountE4: AmountE4? { anchor.map { $0.actualE4 + movedSinceAnchor } }
}

/// A purchase on credit as the opening line of its debt repeats it: the same debt, day and
/// amount. Each purchase explains one such line.
public struct CreditOpening: Hashable, Sendable {
  public var debtId: UUID
  public var day: DateOnly
  public var amount: AmountE4

  public init(debtId: UUID, day: DateOnly, amount: AmountE4) {
    self.debtId = debtId
    self.day = day
    self.amount = amount
  }
}

/// The money on every account, per currency: the latest count of each (account, currency) plus
/// every real movement of money after the moment of that count.
///
/// * A count is a `ReconciledBalance` of a reconciliation of accounts or an opening; a
///   reconciliation of one total, as they were made before accounts, anchors nothing. The
///   latest is the last in the order of the book.
/// * Operations move their account — the main one when they name none — by what moved on it
///   (`Transaction.movedMoney`): minus for a purchase, plus for income, a refund and money
///   back. A line the app wrote for its books, a purchase on credit and money put into a goal
///   move nothing; an operation part of which goes to a goal moves only the rest.
/// * A transfer moves one key down and another up.
/// * Money borrowed or lent through a debt journal alone moves the account of its line.
/// * Nothing is converted: a balance is in its own currency, and rates never make a
///   difference.
public struct AccountBalances: Hashable, Sendable {
  /// One count of a key: the balance counted, its moment and the day of that moment.
  private struct Anchor: Hashable, Sendable {
    var balance: ReconciledBalance
    var at: Date
    var day: DateOnly
  }

  private var balances: [BalanceKey: AccountBalance]
  /// Every movement of every key, oldest first — up to now and after.
  private var movementsByKey: [BalanceKey: [AccountMovement]]
  /// Every count of every key, in the order of the book.
  private var anchorsByKey: [BalanceKey: [Anchor]]

  /// Live accounts × their currencies, and every other key with a count or a movement.
  public private(set) var keys: [BalanceKey]
  /// Live operations with no account while there is no main account to take them — none once
  /// a main account exists.
  public private(set) var unassignedOperations: Int
  /// The moment the balances are worked out for.
  public private(set) var now: Date

  public static let empty = AccountBalances(
    balances: [:], movementsByKey: [:], anchorsByKey: [:], keys: [], unassignedOperations: 0,
    now: Date(timeIntervalSince1970: 0))

  private init(
    balances: [BalanceKey: AccountBalance], movementsByKey: [BalanceKey: [AccountMovement]],
    anchorsByKey: [BalanceKey: [Anchor]], keys: [BalanceKey], unassignedOperations: Int,
    now: Date
  ) {
    self.balances = balances
    self.movementsByKey = movementsByKey
    self.anchorsByKey = anchorsByKey
    self.keys = keys
    self.unassignedOperations = unassignedOperations
    self.now = now
  }

  /// The balances as of `now`.
  ///
  /// `reconciliations` give the kind and the moment of each count; `balances` are the counts in
  /// the order of the book (`PlanningBook.reconciledBalances`). `debts` are every debt, closed
  /// ones included: their journals still say where money went. `calendar` gives the days — of
  /// a count, of a journal line dated by its moment.
  public static func build(
    entries: [TransactionEntry], transfers: [Transfer], debtEntries: [DebtEntry],
    debts: [UUID: Debt], reconciliations: [Reconciliation], balances: [ReconciledBalance],
    accounts: [PaymentMethod], tree: CategoryTree, now: Date, calendar: CalendarContext
  ) -> AccountBalances {
    let mainId = accounts.first { $0.isDefault && !$0.archived }?.id
    var movements: [BalanceKey: [AccountMovement]] = [:]
    var unassigned = 0

    for entry in entries {
      if let moved = movement(of: entry, mainId: mainId, tree: tree) {
        movements[moved.key, default: []].append(moved)
      } else if mainId == nil, entry.transaction.paymentMethodId == nil,
        !entry.transaction.isDeleted
      {
        unassigned += 1
      }
    }
    for transfer in transfers {
      movements[transfer.from, default: []].append(
        AccountMovement(
          key: transfer.from, at: transfer.occurredAt, amountE4: -transfer.fromAmountE4,
          source: .transferOut(transfer.id)))
      movements[transfer.to, default: []].append(
        AccountMovement(
          key: transfer.to, at: transfer.occurredAt, amountE4: transfer.toAmountE4,
          source: .transferIn(transfer.id)))
    }
    var openings = creditOpenings(entries, calendar: calendar)
    for line in debtEntries {
      guard let debt = debts[line.debtId],
        let moved = journalMovement(
          of: line, debt: debt, mainId: mainId, openings: &openings, calendar: calendar)
      else { continue }
      movements[moved.key, default: []].append(moved)
    }
    for key in movements.keys {
      movements[key]?.sort(by: Self.oldestFirst)
    }

    let counted = Dictionary(
      reconciliations.filter { $0.kind != .total }.compactMap { reconciliation in
        reconciliation.reconciledAt.map { (reconciliation.id, $0) }
      },
      uniquingKeysWith: { first, _ in first })
    var anchors: [BalanceKey: [Anchor]] = [:]
    for balance in balances {
      guard let at = counted[balance.reconciliationId] else { continue }
      anchors[balance.key, default: []].append(
        Anchor(balance: balance, at: at, day: calendar.day(of: at)))
    }

    var keys = Set(movements.keys).union(anchors.keys)
    for account in accounts where !account.archived {
      for currency in account.currencies {
        keys.insert(BalanceKey(accountId: account.id, currency: currency))
      }
    }
    var result = AccountBalances(
      balances: [:], movementsByKey: movements, anchorsByKey: anchors, keys: keys.sorted(),
      unassignedOperations: unassigned, now: now)
    for key in result.keys {
      result.balances[key] = result.balance(of: key, anchor: anchors[key]?.last, through: now)
    }
    return result
  }

  public subscript(key: BalanceKey) -> AccountBalance? { balances[key] }

  /// The balance of the key at `instant`: its latest count made by then plus what moved after
  /// the count and up to `instant`; `nil` when the key was not counted by then.
  public func balance(_ key: BalanceKey, at instant: Date) -> AmountE4? {
    let anchor = anchorsByKey[key]?.last { $0.at <= instant }
    return balance(of: key, anchor: anchor, through: instant).amountE4
  }

  /// The latest count of the key and its moment.
  public func latestAnchor(_ key: BalanceKey) -> (balance: ReconciledBalance, at: Date)? {
    anchorsByKey[key]?.last.map { ($0.balance, $0.at) }
  }

  /// Whether the key was ever counted or ever moved, at any moment.
  public func hasHistory(_ key: BalanceKey) -> Bool {
    !(anchorsByKey[key]?.isEmpty ?? true) || !(movementsByKey[key]?.isEmpty ?? true)
  }

  private func balance(of key: BalanceKey, anchor: Anchor?, through end: Date) -> AccountBalance {
    var balance = AccountBalance(key: key, anchor: anchor?.balance, anchorAt: anchor?.at)
    for movement in movementsByKey[key] ?? [] {
      switch movement.timing {
      case .undated:
        balance.undatedJournalLines += 1
        continue
      case .day(let day):
        if day == anchor?.day {
          balance.journalLinesOnAnchorDay += 1
          continue
        }
      case .moment:
        break
      }
      guard movement.at <= end else { continue }
      if let anchor, movement.at <= anchor.at { continue }
      balance.movements.append(movement)
      balance.movedSinceAnchor += movement.amountE4
    }
    return balance
  }

  /// By moment, then by what the movement is, so the order never depends on hashing.
  private static func oldestFirst(_ left: AccountMovement, _ right: AccountMovement) -> Bool {
    if left.at != right.at { return left.at < right.at }
    return left.source.sortKey < right.source.sortKey
  }

  // MARK: - One operation

  /// Whether an operation moves money between the owner's accounts at all. A deleted one does
  /// not, nor a line the app wrote for its books — the surplus is inside the money back, a
  /// shortfall and a remainder written off left at the purchase, a difference is inside its
  /// count —, nor a purchase on credit — the debt grew, no money left —, nor money put into a
  /// goal or taken back out of it, which stays on the accounts.
  public static func movesMoney(_ entry: TransactionEntry, tree: CategoryTree) -> Bool {
    let transaction = KindFields.masked(entry).transaction
    guard !transaction.isDeleted else { return false }
    if OperationLink(externalId: transaction.externalId)?.isBookkeeping == true { return false }
    if transaction.kind == .expense, transaction.creditDebtId != nil { return false }
    if (transaction.kind == .expense || transaction.kind == .refund),
      KindFields.isGoalOnly(entry, tree: tree)
    {
      return false
    }
    return true
  }

  /// The one movement of an operation, or `nil` when it moves nothing or has no account to
  /// move. Part of an expense or a refund that goes to a goal moves nothing; the rest of the
  /// operation moves its share of what moved on the account.
  public static func movement(
    of entry: TransactionEntry, mainId: UUID?, tree: CategoryTree
  ) -> AccountMovement? {
    let masked = KindFields.masked(entry)
    let transaction = masked.transaction
    guard movesMoney(masked, tree: tree),
      let accountId = transaction.paymentMethodId ?? mainId
    else { return nil }
    let moved = transaction.movedMoney
    var amount = moved.amount
    if transaction.kind == .expense || transaction.kind == .refund {
      let goals = masked.parts.map {
        QualityResolver.isGoalContribution(
          goalId: $0.goalId, categoryId: $0.categoryId, categories: tree)
      }
      if goals.contains(true) {
        let shares = moved.amount.allocated(
          proportionallyTo: masked.parts.map(\.amountE4), outOf: transaction.amountE4)
        amount = AmountE4.sum(zip(shares, goals).filter { !$0.1 }.map(\.0))
      }
    }
    let signed = transaction.kind == .expense ? -amount : amount
    return AccountMovement(
      key: BalanceKey(accountId: accountId, currency: moved.currency), at: transaction.occurredAt,
      amountE4: signed, source: .operation(transaction.id))
  }

  // MARK: - Debt journals

  /// Every purchase on credit, deleted ones too: the opening line of its debt is written
  /// without an operation and outlives the purchase.
  public static func creditOpenings(
    _ entries: [TransactionEntry], calendar: CalendarContext
  ) -> [CreditOpening: Int] {
    var openings: [CreditOpening: Int] = [:]
    for entry in entries where entry.transaction.kind == .expense {
      guard let debtId = entry.transaction.creditDebtId else { continue }
      let key = CreditOpening(
        debtId: debtId, day: calendar.day(of: entry.transaction.occurredAt),
        amount: entry.transaction.amountE4)
      openings[key, default: 0] += 1
    }
    return openings
  }

  /// The money a line of a debt journal moved on an account, or `nil` when it moved none.
  ///
  /// Only money borrowed or lent through the journal alone moves money here: a `borrowed` line
  /// written without an operation. A line with an operation is left to that operation, and
  /// every other kind of line moves a balance of the debt, not money. A debt of a purchase on
  /// credit never brought money: its lines are the price of what was bought; and on a debt I
  /// owe, the opening line of a purchase put on it — the same debt, day and amount as the
  /// purchase (`openings`) — is explained by that purchase, one line per purchase.
  ///
  /// Borrowed money came in (plus), lent money went out (minus), on the line's account — the
  /// main one when it names none — in what moved on it: its own figure when the account does not
  /// hold the debt's currency, otherwise the line's amount. A line knows its moment, or only its
  /// day, or nothing (`AccountMovement.Timing`).
  public static func journalMovement(
    of line: DebtEntry, debt: Debt, mainId: UUID?, openings: inout [CreditOpening: Int],
    calendar: CalendarContext
  ) -> AccountMovement? {
    guard line.kind == .borrowed, line.transactionId == nil, line.debtId == debt.id else {
      return nil
    }
    let lent = debt.direction == .owedToMe
    if !lent && debt.origin == .purchase { return nil }
    let day = line.date ?? line.occurredAt.map(calendar.day(of:))
    if !lent, let day {
      let key = CreditOpening(debtId: debt.id, day: day, amount: line.amountE4)
      if let count = openings[key], count > 0 {
        openings[key] = count - 1
        return nil
      }
    }
    guard let accountId = line.paymentMethodId ?? mainId else { return nil }
    let key = BalanceKey(accountId: accountId, currency: line.accountCurrency ?? debt.currency)
    let magnitude = line.accountAmountE4 ?? line.amountE4.magnitude
    let signed = lent ? -magnitude : magnitude
    let source = AccountMovement.Source.journal(line.id)
    if let moment = line.occurredAt {
      return AccountMovement(key: key, at: moment, amountE4: signed, source: source)
    }
    if let day {
      return AccountMovement(
        key: key, at: calendar.startOfDay(day), amountE4: signed, source: source,
        timing: .day(day))
    }
    return AccountMovement(
      key: key, at: .distantPast, amountE4: signed, source: source, timing: .undated)
  }
}
