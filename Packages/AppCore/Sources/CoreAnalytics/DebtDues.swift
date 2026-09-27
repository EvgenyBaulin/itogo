import CoreAccounting
import CoreKit
import Foundation

/// Which monthly dues of a debt are paid: the one rule the Debts screen, the free sum, the
/// planned month, the forecast of the month, the reminders and the 7-day card share.
///
/// Every payment closes the earliest due still unpaid. Counted from the start of the debt, the
/// first `paidCount` dues are paid, whatever months the payments were made in: a payment made
/// on 28 September «for October» pays October, a month missed stays owed after a later
/// payment, and a small extra payment moves the whole schedule on.
public struct DebtDueState: Hashable, Sendable {
  public var debtId: UUID
  /// The first due the debt owes — its payment day in the first month that owes, clipped to
  /// the length of the month; `nil` for a debt without a payment day.
  public var firstDue: DateOnly?
  /// The payments that count, dated from the start of the debt through the day asked about.
  public var paidCount: Int
  /// Something is still owed on the debt: it is open and its journal leaves money owed — or
  /// the journal never recorded what was owed (no line ever raised it), so it has no balance
  /// to go by and owes as it always did. Only then is a due anything to pay.
  public var owes: Bool
  /// The day of the month the debt is paid on.
  public let paymentDay: Int

  public init(debtId: UUID, firstDue: DateOnly?, paidCount: Int, owes: Bool, paymentDay: Int) {
    self.debtId = debtId
    self.firstDue = firstDue
    self.paidCount = max(0, paidCount)
    self.owes = owes
    self.paymentDay = paymentDay
  }

  /// A debt with nothing due: no payment day, nothing owed.
  public static func none(of debtId: UUID) -> DebtDueState {
    DebtDueState(debtId: debtId, firstDue: nil, paidCount: 0, owes: false, paymentDay: 0)
  }

  /// Dues looked at, at most: a hundred years of months.
  static let limit = 1_200

  /// The due of index `index`, 0 the first: the payment day of the month `index` months after
  /// the first one, clipped to its length. Without a first due, the payment day of no month:
  /// 1 January 1970.
  public func due(_ index: Int) -> DateOnly {
    guard let firstDue else { return DateOnly(year: 1970, month: 1, day: 1) }
    let month = firstDue.monthKey.adding(months: max(0, index))
    return DebtDueState.payday(paymentDay, in: month)
  }

  /// The payment day in `month`, clipped to its length: the 31st of September is its 30th.
  public static func payday(_ day: Int, in month: MonthKey) -> DateOnly {
    DateOnly(year: month.year, month: month.month, day: min(max(1, day), month.dayCount))
  }

  /// The earliest due nothing paid yet, while something is owed; it may lie in an earlier
  /// month — overdue.
  public var firstUnpaid: DateOnly? {
    guard owes, firstDue != nil else { return nil }
    return due(paidCount)
  }

  /// The earliest unpaid due and every one after it, through `through`.
  public func unpaid(through: DateOnly) -> [DateOnly] {
    guard owes, firstDue != nil else { return [] }
    var result: [DateOnly] = []
    var index = paidCount
    while result.count < Self.limit {
      let day = due(index)
      guard day <= through else { break }
      result.append(day)
      index += 1
    }
    return result
  }

  /// The unpaid dues before `today`.
  public func overdue(today: DateOnly) -> [DateOnly] {
    unpaid(through: today.adding(days: -1))
  }

  /// Whether the due of `day` — one of the debt's dues — is owed and nothing paid it yet: it is
  /// not before the first due and not before the first unpaid one, and something is owed.
  public func isUnpaid(_ day: DateOnly) -> Bool {
    guard let first = firstUnpaid else { return false }
    return day >= first
  }

  /// Whether the due of `day` — one of the debt's dues — is paid: it is one the debt owes
  /// and comes before the first unpaid one; with nothing owed any more every due is.
  public func isPaid(_ day: DateOnly) -> Bool {
    guard let firstDue, day >= firstDue else { return false }
    guard owes else { return true }
    return day < due(paidCount)
  }
}

