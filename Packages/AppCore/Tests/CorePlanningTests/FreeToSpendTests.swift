import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Free to spend: the lines, the window and the daily guide")
struct FreeToSpendTests: SavingsFixtures {
  let today = DateOnly(year: 2026, month: 9, day: 19)

  /// 80 000 received + 20 000 expected − 45 000 spent − 6 000 scheduled − 10 000 debts −
  /// 5 000 goal reserve; 1 500 paid for others is only listed.
  func inputs(
    until: DateOnly? = nil, spent: String = "45000", reserve: Bool = true
  ) -> FreeToSpendInputs {
    FreeToSpendInputs(
      today: today, until: until, incomeReceived: rub("80000"), expectedIncome: rub("20000"),
      spentThisMonth: rub(spent), plannedScheduled: rub("6000"), plannedDebts: rub("10000"),
      goalReserve: rub("5000"), reserveEnabled: reserve, forOthersUntil: rub("1500"))
  }

  /// free = 100 000 − 66 000 = 34 000; 12 days from the 19th through the 30th, today
  /// included: 34 000 ÷ 12 = 2 833.3333.
  @Test func linesAddUpToTheFreeSumAndTheGuideSpreadsIt() {
    let result = FreeToSpend(inputs())
    #expect(
      result.lines.map(\.key) == [
        "planning.free.income", "planning.free.expected", "planning.free.spent",
        "planning.free.scheduled", "planning.free.debts", "planning.free.goalReserve",
      ])
    #expect(result.lines.map(\.sign) == [.plus, .plus, .minus, .minus, .minus, .minus])
    #expect(
      result.lines.map(\.amount) == ["80000", "20000", "45000", "6000", "10000", "5000"].map(rub))
    #expect(result.free == rub("34000"))
    #expect(AmountE4.sum(result.lines.map(\.signedAmount)) == result.free)
    #expect(result.until == date("2026-09-30"))
    #expect(result.days == 12)
    #expect(result.dailyGuide == rub("2833.3333"))
    #expect(
      result.info == [
        FreeToSpendLine(key: "planning.free.forOthers", sign: .minus, amount: rub("1500"))
      ])
  }

  /// Until the 25th: 7 days, 34 000 ÷ 7 = 4 857.142857… → 4 857.1429. A day past the month
  /// is clipped to its end, a day before today to today.
  @Test func theWindowIsClippedToTheMonth() {
    let untilThe25th = FreeToSpend(inputs(until: date("2026-09-25")))
    #expect(untilThe25th.days == 7)
    #expect(untilThe25th.dailyGuide == rub("4857.1429"))
    let pastTheMonth = FreeToSpend(inputs(until: date("2026-10-05")))
    #expect(pastTheMonth.until == date("2026-09-30"))
    #expect(pastTheMonth.days == 12)
    let beforeToday = FreeToSpend(inputs(until: date("2026-09-10")))
    #expect(beforeToday.until == today)
    #expect(beforeToday.days == 1)
    #expect(beforeToday.dailyGuide == rub("34000"))
  }

  /// Overspent: 100 000 − (110 000 + 6 000 + 10 000 + 5 000) = −31 000, and the guide is 0.
  @Test func aNegativeFreeSumGivesNoDailyGuide() {
    let result = FreeToSpend(inputs(spent: "110000"))
    #expect(result.free == rub("-31000"))
    #expect(result.dailyGuide == .zero)
  }

  /// With the reserve off its line is gone and the 5 000 are free: 39 000.
  @Test func theReserveSwitchedOffLeavesItsLineOut() {
    let result = FreeToSpend(inputs(reserve: false))
    #expect(!result.lines.contains { $0.key == FreeToSpend.Key.goalReserve })
    #expect(result.free == rub("39000"))
    #expect(AmountE4.sum(result.lines.map(\.signedAmount)) == result.free)
  }

  @Test func nothingForOthersListsNoInfo() {
    var plain = inputs()
    plain.forOthersUntil = .zero
    #expect(FreeToSpend(plain).info.isEmpty)
  }

  /// Car: plan 10 000, 4 000 in. Flat: plan 5 000, 7 000 in — nothing left. Trip: plan
  /// 3 000, 3 000 in and 1 000 taken back. Boat: no plan. Old: archived. Reserve: 6 000 +
  /// 1 000 = 7 000 — the same figure the forecast plans for the goals.
  @Test func theGoalReserveIsWhatThePlansStillAsk() {
    var book = SavingsBook()
    let car = Goal(
      id: uid(500), name: "Car", targetE4: rub("100000"), monthlyPlanE4: rub("10000"),
      subcategoryId: book.carSubcategory)
    let flat = Goal(
      id: uid(501), name: "Flat", targetE4: rub("100000"), monthlyPlanE4: rub("5000"))
    let trip = Goal(
      id: uid(502), name: "Trip", targetE4: rub("100000"), monthlyPlanE4: rub("3000"))
    let boat = Goal(id: uid(503), name: "Boat", targetE4: rub("100000"))
    let old = Goal(
      id: uid(504), name: "Old", targetE4: rub("100000"), monthlyPlanE4: rub("9000"),
      archived: true)
    // Filed under the Car subcategory without a goal: still the car's.
    book.contribute("2026-09-02", "4000", goal: nil)
    // Last month's contribution does not reduce this month's plan.
    book.contribute("2026-08-30", "10000", goal: car.id)
    book.contribute("2026-09-03", "7000", goal: flat.id, category: book.goalsRoot)
    book.contribute("2026-09-04", "3000", goal: trip.id, category: book.goalsRoot)
    book.withdraw("2026-09-05", "1000", goal: trip.id, category: book.goalsRoot)
    let goals = [car, flat, trip, boat, old]
    book.goals = goals
    let ledger = book.ledger

    let reserve = FreeToSpend.goalReserve(goals: goals, ledger: ledger, today: today)
    #expect(reserve == rub("7000"))
    #expect(reserve == PlannedPayments(ledger: ledger, today: today).goals)
  }

  /// «Несделанный плановый взнос этого месяца» is never more than the plan: with
  /// a plan of 3 000 and 5 000 taken out of the savings of earlier months, the reserve is the
  /// 3 000 still to put in, not 8 000 — putting the 5 000 back is no plan of this month.
  /// Taking back part of this month's own contribution still unmakes that part.
  @Test(arguments: [
    (["-5000"], "3000"),
    (["2000", "-5000"], "3000"),
    (["3000", "-1000"], "1000"),
    (["1000"], "2000"),
  ])
  func theGoalReserveIsNeverMoreThanThePlan(moves: [String], reserve: String) {
    var book = SavingsBook()
    let trip = Goal(
      id: uid(502), name: "Trip", targetE4: rub("100000"), monthlyPlanE4: rub("3000"))
    book.contribute("2026-08-10", "20000", goal: trip.id, category: book.goalsRoot)
    for (index, move) in moves.enumerated() {
      let day = "2026-09-0\(index + 2)"
      if move.hasPrefix("-") {
        book.withdraw(day, String(move.dropFirst()), goal: trip.id, category: book.goalsRoot)
      } else {
        book.contribute(day, move, goal: trip.id, category: book.goalsRoot)
      }
    }
    book.goals = [trip]
    let ledger = book.ledger
    let expected = rub(reserve)
    #expect(FreeToSpend.goalReserve(goals: [trip], ledger: ledger, today: today) == expected)
    #expect(
      PlannedMonth.build(ledger: ledger, book: .empty, today: today).goals == expected)
    #expect(PlannedPayments(ledger: ledger, today: today).goals == expected)
  }
}
