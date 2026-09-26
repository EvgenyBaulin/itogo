import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A debt owes nothing before it began: a phone bought in parts on 15 September, paid on the
/// 5th, first owes on 5 October. The free sum already knows it; every other screen that names
/// the next payment of a debt must say the same, or the Overview calls a payment overdue that
/// the free sum does not hold back.
@Suite("A debt owes nothing before it began")
struct DebtStartTests {
  typealias Fx = CashFx

  static let phone = Debt(
    id: CashFx.id(304), direction: .iOwe, type: .installment, name: "Phone in parts",
    monthlyPaymentE4: CashFx.money("3000"), paymentDay: 5, paymentsAreExpenses: false,
    origin: .purchase)

  func book(startedOn start: String, dated: Bool = true) -> CashFx {
    var fx = Fx()
    fx.debts = [Self.phone]
    fx.debtEntries = [
      DebtEntry(
        debtId: Self.phone.id, date: dated ? Fx.day(start) : nil,
        amountE4: Fx.money("30000"), kind: .borrowed,
        occurredAt: dated ? nil : Fx.at(start, 12))
    ]
    return fx
  }

  /// Bought on the 15th, today the 19th: the next payment is 5 October — on the Debts screen,
  /// in the 7-day card (nothing within a week) and in the reminders (nothing), as in the free
  /// sum.
  @Test func theNextPaymentOfADebtBoughtAfterItsDayIsNextMonth() {
    let fx = book(startedOn: "2026-09-15")
    let snapshot = fx.snapshot()
    let line = snapshot.debts.iOwe.first
    #expect(line?.nextPayment == Fx.day("2026-10-05"))
    #expect(!snapshot.upcoming.contains { $0.kind == .debt })
    #expect(!snapshot.reminders.contains { $0.kind == .debtPayment })
    #expect(snapshot.planned.debtsDueByToday == .zero)
    #expect(fx.plan(until: "2026-09-30").debts == .zero)
    #expect(fx.plan(until: "2026-10-31").debts == Fx.money("3000"))
  }

  /// Three days before 5 October the reminder comes and the 7-day card shows it, not overdue.
  @Test func itIsRemindedBeforeItsFirstDay() {
    let fx = book(startedOn: "2026-09-15")
    let snapshot = fx.snapshot(today: Fx.day("2026-10-02"), now: Fx.at("2026-10-02", 12))
    #expect(snapshot.debts.iOwe.first?.nextPayment == Fx.day("2026-10-05"))
    #expect(
      snapshot.upcoming.filter { $0.kind == .debt }.map(\.due) == [Fx.day("2026-10-05")])
    #expect(snapshot.upcoming.allSatisfy { !$0.isOverdue })
    #expect(
      snapshot.reminders.filter { $0.kind == .debtPayment }.map(\.due) == [Fx.day("2026-10-05")])
  }

  /// A debt that began on its payment day owes on that very day — the careful reading — and
  /// one that began earlier is overdue as before. A journal line with only a moment counts by
  /// the day of that moment.
  @Test func aDebtThatBeganByItsDayOwesThisMonth() {
    for (start, dated) in [("2026-09-05", true), ("2026-08-20", true), ("2026-09-03", false)] {
      let snapshot = book(startedOn: start, dated: dated).snapshot()
      #expect(snapshot.debts.iOwe.first?.nextPayment == Fx.day("2026-09-05"), "\(start)")
      #expect(
        snapshot.upcoming.filter { $0.kind == .debt }.map(\.isOverdue) == [true], "\(start)")
      #expect(
        snapshot.reminders.filter { $0.kind == .debtPayment }.map(\.due)
          == [Fx.day("2026-09-05")], "\(start)")
    }
  }

  /// A debt with an empty journal has nothing to say when it began: this month's day, as
  /// before.
  @Test func aDebtWithoutAJournalKeepsThisMonthsDay() {
    var fx = Fx()
    fx.debts = [Self.phone]
    let snapshot = fx.snapshot()
    #expect(snapshot.debts.iOwe.first?.nextPayment == Fx.day("2026-09-05"))
  }

  /// The date alone decides: `DebtSchedule.nextPaymentDate` given the day the debt began.
  @Test func theScheduleGivenTheStart() {
    func next(_ today: String, paid: Bool, start: String?) -> DateOnly? {
      DebtSchedule.nextPaymentDate(
        of: Self.phone, today: Fx.day(today), paidThisMonth: paid, calendar: .utc,
        startsOn: start.map(Fx.day))
    }
    #expect(next("2026-09-19", paid: false, start: "2026-09-15") == Fx.day("2026-10-05"))
    #expect(next("2026-09-19", paid: false, start: "2026-09-05") == Fx.day("2026-09-05"))
    #expect(next("2026-09-19", paid: false, start: nil) == Fx.day("2026-09-05"))
    // Paid in the month it began, which owed nothing: that payment pays 5 October, the first
    // due (`DebtStartPrepaymentTests`).
    #expect(next("2026-09-19", paid: true, start: "2026-09-15") == Fx.day("2026-11-05"))
    // Written today for a debt that begins in November: its first payment is 5 December.
    #expect(next("2026-09-19", paid: false, start: "2026-11-10") == Fx.day("2026-12-05"))
    // The 31st of a debt that began on 30 September: 31 October, not 30 September.
    var monthEnd = Self.phone
    monthEnd.paymentDay = 31
    #expect(
      DebtSchedule.nextPaymentDate(
        of: monthEnd, today: Fx.day("2026-09-30"), paidThisMonth: false, calendar: .utc,
        startsOn: Fx.day("2026-09-30")) == Fx.day("2026-09-30"))
    #expect(
      DebtSchedule.nextPaymentDate(
        of: monthEnd, today: Fx.day("2026-10-01"), paidThisMonth: false, calendar: .utc,
        startsOn: Fx.day("2026-10-01")) == Fx.day("2026-10-31"))
  }
}

