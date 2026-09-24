import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

// MARK: - The formula

/// Whether a line of the formula adds to the expected total or takes from it.
public enum ReconciliationSign: Int, Hashable, Sendable {
  case plus = 1
  case minus = -1

  public func applied(to amount: AmountE4) -> AmountE4 {
    self == .plus ? amount : -amount
  }
}

/// One term of the expected total of a reconciliation, in the order the sheet
/// shows them. Keys are stable (`reconcile.term.<name>`): the app looks the words up by them.
///
/// Written plainly, the formula is «previous + income + money returned − my expenses − parts
/// for others not yet returned». Read literally it counts three things twice or not at
/// all: the surplus of a reimbursement is both income and part of the money returned; a
/// shortfall is my expense today although the money left at the purchase; a part bought
/// for somebody and returned inside one window is never subtracted while its return is
/// added. So the expected total is built from the money that really moved, and every
/// correction is a line of its own — the formula stays fully visible.
public enum ReconciliationTerm: String, CaseIterable, Hashable, Sendable {
  /// The actual total of the previous reconciliation: where the count starts.
  case previous
  /// Every income operation, the surplus records of reimbursements included.
  case income
  /// The surplus records: that money is already inside «returned», which counts the whole
  /// amount the person gave.
  case surplus
  /// Money people gave back for what I paid for them, as received (no debt attached).
  case returned
  /// My expenses by the accounting rules (`MyExpensesRule`).
  case myExpenses
  /// Shortfalls are my expenses now, but their money left my pocket at the purchase.
  case shortfalls
  /// A purchase on credit is my expense, but no money left: the debt grew instead.
  case onCredit
  /// Contributions to goals are my expenses, but the money is still in the total I count.
  case goalSavings
  /// Paid for somebody else and not returned yet: the money left, it is not my expense.
  case paidForOthersExpected
  /// Paid for somebody else and already returned: the money left, and its return is
  /// inside «returned».
  case paidForOthersReturned
  /// Payments on debts that are not expenses (a purchase in instalments pays off here).
  case debtPayments
  /// Money a person paid back on a debt owed to me.
  case repaidToMe
  /// Money I borrowed, from the debt journal.
  case borrowed
  /// Money I lent, from the debt journal or an operation on a debt owed to me.
  case lent

  public var key: String { "reconcile.term." + rawValue }

  public var sign: ReconciliationSign {
    switch self {
    case .previous, .income, .returned, .shortfalls, .onCredit, .goalSavings, .repaidToMe,
      .borrowed:
      .plus
    case .surplus, .myExpenses, .paidForOthersExpected, .paidForOthersReturned, .debtPayments,
      .lent:
      .minus
    }
  }
}

/// One line of the formula: what the sheet shows as «+ income 45 000».
public struct ReconciliationLine: Hashable, Sendable {
  public var term: ReconciliationTerm
  public var sign: ReconciliationSign
  /// The sum of the line, before its sign. It can be below zero: refunds can outweigh
  /// the spending of a window.
  public var amount: AmountE4

  public init(term: ReconciliationTerm, amount: AmountE4) {
    self.term = term
    self.sign = term.sign
    self.amount = amount
  }

  /// What the line adds to the expected total.
  public var signedAmount: AmountE4 { sign.applied(to: amount) }
}

/// The expected total of the next reconciliation, with the lines it is made of.
public struct ReconciliationExpectation: Hashable, Sendable {
  public var previous: Reconciliation
  /// Operations after this instant count: the moment of the previous reconciliation, or the
  /// end of its day when it has no moment.
  public var from: Date
  /// …up to and including this one.
  public var to: Date
  /// Every term in the order of `ReconciliationTerm`; `goalSavings` only when the setting
  /// keeps the savings in the total.
  public var lines: [ReconciliationLine]
  public var expected: AmountE4
  /// Journal lines that would move money but carry no date, so no window can hold them.
  /// The sheet says they were left out instead of guessing.
  public var undatedJournalLines: Int
  /// Journal lines in a currency the caller has no rate for, left out the same way.
  public var journalLinesWithoutRate: Int
  /// Journal lines that would move money, dated on the day of the previous reconciliation.
  /// A line has a day and no moment, so nothing tells whether it was written before that
  /// reconciliation — its money already in that total — or after it. They are left out, as
  /// the day rule has it, and counted here so the sheet can say so instead of losing them
  /// without a word.
  public var journalLinesOnPreviousDay: Int

