import CoreAccounting
import CoreKit
import CorePlanning
import Foundation
import Testing

@Suite("Funding: what each payment method needs this month, by currency")
struct FundingTests {
  typealias Fx = SchedFx

  let cardOne = SchedFx.id(31)
  let cardTwo = SchedFx.id(32)
  let tenge = CurrencyCode("KZT")

  /// September 2026, today the 19th. Two cards, four currencies:
  ///
  /// * card 1 — 500 ₽ on the 10th, already paid (500 ₽ from card 1); 10 $ on the 25th;
  ///   5 000 ₸ weekly from the 21st: the 21st and the 28th, 10 000 ₸;
  /// * card 2 — 1 000 ₽ on the 30th; 15 $ with a price of 20 $ since 1 September, on the
  ///   20th; 50 € yearly on 1 September, paid on 30 August with 52 € from card 1 — card 1
  ///   settled it, so card 2 is not asked for it again;
  /// * an inactive payment and a September date that was skipped need nothing.
  @Test func twoMethodsAndTheirCurrencies() {
    let internet = ScheduledPayment(
      id: Fx.id(1), name: "Internet", amountE4: Fx.money("500"), paymentMethodId: cardOne,
      day: 10, nextDate: Fx.day("2026-10-10"))
    let music = ScheduledPayment(
      id: Fx.id(2), name: "Music", amountE4: Fx.money("10"), currency: .usd,
      paymentMethodId: cardOne, day: 25, nextDate: Fx.day("2026-09-25"))
    let lessons = ScheduledPayment(
      id: Fx.id(3), name: "Lessons", amountE4: Fx.money("5000"), currency: tenge,
      paymentMethodId: cardOne, freq: .weekly, nextDate: Fx.day("2026-09-21"))
    let phone = ScheduledPayment(
      id: Fx.id(4), name: "Phone", amountE4: Fx.money("1000"), paymentMethodId: cardTwo,
      day: 30, nextDate: Fx.day("2026-09-30"))
    let video = ScheduledPayment(
      id: Fx.id(5), name: "Video", kind: .subscription, amountE4: Fx.money("15"),
      currency: .usd, paymentMethodId: cardTwo, day: 20, nextDate: Fx.day("2026-09-20"))
    let domain = ScheduledPayment(
      id: Fx.id(6), name: "Domain", amountE4: Fx.money("50"), currency: .eur,
      paymentMethodId: cardTwo, freq: .yearly, day: 1, month: 9,
      nextDate: Fx.day("2027-09-01"))
    let inactive = ScheduledPayment(
      id: Fx.id(7), name: "Old", amountE4: Fx.money("777"), paymentMethodId: cardTwo, day: 22,
      nextDate: Fx.day("2026-09-22"), active: false)
    let skipped = ScheduledPayment(
      id: Fx.id(8), name: "Skipped", amountE4: Fx.money("300"), paymentMethodId: cardTwo,
      day: 5, nextDate: Fx.day("2026-10-05"))
    let book = PlanningBook(
      scheduled: [internet, music, lessons, phone, video, domain, inactive, skipped],
      prices: [
        SubscriptionPrice(paymentId: video.id, date: Fx.day("2026-09-01"), amountE4: Fx.money("20"))
      ])
    let ledger = Fx.ledger(
      [
        Fx.operation(
          1, "2026-09-10", "500", method: cardOne,
          link: .scheduled(paymentId: internet.id, due: Fx.day("2026-09-10"))),
        Fx.operation(
          2, "2026-08-30", "52", currency: .eur, rubles: "5200", method: cardOne,
          link: .scheduled(paymentId: domain.id, due: Fx.day("2026-09-01"))),
      ], book: book)

    let lines = Funding.month(
      MonthKey(year: 2026, month: 9), book: book, ledger: ledger, today: Fx.day("2026-09-19"))

    func line(
      _ method: UUID, _ currency: CurrencyCode, _ due: String, _ paid: String, _ remaining: String
    ) -> FundingLine {
      FundingLine(
        paymentMethodId: method, currency: currency, due: Fx.money(due), paid: Fx.money(paid),
        remaining: Fx.money(remaining))
    }
    #expect(
      lines == [
        line(cardOne, .eur, "52", "52", "0"),
        line(cardOne, tenge, "10000", "0", "10000"),
        line(cardOne, .rub, "500", "500", "0"),
        line(cardOne, .usd, "10", "0", "10"),
        line(cardTwo, .rub, "1000", "0", "1000"),
        line(cardTwo, .usd, "20", "0", "20"),
      ])

    // The euros paid on 30 August settled September, so August needs nothing at all.
    #expect(
      Funding.month(
        MonthKey(year: 2026, month: 8), book: book, ledger: ledger, today: Fx.day("2026-09-19")
      ).isEmpty)
  }

  /// A payment without a method is still funded, on a line of its own, after the cards.
  @Test func aPaymentWithoutAMethodComesLast() {
    let cash = ScheduledPayment(
      id: Fx.id(1), name: "Cleaning", amountE4: Fx.money("2000"), day: 12,
      nextDate: Fx.day("2026-09-12"))
    let card = ScheduledPayment(
      id: Fx.id(2), name: "Phone", amountE4: Fx.money("700"), paymentMethodId: cardOne, day: 20,
      nextDate: Fx.day("2026-09-20"))
    let book = PlanningBook(scheduled: [cash, card])
    let lines = Funding.month(
      MonthKey(year: 2026, month: 9), book: book, ledger: Fx.ledger([], book: book),
      today: Fx.day("2026-09-19"))
    #expect(lines.map(\.paymentMethodId) == [cardOne, nil])
    // The overdue 12th still needs its money.
    #expect(lines.map(\.remaining) == [Fx.money("700"), Fx.money("2000")])
  }
}
