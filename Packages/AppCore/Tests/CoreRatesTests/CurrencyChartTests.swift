import CoreKit
import Foundation
import Testing

@testable import CoreRates

@Suite("График валюты")
struct CurrencyChartTests {
  private let today = DateOnly(year: 2026, month: 10, day: 7)

  @Test func theDaysOfEachPeriod() {
    let week = CurrencyChart.days(.week, today: today, calendar: .utc)
    #expect(
      week.count == 7 && week.last == today && week.first == DateOnly(year: 2026, month: 10, day: 1)
    )
    #expect(CurrencyChart.days(.month, today: today, calendar: .utc).count == 11)
    let year = CurrencyChart.days(.year, today: today, calendar: .utc)
    #expect(year.count == 13 && year.first! < DateOnly(year: 2025, month: 10, day: 20))
  }

  @Test func theRateOfAPair() {
    let usd = CurrencyPair(base: .usd, quote: .rub)
    #expect(CurrencyChart.rateE4(of: usd, basePerRub: 92.5, quotePerRub: nil) == 925_000)
    let usdEur = CurrencyPair(base: .usd, quote: .eur)
    #expect(CurrencyChart.rateE4(of: usdEur, basePerRub: 90, quotePerRub: 100) == 9_000)
    #expect(CurrencyChart.rateE4(of: usdEur, basePerRub: 90, quotePerRub: nil) == nil)
  }

  @Test func theChangeOverThePeriod() {
    let points = [
      CurrencyChartPoint(day: today, rateE4: 900_000),
      CurrencyChartPoint(day: today, rateE4: 945_000),
    ]
    let summary = CurrencyChart.summary(points)
    #expect(summary?.current == 945_000 && summary?.change == 45_000 && summary?.changeBp == 500)
    #expect(CurrencyChart.summary(Array(points.prefix(1))) == nil)
  }

  @Test func thePairsOffered() {
    let pairs = CurrencyChart.pairs(
      accountCurrencies: [.rub, .usd, CurrencyCode("KZT")], defaultCurrency: .rub)
    #expect(pairs.map(\.description) == ["USD/RUB", "EUR/RUB", "KZT/RUB"])
  }

  @Test func theChoiceIsKept() {
    let (pair, period) = CurrencyChart.decode(
      CurrencyChart.encode(CurrencyPair(base: .eur, quote: .rub), .year))
    #expect(pair.description == "EUR/RUB" && period == .year)
    #expect(CurrencyChart.decode(nil).0.description == "USD/RUB")
    #expect(CurrencyChart.decode("junk").1 == .month)
  }
}