  public init(
    previous: Reconciliation, from: Date, to: Date, lines: [ReconciliationLine],
    expected: AmountE4, undatedJournalLines: Int = 0, journalLinesWithoutRate: Int = 0,
    journalLinesOnPreviousDay: Int = 0
  ) {
    self.previous = previous
    self.from = from
    self.to = to
    self.lines = lines
    self.expected = expected
    self.undatedJournalLines = undatedJournalLines
    self.journalLinesWithoutRate = journalLinesWithoutRate
    self.journalLinesOnPreviousDay = journalLinesOnPreviousDay
  }

  public func amount(of term: ReconciliationTerm) -> AmountE4? {
    lines.first { $0.term == term }?.amount
  }

  /// actual − expected: below zero money went missing, above zero some came unrecorded.
  public func difference(actual: AmountE4) -> AmountE4 { actual - expected }
}

public enum ReconciliationError: Error, Equatable, Sendable, CustomStringConvertible {
  /// A total typed in a currency the app has no rate for. The rate is never guessed.
  case missingRate(CurrencyCode)

  public var description: String {
    switch self {
    case .missingRate(let currency): return "There is no rate for \(currency.code)."
    }
  }
}

// MARK: - Rules

/// «How much money do I have in total» against what the books say it should be.
///
/// The first reconciliation is the starting point. Each next one takes the actual total of
/// the previous one and adds what really moved since: operations whose moment falls in
/// (previous, now], and journal lines of debts that moved money without an operation, by
/// their date in (previous day, today]. Everything is in rubles and by date — never by the
/// month income is attributed to: the money arrived when it arrived.
public enum ReconciliationRules {

  /// The reconciliation the next one counts from: the latest by day, then by moment. On a
  /// tie the later one in the list wins, as the book keeps them oldest first.
  public static func latest(_ reconciliations: [Reconciliation]) -> Reconciliation? {
    var latest: Reconciliation?
    for candidate in reconciliations {
      guard let current = latest else {
        latest = candidate
        continue
      }
      if (candidate.date, candidate.reconciledAt ?? .distantPast)
        >= (current.date, current.reconciledAt ?? .distantPast)
      {
        latest = candidate
      }
    }
    return latest
  }

  /// The expected total now, or `nil` when nothing was reconciled yet: the first
  /// reconciliation is the starting point and has nothing to be compared with.
  ///
  /// `calendar` should be the one the ledger was built with. Journal lines of a debt in
  /// another currency are converted at `rubPerUnit`; without a rate they are counted in
  /// `journalLinesWithoutRate` and left out.
  public static func expectation(
    ledger: Ledger, book: PlanningBook, now: Date, calendar: CalendarContext,
    rubPerUnit: [CurrencyCode: Decimal] = [:]
  ) -> ReconciliationExpectation? {
    guard let previous = latest(book.reconciliations) else { return nil }
    let from = previous.reconciledAt ?? calendar.endOfDay(previous.date)
    let includeGoals = book.settings.reconcileIncludesGoalSavings
    let debts = ledger.debtsById
    var sums: [ReconciliationTerm: AmountE4] = [:]

    if from < now {
      let days = DayRange(ledger.calendar.day(of: from), ledger.calendar.day(of: now))
      for row in ledger.rows(in: days) {
        // The day narrows the search; the moment decides. An operation made on the day of
        // the previous reconciliation but before it was already in that total.
        guard let occurredAt = ledger.entry(row.transactionId)?.transaction.occurredAt,
          occurredAt > from, occurredAt <= now
        else { continue }
        // The difference a reconciliation wrote is how the books caught up with the
        // money, not money that moved: counting it would move the total twice.
        if case .reconciliation = row.link { continue }
        record(row, debts: debts, includeGoals: includeGoals, into: &sums)
      }
    }

    let journal = journalMoves(
      book.debtEntries, debts: debts, after: previous.date, through: calendar.day(of: now),
      openings: creditOpenings(ledger.dataset.entries, calendar: ledger.calendar),
      rubPerUnit: rubPerUnit)
    sums[.borrowed, default: .zero] += journal.borrowed
    sums[.lent, default: .zero] += journal.lent

    sums[.previous] = previous.actualTotalRubE4
    let lines = ReconciliationTerm.allCases
      .filter { includeGoals || $0 != .goalSavings }
      .map { ReconciliationLine(term: $0, amount: sums[$0] ?? .zero) }
    return ReconciliationExpectation(
      previous: previous, from: from, to: now, lines: lines,
      expected: AmountE4.sum(lines.map(\.signedAmount)),
      undatedJournalLines: journal.undated, journalLinesWithoutRate: journal.withoutRate,
      journalLinesOnPreviousDay: journal.onPreviousDay)
  }

