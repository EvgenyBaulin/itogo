import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// One debt of the Debts section, with its journal worked out.
public struct DebtLine: Identifiable, Hashable, Sendable {
  public var debt: Debt
  /// Σ of the journal, in the currency of the debt: plus is still owed.
  public var balance: AmountE4
  /// The balance in rubles; `nil` for a foreign debt without a known rate.
  public var balanceRub: AmountE4?
  /// Subtotals per group, in the order the groups first appear in the journal.
  public var groups: [DebtGroupTotal]
  public var nextPayment: DateOnly?
  public var paidThisMonth: Bool
  /// The journal, newest first; lines without a date last.
  public var entries: [DebtEntry]

  public init(
    debt: Debt, balance: AmountE4, balanceRub: AmountE4?, groups: [DebtGroupTotal],
    nextPayment: DateOnly?, paidThisMonth: Bool, entries: [DebtEntry]
  ) {
    self.debt = debt
    self.balance = balance
    self.balanceRub = balanceRub
    self.groups = groups
    self.nextPayment = nextPayment
    self.paidThisMonth = paidThisMonth
    self.entries = entries
  }

  public var id: UUID { debt.id }
}

/// A part I paid for somebody else that is still expected back, as the «Owed to me» list
/// shows it.
public struct OwedPartSummary: Identifiable, Hashable, Sendable {
  public var partId: UUID
  public var transactionId: UUID
  /// The day of the purchase.
  public var day: DateOnly
  /// Who owes it: the debtor of the part.
  public var personId: UUID?
  /// What the part cost in rubles on the day of the purchase — what is owed.
  public var amountRub: AmountE4
  /// The note of the part, otherwise of its operation.
  public var note: String?

  public init(
    partId: UUID, transactionId: UUID, day: DateOnly, personId: UUID?, amountRub: AmountE4,
    note: String?
  ) {
    self.partId = partId
    self.transactionId = transactionId
    self.day = day
    self.personId = personId
    self.amountRub = amountRub
    self.note = note
  }

  public var id: UUID { partId }
}

/// Everything one person owes me: their personal debts and the parts I paid for them.
public struct OwedToMeGroup: Hashable, Sendable {
  /// `nil` gathers the debts and the parts that name nobody.
  public var personId: UUID?
  public var debts: [DebtLine]
  /// Oldest first.
  public var parts: [OwedPartSummary]
  /// The balances of the debts in rubles (those with a rate) plus the parts.
  public var totalRub: AmountE4
  /// The oldest expectation: the earliest part, or the earliest dated journal line of a
  /// debt that still has something owed on it.
  public var oldest: DateOnly?

  public init(
    personId: UUID?, debts: [DebtLine], parts: [OwedPartSummary], totalRub: AmountE4,
    oldest: DateOnly?
  ) {
    self.personId = personId
    self.debts = debts
    self.parts = parts
    self.totalRub = totalRub
    self.oldest = oldest
  }
}

/// The Debts section: two lists — «I owe» and «Owed to me» — the closed
/// debts, and the totals on top.
///
/// Balances live here and nowhere else: they never reach the Overview or the analytics, which
/// read operations only.
public struct DebtsOverview: Hashable, Sendable {
  /// Open debts I owe: the nearest payment first, then by name.
  public var iOwe: [DebtLine]
  /// Open debts owed to me and the parts I paid for others that are still expected, merged
  /// by person: the largest total first, the group without a person last.
  public var owedToMe: [OwedToMeGroup]
  /// Closed debts of both directions, by name.
  public var closed: [DebtLine]
  /// Σ balances of `iOwe` in rubles, the debts without a rate left out.
  public var totalIOweRub: AmountE4
  /// Σ totals of `owedToMe`.
  public var totalOwedToMeRub: AmountE4
  /// Σ monthly payments of the open debts I owe, in rubles.
  public var monthlyPaymentsRub: AmountE4
  /// Open debts left out of a total because their currency has no known rate (or, beyond any
  /// real figure, their rubles do not fit into stored units: `DebtRubles.convert`).
  public var withoutRate: [UUID]

  public init(
    iOwe: [DebtLine], owedToMe: [OwedToMeGroup], closed: [DebtLine], totalIOweRub: AmountE4,
    totalOwedToMeRub: AmountE4, monthlyPaymentsRub: AmountE4, withoutRate: [UUID]
  ) {
    self.iOwe = iOwe
    self.owedToMe = owedToMe
    self.closed = closed
    self.totalIOweRub = totalIOweRub
    self.totalOwedToMeRub = totalOwedToMeRub
    self.monthlyPaymentsRub = monthlyPaymentsRub
    self.withoutRate = withoutRate
  }