/// The dues of the debts, worked out once for all of them.
public enum DebtDues {
  /// Every debt's state as of `today`.
  ///
  /// * The schedule starts on `allocationStart` of the debt's journal; the first due is the
  ///   payment day of the first month that owes (`DebtStart.firstMonth`: the month it began, or
  ///   the next one when that month's payment day came before the start — or on it, for
  ///   something bought on credit). A debt whose journal has no day at all starts with this
  ///   month: its first due is this month's payment day, and only payments of this month on
  ///   count — the month rule it always had.
  /// * The payments are the live operations that point at the debt, once each — not those the
  ///   journal wrote as an «Offset» or as more money borrowed (`DebtRules.notPayments`) — and the
  ///   journal's `payment` lines that belong to no such operation (a payment recorded on the
  ///   debt card alone, or «Уже списано до сверки»). Only those dated from the start through
  ///   `paymentsThrough` — today when not said — count: a payment typed ahead pays nothing
  ///   before its day. The plan of the month's end asks with a later day.
  public static func states(
    debts: [Debt], ledger: Ledger, journal: [DebtEntry], today: DateOnly,
    paymentsThrough: DateOnly? = nil
  ) -> [UUID: DebtDueState] {
    guard !debts.isEmpty else { return [:] }
    let wanted = Set(debts.map(\.id))
    let through = paymentsThrough ?? today
    let calendar = ledger.calendar
    let notPayments = DebtRules.notPayments(journal)

    var journals: [UUID: [DebtEntry]] = [:]
    for line in journal where wanted.contains(line.debtId) {
      journals[line.debtId, default: []].append(line)
    }
    // The operations that pay each debt, by day.
    var operationDays: [UUID: [(transactionId: UUID, day: DateOnly)]] = [:]
    for row in ledger.rows where row.isFirstPart {
      guard let debtId = row.debtId, wanted.contains(debtId),
        !notPayments.contains(row.transactionId)
      else { continue }
      operationDays[debtId, default: []].append((row.transactionId, row.day))
    }

    var result: [UUID: DebtDueState] = [:]
    for debt in debts {
      let lines = journals[debt.id] ?? []
      let opened = lines.contains { $0.amountE4.raw > 0 }
      let owes = !debt.closed && (!opened || DebtRules.balance(entries: lines).raw > 0)
      guard let paymentDay = debt.paymentDay, paymentDay >= 1 else {
        result[debt.id] = DebtDueState(
          debtId: debt.id, firstDue: nil, paidCount: 0, owes: owes, paymentDay: 0)
        continue
      }
      let start = allocationStart(of: lines, calendar: calendar)
      let firstDue: DateOnly
      let countsFrom: DateOnly
      if let start, let month = DebtStart.firstMonth(of: debt, startsOn: start, calendar: calendar)
      {
        firstDue = DebtDueState.payday(paymentDay, in: month)
        countsFrom = start
      } else {
        firstDue = DebtDueState.payday(paymentDay, in: today.monthKey)
        countsFrom = today.monthKey.firstDay
      }
      func counts(_ day: DateOnly) -> Bool { day >= countsFrom && day <= through }

      let operations = operationDays[debt.id] ?? []
      let paidByOperation = Set(operations.map(\.transactionId))
      var paid = operations.filter { counts($0.day) }.count
      for line in lines where line.kind == .payment {
        if let transactionId = line.transactionId, paidByOperation.contains(transactionId) {
          continue
        }
        guard let day = line.date ?? line.occurredAt.map(calendar.day(of:)), counts(day) else {
          continue
        }
        paid += 1
      }
      result[debt.id] = DebtDueState(
        debtId: debt.id, firstDue: firstDue, paidCount: paid, owes: owes,
        paymentDay: paymentDay)
    }
    return result
  }

  /// The day the schedule of a debt starts: the day it began (`DebtStart.day`), moved to the
  /// day after the latest day its balance fell to zero or below when it grew again afterwards —
  /// a debt paid off and taken again, or a credit card kept as a debt, starts a new schedule
  /// instead of letting old payments pay new dues. Lines without a day come first; the
  /// balance is read at the end of each day. `nil` for a journal with no day at all.
  public static func allocationStart(
    of journal: [DebtEntry], calendar: CalendarContext
  ) -> DateOnly? {
    guard var start = DebtStart.day(of: journal, calendar: calendar) else { return nil }
    var undated = AmountE4.zero
    var byDay: [DateOnly: AmountE4] = [:]
    for line in journal {
      if let day = line.date ?? line.occurredAt.map(calendar.day(of:)) {
        byDay[day, default: .zero] += line.amountE4
      } else {
        undated += line.amountE4
      }
    }
    var balance = undated
    var lastZero: DateOnly?
    for day in byDay.keys.sorted() {
      balance += byDay[day] ?? .zero
      if balance.raw <= 0 { lastZero = day }
    }
    if balance.raw > 0, let lastZero { start = max(start, lastZero.adding(days: 1)) }
    return start
  }
}