  /// Puts one part of an operation on the lines it belongs to. Every part lands where its
  /// money went exactly once: my expenses, then — for what never left the pocket — one
  /// correction back; or the parts for others; or a debt payment that is not an expense.
  private static func record(
    _ row: LedgerRow, debts: [UUID: Debt], includeGoals: Bool,
    into sums: inout [ReconciliationTerm: AmountE4]
  ) {
    switch row.kind {
    case .income:
      sums[.income, default: .zero] += row.amountRubE4
      if case .surplus = row.link { sums[.surplus, default: .zero] += row.amountRubE4 }
    case .reimbursement:
      sums[row.debtId == nil ? .returned : .repaidToMe, default: .zero] += row.amountRubE4
    case .expense, .refund:
      sums[.myExpenses, default: .zero] += row.contribution
      // At most one correction per part, so nothing is added back twice.
      if case .shortfall = row.link {
        sums[.shortfalls, default: .zero] += row.contribution
      } else if row.creditDebtId != nil {
        sums[.onCredit, default: .zero] += row.contribution
      } else if includeGoals && row.isGoalContribution {
        sums[.goalSavings, default: .zero] += row.contribution
      }

      // A refund brings money back, so it counts against the line of the money it returns.
      let moved = row.kind == .expense ? row.amountRubE4 : -row.amountRubE4
      // Nothing left the pocket for a part bought on credit, whoever it was for.
      guard row.creditDebtId == nil else { return }
      if row.reimbursable {
        // A written-off part is my expense by the date of the purchase and stays in line 5.
        switch row.reimbursementStatus ?? .expected {
        case .expected:
          sums[.paidForOthersExpected, default: .zero] += moved
          return
        case .returned:
          sums[.paidForOthersReturned, default: .zero] += moved
          return
        case .writtenOff:
          break
        }
      }
      // A payment on a debt that is not an expense still took the money. On a debt owed to
      // me the money went to the person: that is lending.
      guard let debtId = row.debtId, row.contribution.isZero else { return }
      let term: ReconciliationTerm = debts[debtId]?.direction == .owedToMe ? .lent : .debtPayments
      sums[term, default: .zero] += moved
    }
  }

  // MARK: - Journal lines

  private struct JournalMoves {
    var borrowed = AmountE4.zero
    var lent = AmountE4.zero
    var undated = 0
    var withoutRate = 0
    var onPreviousDay = 0
  }

  /// A purchase on credit, as the opening line of its debt would repeat it.
  private struct Opening: Hashable {
    var debtId: UUID
    var day: DateOnly
    var amount: AmountE4
  }

  /// Every purchase on credit, deleted ones too: the app writes the opening line of the
  /// debt without `transaction_id`, and the line outlives the purchase if that is deleted.
  private static func creditOpenings(
    _ entries: [TransactionEntry], calendar: CalendarContext
  ) -> [Opening: Int] {
    var openings: [Opening: Int] = [:]
    for entry in entries where entry.transaction.kind == .expense {
      guard let debtId = entry.transaction.creditDebtId else { continue }
      let key = Opening(
        debtId: debtId, day: calendar.day(of: entry.transaction.occurredAt),
        amount: entry.transaction.amountE4)
      openings[key, default: 0] += 1
    }
    return openings
  }

