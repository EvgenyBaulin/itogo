import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// A word of the entry line that looks like a day — «12.09», «31.09», «12/09» — is a day only
/// when it is one in the calendar and another number is left for the amount; otherwise it is a
/// number, and the first number of the line is the amount. Some of these readings are open
/// questions; each is pinned here so that changing it is a choice made on purpose, not an
/// accident of some other change. «Today» is 18 September 2026.
@Suite("A day or a number in the entry line")
struct DateOrNumberLineTests {
  struct Reading: Sendable, CustomTestStringConvertible {
    let line: String
    let amount: String?
    let date: String?
    let note: String
    let expression: String?
    var testDescription: String { line }
    init(
      _ line: String, amount: String?, date: String? = nil, note: String = "кофе",
      expression: String? = nil
    ) {
      self.line = line
      self.amount = amount
      self.date = date
      self.note = note
      self.expression = expression
    }
  }

  @Test(
    "How a word that looks like a day is read",
    arguments: [
      // A real day with an amount beside it, on either side: the day and the amount.
      Reading("кофе 1.09 250", amount: "250", date: "2026-09-01"),
      Reading("кофе 250 12.09", amount: "250", date: "2026-09-12"),
      Reading("кофе 5.05 300", amount: "300", date: "2026-05-05"),
      Reading("кофе 28.02 250", amount: "250", date: "2026-02-28"),
      // A day later in the year than today is last year's.
      Reading("10.10 2500", amount: "2500", date: "2025-10-10", note: ""),
      // The 29th of February is not in 2026: the nearest year before that has one.
      Reading("кофе 29.02 250", amount: "250", date: "2024-02-29"),
      // Not a day of the calendar: a number, and the first number is the amount.
      Reading("кофе 31.09 250", amount: "31.09", note: "кофе 250"),
      Reading("кофе 30.02 250", amount: "30.02", note: "кофе 250"),
      Reading("кофе 31.04 250", amount: "31.04", note: "кофе 250"),
      Reading("кофе 12.13 250", amount: "12.13", note: "кофе 250"),
      // A day is written with a point and a month of two digits; anything else is a number.
      Reading("кофе 12,09 250", amount: "12.09", note: "кофе 250"),
      Reading("кофе 12.9 250", amount: "12.9", note: "кофе 250"),
      // The only number of the line is the amount, whatever it looks like.
      Reading("кофе 12.09", amount: "12.09"), Reading("кофе 10.10", amount: "10.1"),
      // A slash is a division, and a space before three digits groups thousands.
      Reading("кофе 12/09 250", amount: "0.0013", expression: "12/09 250"),
      Reading("кофе 250/2 100", amount: "0.119", expression: "250/2 100"),
      Reading("кофе 05 300", amount: "5300"),
    ])
  func howAWordThatLooksLikeADayIsRead(_ reading: Reading) {
    let result = Fixture.parse(reading.line)
    #expect(result.amount == reading.amount.map(dec))
    #expect(result.date?.iso == reading.date)
    #expect(result.note == reading.note)
    #expect(result.amountExpression == reading.expression)
  }

  /// What shows the amount before Enter where a day and a number are easy to mix up: a comma
  /// that is not how the app writes it, a formula, a number grouped by a space. A day-shaped
  /// number written the app's way shows nothing.
  @Test("What is shown before Enter for day-shaped numbers")
  func previewsOfDayShapedNumbers() {
    #expect(Fixture.parse("кофе 12,09 250").amountToPreview == "12,09")
    #expect(Fixture.parse("кофе 12/09 250").amountToPreview == "12/09 250")
    #expect(Fixture.parse("кофе 05 300").amountToPreview == "05 300")
    #expect(Fixture.parse("кофе 12.09").amountToPreview == nil)
    #expect(Fixture.parse("кофе 31.09 250").amountToPreview == nil)
  }
}