  /// The section for `today`.
  ///
  /// * Debts come from the dataset of the ledger, the closed ones included; their journals
  ///   from `book.debtEntries`. A balance is `DebtRules.balance` of the journal, the groups
  ///   are `DebtRules.groupTotals`.
  /// * A foreign balance or payment is converted at the last rate the caller knows
  ///   (`rubPerUnit`); without one the debt stays in its list with no rubles and is named in
  ///   `withoutRate` instead of being guessed into a total.
  /// * The parts paid for others are the ones the Overview counts as owed to me: parts of
  ///   purchases, paid for somebody else, still expected — in the rubles they cost on the day
  ///   of the purchase. The person is the debtor of the part, the same key the
  ///   report of payments for others groups by.
  public static func build(
    ledger: Ledger, book: PlanningBook, today: DateOnly, rubPerUnit: [CurrencyCode: Decimal]
  ) -> DebtsOverview {
    var journals: [UUID: [DebtEntry]] = [:]
    for entry in book.debtEntries { journals[entry.debtId, default: []].append(entry) }
    let paidByOperation = DebtSchedule.debtsPaid(
      in: today.monthKey, ledger: ledger, journal: book.debtEntries)

    func line(_ debt: Debt) -> DebtLine {
      let journal = journals[debt.id] ?? []
      let paid = DebtSchedule.isPaid(
        debt.id, in: today.monthKey, paidByOperation: paidByOperation, journal: journal)
      let balance = DebtRules.balance(entries: journal)
      return DebtLine(
        debt: debt, balance: balance,
        balanceRub: DebtRubles.convert(balance, from: debt.currency, rubPerUnit: rubPerUnit),
        groups: DebtRules.groupTotals(entries: journal),
        nextPayment: DebtSchedule.nextPaymentDate(
          of: debt, today: today, paidThisMonth: paid, calendar: ledger.calendar),
        paidThisMonth: paid, entries: newestFirst(journal))
    }

    let debts = ledger.dataset.debts
    let open = debts.filter { !$0.closed }.map(line)
    let iOwe = open.filter { $0.debt.direction == .iOwe }.sorted(by: nearestPaymentFirst)
    let closed = debts.filter(\.closed).map(line).sorted(by: byName)

    // «Owed to me»: the person's debts and the parts they owe, one group per person.
    var groupDebts: [UUID?: [DebtLine]] = [:]
    for line in open where line.debt.direction == .owedToMe {
      groupDebts[line.debt.personId, default: []].append(line)
    }
    var groupParts: [UUID?: [OwedPartSummary]] = [:]
    for row in ledger.rows
    where row.kind == .expense && row.reimbursable && row.reimbursementStatus == .expected {
      let entry = ledger.entry(row.transactionId)
      let part = entry?.parts.first { $0.id == row.partId }
      groupParts[row.debtorPersonId, default: []].append(
        OwedPartSummary(
          partId: row.partId, transactionId: row.transactionId, day: row.day,
          personId: row.debtorPersonId, amountRub: row.amountRubE4,
          note: part?.note ?? entry?.transaction.note))
    }
    let people = Set(groupDebts.keys).union(groupParts.keys)
    let owedToMe = people.map { person in
      group(
        person, debts: (groupDebts[person] ?? []).sorted(by: byName),
        parts: groupParts[person] ?? [])
    }.sorted(by: largestFirst)

    let payments = DebtLoad.monthlyPayments(of: debts, rubPerUnit: rubPerUnit)
    let unconverted = open.filter { $0.balanceRub == nil }.map(\.debt.id)
    return DebtsOverview(
      iOwe: iOwe, owedToMe: owedToMe, closed: closed,
      totalIOweRub: AmountE4.sum(iOwe.compactMap(\.balanceRub)),
      totalOwedToMeRub: AmountE4.sum(owedToMe.map(\.totalRub)),
      monthlyPaymentsRub: payments.total,
      withoutRate: DebtRubles.sorted(Set(unconverted).union(payments.withoutRate)))
  }

  // MARK: - Pieces

  /// Parts come in the order of the ledger — by day — which is oldest first.
  static func group(
    _ personId: UUID?, debts: [DebtLine], parts: [OwedPartSummary]
  ) -> OwedToMeGroup {
    let total =
      AmountE4.sum(debts.compactMap(\.balanceRub)) + AmountE4.sum(parts.map(\.amountRub))
    let starts = debts.filter { $0.balance.raw > 0 }.compactMap { line in
      line.entries.compactMap(\.date).min()
    }
    let oldest = (parts.map(\.day) + starts).min()
    return OwedToMeGroup(
      personId: personId, debts: debts, parts: parts, totalRub: total, oldest: oldest)
  }

  /// Dated lines newest first, undated ones after them; among equals the later line of the
  /// journal first, since the journal is written in the order things happen.
  static func newestFirst(_ journal: [DebtEntry]) -> [DebtEntry] {
    journal.enumerated().sorted { left, right in
      switch (left.element.date, right.element.date) {
      case (let leftDate?, let rightDate?) where leftDate != rightDate:
        return leftDate > rightDate
      case (.some, .none):
        return true
      case (.none, .some):
        return false
      default:
        return left.offset > right.offset
      }
    }.map(\.element)
  }

  static func nearestPaymentFirst(_ left: DebtLine, _ right: DebtLine) -> Bool {
    switch (left.nextPayment, right.nextPayment) {
    case (let leftDay?, let rightDay?) where leftDay != rightDay:
      return leftDay < rightDay
    case (.some, .none):
      return true
    case (.none, .some):
      return false
    default:
      return byName(left, right)
    }
  }

  static func byName(_ left: DebtLine, _ right: DebtLine) -> Bool {
    if left.debt.name != right.debt.name { return left.debt.name < right.debt.name }
    return left.debt.id.uuidString < right.debt.id.uuidString
  }

  /// The largest total first; the group without a person last, as in the report of payments
  /// for others.
  static func largestFirst(_ left: OwedToMeGroup, _ right: OwedToMeGroup) -> Bool {
    if (left.personId == nil) != (right.personId == nil) { return right.personId == nil }
    if left.totalRub != right.totalRub { return left.totalRub > right.totalRub }
    return (left.personId?.uuidString ?? "") < (right.personId?.uuidString ?? "")
  }
}