extension DebtStartTests {
  /// A loan taken on the 15th, its payments expenses on the 5th: this month's 5th owed
  /// nothing, so «can save» does not count it as a payment still due by today.
  @Test func aLoanTakenAfterItsDayIsNoPaymentDueByToday() {
    var fx = Fx()
    let loan = Debt(
      id: Fx.id(305), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: Fx.money("8000"), paymentDay: 5)
    fx.debts = [loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-09-15"), amountE4: Fx.money("80000"),
        kind: .borrowed)
    ]
    let snapshot = fx.snapshot()
    #expect(snapshot.planned.debtsDueByToday == .zero)
    #expect(!snapshot.planned.items.contains { $0.kind == .debt })
    let october = PlannedMonth.build(
      ledger: fx.ledger, book: fx.book, today: Fx.today, until: Fx.day("2026-10-31"),
      rubPerUnit: fx.rubPerUnit)
    #expect(october.items.filter { $0.kind == .debt }.map(\.due) == [Fx.day("2026-10-05")])

    // Taken on the 1st, the 5th was owed and is still due by today.
    fx.debtEntries[0].date = Fx.day("2026-09-01")
    #expect(fx.snapshot().planned.debtsDueByToday == Fx.money("8000"))
  }
}

extension DebtStartTests {
  /// The forecast of the month (`PlannedPayments`, CoreAnalytics) and the planned month read
  /// the start of a debt by one rule: for a loan of 8 000 on the 25th begun on any of these
  /// days, paid or not in the month it began, on any of these todays, the two figures of the
  /// debt are one.
  @Test func theForecastAndThePlannedMonthAgreeOnWhenADebtBegan() {
    let loan = Debt(
      id: Fx.id(306), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: Fx.money("8000"), paymentDay: 25)
    let starts = [
      "2026-08-30", "2026-09-01", "2026-09-25", "2026-09-26", "2026-09-28", "2026-10-10",
      "2026-11-10",
    ]
    for start in starts {
      for paidOn in [nil, "2026-09-27", "2026-10-02"] as [String?] {
        var fx = Fx()
        fx.debts = [loan]
        fx.debtEntries = [
          DebtEntry(
            debtId: loan.id, date: Fx.day(start), amountE4: Fx.money("80000"), kind: .borrowed)
        ]
        if let paidOn {
          fx.debtEntries.append(
            DebtEntry(
              debtId: loan.id, date: Fx.day(paidOn), amountE4: Fx.money("-8000"),
              kind: .payment))
        }
        let ledger = fx.ledger
        for today in ["2026-09-19", "2026-09-29", "2026-10-03", "2026-11-03"].map(Fx.day) {
          let month = PlannedMonth.build(
            ledger: ledger, book: fx.book, today: today, rubPerUnit: fx.rubPerUnit)
          let forecast = PlannedPayments(ledger: ledger, today: today, rubPerUnit: fx.rubPerUnit)
          #expect(
            forecast.debts == month.debts, "start \(start), paid \(paidOn ?? "-"), \(today.iso)")
        }
      }
    }
  }
}
