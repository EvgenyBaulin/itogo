import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// «Это было до сверки в 14:05?» at the edges of a day, and with two counts on one day. The
/// answer puts the operation before or after the count — and never on another day: the day is
/// the one the owner typed, and it decides the month the operation is spent in.
@Suite("Before the count: the edges of a day and two counts")
struct BeforeTheCountEdgeTests {
  typealias Fx = CashFx

  static let mainRub = BalanceKey(accountId: CashFx.main, currency: .rub)
  static let cardRub = BalanceKey(accountId: CashFx.card, currency: .rub)

  func balance(_ fx: CashFx, _ key: BalanceKey) -> AmountE4? {
    ReconciliationPropertyTests.Scenario.balances(fx, now: Fx.at("2026-10-05", 0))[key]?.amountE4
  }

  /// Counted at 00:00:00 on 1 October; 300 spent «today» saved at 10:00, and the owner says it
  /// was before the count. It stays an operation of 1 October — of October, not of September —
  /// and inside the count: the balance does not move.
  @Test func aYesAtMidnightKeepsTheDay() {
    var fx = Fx()
    let count = Fx.at("2026-10-01", 0)
    fx.count([(Fx.main, .rub, "10000")], at: count)
    let occurredAt = Fx.at("2026-10-01", 10)
    let asked = AccountReconciliation.beforeTheCount(
      occurredAt: occurredAt, savedAt: occurredAt, keys: [Self.mainRub],
      balances: ReconciliationPropertyTests.Scenario.balances(fx, now: occurredAt),
      calendar: .utc)
    #expect(asked == count)
    let stamp = AccountReconciliation.stamped(
      occurredAt: occurredAt, count: count, wasBefore: true, calendar: .utc)
    #expect(CalendarContext.utc.day(of: stamp) == Fx.day("2026-10-01"))
    #expect(stamp <= count)
    fx.add(.expense, "300", at: stamp)
    #expect(balance(fx, Self.mainRub) == Fx.money("10000"))
  }

  /// Counted at 23:59:59 on 30 September; 300 dated that day, saved a few seconds later, and
  /// the owner says it was after the count. It stays an operation of 30 September and after
  /// the count: the balance moves by it.
  @Test func aNoAtTheLastSecondKeepsTheDay() {
    var fx = Fx()
    let count = Fx.at("2026-09-30", 23, 59).addingTimeInterval(59)
    fx.count([(Fx.main, .rub, "10000")], at: count)
    let occurredAt = CalendarContext.utc.noon(of: Fx.day("2026-09-30"))
    let savedAt = count.addingTimeInterval(20)
    let asked = AccountReconciliation.beforeTheCount(
      occurredAt: occurredAt, savedAt: savedAt, keys: [Self.mainRub],
      balances: ReconciliationPropertyTests.Scenario.balances(fx, now: savedAt), calendar: .utc)
    #expect(asked == count)
    let stamp = AccountReconciliation.stamped(
      occurredAt: occurredAt, count: count, wasBefore: false, calendar: .utc)
    #expect(CalendarContext.utc.day(of: stamp) == Fx.day("2026-09-30"))
    #expect(stamp > count)
    fx.add(.expense, "300", at: stamp)
    #expect(balance(fx, Self.mainRub) == Fx.money("9700"))
  }

  /// Anywhere inside the day the answer is a second before or after the count, as before.
  @Test func insideTheDayTheAnswerIsASecondAway() {
    let count = Fx.at("2026-09-19", 14, 5)
    let typed = Fx.at("2026-09-19", 15)
    #expect(
      AccountReconciliation.stamped(
        occurredAt: typed, count: count, wasBefore: true, calendar: .utc)
        == count.addingTimeInterval(-1))
    #expect(
      AccountReconciliation.stamped(
        occurredAt: Fx.at("2026-09-19", 12), count: count, wasBefore: false, calendar: .utc)
        == count.addingTimeInterval(1))
    // Typed after the count already, «Нет» keeps the moment typed.
    #expect(
      AccountReconciliation.stamped(
        occurredAt: typed, count: count, wasBefore: false, calendar: .utc) == typed)
  }

  /// A transfer Main → Card, Main counted at 09:00 and Card at 13:00, dated «вчера» (noon) and
  /// saved after both. The core asks about the earlier count only; its «Нет» alone puts the
  /// transfer at noon — after Main's count but inside Card's, so Card's balance does not move.
  /// The transfer sheet therefore asks about every count of the day in turn.
  @Test func aNoAboutTheEarlierOfTwoCountsLandsInsideTheLater() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-09-18", 9))
    fx.count([(Fx.card, .rub, "500")], at: Fx.at("2026-09-18", 13))
    let transfer = Transfer(
      occurredAt: CalendarContext.utc.noon(of: Fx.day("2026-09-18")), fromAccountId: Fx.main,
      fromCurrency: .rub, fromAmountE4: Fx.money("100"), toAccountId: Fx.card,
      toCurrency: .rub, toAmountE4: Fx.money("100"))
    let asked = AccountReconciliation.beforeTheCount(
      occurredAt: transfer.occurredAt, savedAt: Fx.now,
      keys: AccountReconciliation.movedKeys(of: transfer),
      balances: ReconciliationPropertyTests.Scenario.balances(fx, now: Fx.now), calendar: .utc)
    #expect(asked == Fx.at("2026-09-18", 9))
    var stamped = transfer
    stamped.occurredAt = AccountReconciliation.stamped(
      occurredAt: transfer.occurredAt, count: Fx.at("2026-09-18", 9), wasBefore: false,
      calendar: .utc)
    #expect(stamped.occurredAt == transfer.occurredAt)
    fx.transfers = [stamped]
    #expect(balance(fx, Self.mainRub) == Fx.money("900"))
    #expect(balance(fx, Self.cardRub) == Fx.money("500"))
  }
}
