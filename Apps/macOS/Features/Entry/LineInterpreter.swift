import AppCore
import Foundation

/// What the entry line hands to the store. The real implementation lives in `CoreParse`
/// and understands English and Russian, amounts as expressions, dates, places, people and
/// the rest; this protocol keeps the view independent of it.
protocol LineInterpreter: Sendable {
  /// `kind` is the kind the ↓ panel already chose, for a line that names none.
  func interpret(_ text: String, today: DateOnly, kind: TransactionKind?) -> ParsedInput
}

extension LineInterpreter {
  func interpret(_ text: String, today: DateOnly) -> ParsedInput {
    interpret(text, today: today, kind: nil)
  }
}

/// The real interpreter: `CoreParse` understands English and Russian at the same time,
/// amounts written as expressions, dates, places, people, events, payment methods, goals
/// and debts.
struct CoreLineInterpreter: LineInterpreter {
  let vocabulary: ParserVocabulary
  let calendar: CalendarContext

  func interpret(_ text: String, today: DateOnly, kind: TransactionKind?) -> ParsedInput {
    InputLineParser(vocabulary: vocabulary, calendar: calendar).parse(
      text, today: today, kind: kind)
  }
}

extension ParsedInput {
  /// What Enter says when the line has no amount to save: why the number that was typed is
  /// not one («Делений на ноль и мусора нет: понятная ошибка вместо сохранения»), or that
  /// there is no number at all.
  var missingAmountErrorKey: String {
    switch amountProblem {
    case .divisionByZero: "entry.error.divisionByZero"
    case .tooLarge: "entry.error.amountTooLarge"
    case .negative: "entry.error.amountNegative"
    case .malformed: "entry.error.badExpression"
    case nil: "entry.error.amountMissing"
    }
  }
}
