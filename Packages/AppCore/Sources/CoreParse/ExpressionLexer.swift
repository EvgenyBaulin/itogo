import CoreKit
import Foundation

/// One token of an arithmetic expression together with the offset of its first character.
/// The offset is what `CoreError.malformedExpression(position:)` reports, so the entry
/// field can underline the exact character that broke the formula.
struct ExpressionToken: Equatable {
  enum Kind: Equatable {
    /// A number, and the same number as an exact fraction when it fits one.
    case number(Decimal, exact: ExactFraction?)
    case plus
    case minus
    case times
    case divide
    case openParen
    case closeParen
  }

  let kind: Kind
  let position: Int
  /// The offset just past the token.
  let end: Int
  /// A number written the way the app writes numbers, its `k` kept as typed: «1500,5» is
  /// «1,500.5», «2,5к» is «2.5к». Empty for everything but a number.
  var canonical = ""
}

/// Turns the characters of an expression into tokens.
///
/// Numbers accept both decimal separators and every thousand separator a person may type:
/// a plain space, a non-breaking space, a thin space, `.` or `,`. Which separator is the
/// decimal one is decided by `TypedNumber`, the rule of amounts typed by hand: `1,250.50` and
/// `1.250,50` both mean 1250.5, `1,500` is 1500 and `1,5` is 1.5. A trailing `k` / `к`
/// multiplies by a thousand: `2k` and `2к` are 2000.
enum ExpressionLexer {
  /// Spaces that may sit inside a number as a thousand separator.
  static let spaces: Set<Character> = [
    " ", "\u{00A0}", "\u{202F}", "\u{2009}", "\t", "\n", "\r",
  ]
  /// `k` and its Russian twin `к`, both cases.
  static let thousandSuffixes: Set<Character> = ["k", "K", "к", "К"]
  static let decimalSeparators: Set<Character> = [".", ","]

  static func isDigit(_ character: Character) -> Bool {
    character >= "0" && character <= "9"
  }

  static func isSpace(_ character: Character) -> Bool {
    spaces.contains(character) || character.isWhitespace
  }

  static func operatorKind(_ character: Character) -> ExpressionToken.Kind? {
    switch character {
    case "+": return .plus
    // U+2212 minus sign, U+2013 en dash, U+2014 em dash — all typed instead of a hyphen.
    case "-", "\u{2212}", "\u{2013}", "\u{2014}": return .minus
    case "*", "\u{00D7}", "\u{22C5}", "\u{00B7}": return .times
    case "/", "\u{00F7}", "\u{2215}": return .divide
    case "(": return .openParen
    case ")": return .closeParen
    default: return nil
    }
  }

  static func tokenize(_ characters: [Character]) throws -> [ExpressionToken] {
    var tokens: [ExpressionToken] = []
    var index = 0
    while index < characters.count {
      let character = characters[index]
      if isSpace(character) {
        index += 1
        continue
      }
      let startsNumber =
        isDigit(character)
        || (decimalSeparators.contains(character) && index + 1 < characters.count
          && isDigit(characters[index + 1]))
      if startsNumber {
        let scanned = try scanNumber(characters, from: index)
        tokens.append(
          ExpressionToken(
            kind: .number(scanned.value, exact: scanned.exact), position: index,
            end: scanned.end, canonical: scanned.canonical))
        index = scanned.end
        continue
      }
      guard let kind = operatorKind(character) else {
        throw CoreError.malformedExpression(position: index)
      }
      tokens.append(ExpressionToken(kind: kind, position: index, end: index + 1))
      index += 1
    }
    return tokens
  }

  /// Reads one number starting at `start` and returns it with the offset just past it and
  /// its canonical text.
  private static func scanNumber(
    _ characters: [Character], from start: Int
  ) throws -> (value: Decimal, exact: ExactFraction?, end: Int, canonical: String) {
    var index = start
    var digits = ""
    // Spaces group thousands before the decimal part only. Once a `.` or `,` has been read,
    // a space and three digits start the next number: «1,5 120» is 1.5 and 120, not 1.512.
    var sawSeparator = false
    while index < characters.count {
      let character = characters[index]
      if isDigit(character) {
        digits.append(character)
        index += 1
      } else if decimalSeparators.contains(character), index + 1 < characters.count,
        isDigit(characters[index + 1])
      {
        digits.append(character)
        sawSeparator = true
        index += 1
      } else if !sawSeparator, isSpace(character),
        startsGroupOfThree(characters, separatorAt: index)
      {
        index += 1
      } else {
        break
      }
    }

    var multiplier = Decimal(1)
    var suffix = ""
    if index < characters.count, thousandSuffixes.contains(characters[index]) {
      let next = index + 1 < characters.count ? characters[index + 1] : nil
      let glued = next.map { $0.isLetter || isDigit($0) } ?? false
      if !glued {
        multiplier = Decimal(1000)
        suffix = String(characters[index])
        index += 1
      }
    }

    guard let reading = TypedNumber.read(digits) else {
      // Hundreds of digits are a number too large to be an amount, not a typo.
      if TypedNumber.isTooLarge(digits) { throw CoreError.amountOutOfRange }
      throw CoreError.malformedExpression(position: start)
    }
    var exact = ExactFraction(
      integerDigits: reading.integerDigits, fractionDigits: reading.fractionDigits,
      multiplier: suffix.isEmpty ? 1 : 1_000)
    if reading.isNegative { exact = exact?.negated() }
    return (reading.value * multiplier, exact, index, reading.canonical + suffix)
  }

  /// A space belongs to a number only when exactly three digits follow it, the way
  /// thousands are grouped: `1 250,50` is one number, `250 300` is 250300, but `1 25` is not.
  private static func startsGroupOfThree(
    _ characters: [Character], separatorAt index: Int
  ) -> Bool {
    guard index + 3 < characters.count else { return false }
    for offset in 1...3 where !isDigit(characters[index + offset]) { return false }
    let after = index + 4
    guard after < characters.count else { return true }
    return !isDigit(characters[after])
  }
}