  /// Money borrowed and lent that only the debt journal knows about. A line written with
  /// an operation is left to that operation, and so is every other kind of line: an offset,
  /// a transfer or an adjustment moves a balance, not my money — which is why the opening
  /// balance of a debt I already had and a debt that grew are adjustments
  /// (`DebtRules.opening`, `DebtRules.growth`), not `borrowed` lines.
  ///
  /// A debt of a purchase on credit never brought money: its `borrowed` lines are the price
  /// of what was bought. The same holds for the opening line of a purchase put on a debt I
  /// already had (a credit card) — it has the debt, the day and the amount of the purchase,
  /// and each purchase explains one such line.
  private static func journalMoves(
    _ lines: [DebtEntry], debts: [UUID: Debt], after start: DateOnly, through end: DateOnly,
    openings: [Opening: Int], rubPerUnit: [CurrencyCode: Decimal]
  ) -> JournalMoves {
    var moves = JournalMoves()
    var openings = openings
    for line in lines where line.kind == .borrowed && line.transactionId == nil {
      guard let debt = debts[line.debtId] else { continue }
      let lent = debt.direction == .owedToMe
      if !lent && debt.origin == .purchase { continue }
      guard let date = line.date else {
        moves.undated += 1
        continue
      }
      guard date >= start, date <= end else { continue }
      if !lent {
        let key = Opening(debtId: debt.id, day: date, amount: line.amountE4)
        if let count = openings[key], count > 0 {
          openings[key] = count - 1
          continue
        }
      }
      guard date > start else {
        moves.onPreviousDay += 1
        continue
      }
      guard let rubles = rubles(line.amountE4, in: debt.currency, rubPerUnit: rubPerUnit) else {
        moves.withoutRate += 1
        continue
      }
      if lent { moves.lent += rubles } else { moves.borrowed += rubles }
    }
    return moves
  }

  private static func rubles(
    _ amount: AmountE4, in currency: CurrencyCode, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    if currency == .rub { return amount }
    guard let rate = rubPerUnit[currency], rate > 0 else { return nil }
    return try? AmountE4(decimal: amount.decimal * rate)
  }

  // MARK: - The actual total

  /// The actual total in rubles from the amounts typed by currency.
  public static func actualTotal(_ amounts: [ReconciliationAmount]) -> AmountE4 {
    AmountE4.sum(amounts.map(\.rubE4))
  }

  /// The amounts the owner typed by currency, each converted at the rate the caller gives
  /// (rubles per one unit, rounded half away from zero to 1/10000). Rubles need no rate.
  /// A currency without a rate — or with one that is not above zero — throws instead of
  /// being guessed. The amounts stay in the order and the split they were typed in.
  public static func breakdown(
    _ amounts: [Money], rubPerUnit: [CurrencyCode: Decimal]
  ) throws -> [ReconciliationAmount] {
    try amounts.map { money in
      if money.currency == .rub {
        return ReconciliationAmount(
          currency: .rub, amountE4: money.amount, rubPerUnit: nil, rubE4: money.amount)
      }
      guard let rate = rubPerUnit[money.currency], rate > 0 else {
        throw ReconciliationError.missingRate(money.currency)
      }
      return ReconciliationAmount(
        currency: money.currency, amountE4: money.amount, rubPerUnit: rate,
        rubE4: try AmountE4(decimal: money.amount.decimal * rate))
    }
  }

  // MARK: - The difference

  /// The operation that records the difference: less money than expected is an expense of the
  /// gap, more is an income; no gap, nothing to write. Both carry the day of the
  /// reconciliation, because that is the only day the gap is known to exist — nothing says
  /// when the money really went.
  ///
  /// Which category the app hands in is the app's business. Until 21.09 it was «Не помню»,
  /// as the specification wrote it; the owner asked for a category of its own, «Сверка», so
  /// that money the books caught up with is not mixed with a purchase he could not place.
  ///
  /// The draft is in rubles, with no description — the app supplies the words — and the
  /// category the app chose (`system`). An expense gets its quality by the usual rules, which
  /// for a category without a history comes from the category (neutral when it has none).
  /// The app writes `OperationLink.reconciliation(id).externalId` to the saved operation, so
  /// the next reconciliation leaves it out.
  public static func differenceDraft(
    difference: AmountE4, occurredAt: Date, expenseCategoryId: UUID,
    incomeCategoryId: UUID, categories: CategoryTree = CategoryTree()
  ) -> TransactionDraft? {
    guard !difference.isZero else { return nil }
    let missing = difference.isNegative
    var draft = TransactionDraft(
      kind: missing ? .expense : .income, occurredAt: occurredAt, currency: .rub,
      amount: difference.magnitude)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = missing ? expenseCategoryId : incomeCategoryId
    draft.parts[0].categorySource = .system
    if missing {
      let decision = QualityResolver.resolve(
        categoryId: expenseCategoryId, categories: categories)
      draft.parts[0].quality = decision.quality
      draft.parts[0].qualitySource = decision.source
    }
    return draft
  }

  // MARK: - Reminder

  /// Is it time to reconcile? Always before the first one; afterwards once more than
  /// `everyDays` days have passed since the day of the last one.
  public static func isDue(last: Reconciliation?, today: DateOnly, everyDays: Int) -> Bool {
    guard let last else { return true }
    return last.date.days(to: today) > everyDays
  }
}
