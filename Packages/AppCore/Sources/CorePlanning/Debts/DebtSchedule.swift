import CoreAnalytics
import CoreKit
import Foundation

/// When the next payment of a debt is due (the card shows the day of the
/// monthly payment, and the reminders fire from it).
public enum DebtSchedule {

  /// The day of the next payment, or `nil` for a debt without a payment day and for a closed
  /// one.
  ///
  /// * The payment day is clipped to the length of the month: a debt paid on the 31st is due
  ///   on 30 September and on 28 (29) February.
  /// * Once this month's payment is made, the next one is next month's.
  /// * A payment not made yet stays on this month's day even after that day has passed: it
  ///   is overdue, not skipped, so the reminder keeps pointing at it.
  public static func nextPaymentDate(
    of debt: Debt, today: DateOnly, paidThisMonth: Bool, calendar: CalendarContext
  ) -> DateOnly? {
    guard !debt.closed, let paymentDay = debt.paymentDay, paymentDay >= 1 else { return nil }
    let month = paidThisMonth ? today.monthKey.next : today.monthKey
    return DateOnly(
      year: month.year, month: month.month,
      day: min(paymentDay, calendar.daysInMonth(month)))
  }

  /// Was the debt paid in the calendar month of `today`?
  ///
  /// It was when an operation dated in that month points at the debt (`debt_id`) — the rule
  /// the forecast uses for planned payments (`PlannedPayments`) — or when the journal has a
  /// `payment` line dated in that month, which covers a payment recorded on the card alone.
  /// The whole month counts, a payment entered ahead with a later date included. An
  /// «Offset» is not a payment: its operation points at the debt too, but its journal line
  /// is an `offset`, so it is left out.
  public static func isPaid(
    _ debt: Debt, inMonthOf today: DateOnly, ledger: Ledger, journal: [DebtEntry]
  ) -> Bool {
    isPaid(
      debt.id, in: today.monthKey,
      paidByOperation: debtsPaid(in: today.monthKey, ledger: ledger, journal: journal),
      journal: journal)
  }

  /// The debts an operation dated in `month` points at, found once for the whole section.
  /// Operations the journal has an `offset` line for («Offset») or a `borrowed` line for
  /// (money taken or lent more through the entry line) are not payments and are skipped.
  /// Payments typed in the entry line may have no journal line at all and still count.
  static func debtsPaid(in month: MonthKey, ledger: Ledger, journal: [DebtEntry]) -> Set<UUID> {
    let offsets = notPayments(journal)
    var paid: Set<UUID> = []
    for row in ledger.rows(in: Period.month(month).range) {
      guard let debtId = row.debtId, !offsets.contains(row.transactionId) else { continue }
      paid.insert(debtId)
    }
    return paid
  }

  /// The operations that point at a debt without paying it: the journal wrote them as an
  /// `offset` or as more `borrowed`.
  public static func notPayments(_ journal: [DebtEntry]) -> Set<UUID> {
    Set(
      journal.lazy.filter { $0.kind == .offset || $0.kind == .borrowed }
        .compactMap(\.transactionId))
  }

  static func isPaid(
    _ debtId: UUID, in month: MonthKey, paidByOperation: Set<UUID>, journal: [DebtEntry]
  ) -> Bool {
    paidByOperation.contains(debtId)
      || journal.contains { entry in
        entry.debtId == debtId && entry.kind == .payment && entry.date?.monthKey == month
      }
  }
}
