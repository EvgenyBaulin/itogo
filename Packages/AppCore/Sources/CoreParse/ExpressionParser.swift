import CoreKit
import Foundation

/// Evaluates the small arithmetic a person can type instead of an amount:
/// `120+80.5+45`, `(1000+600)/2`, `3000÷4`, `1500×3−2000`.
///
/// Everything is computed in `Decimal`; the result is rounded to the four fraction digits
/// the schema stores in its `*_e4` columns, so an expression can never carry more precision
/// than the amount it produces.
public enum ExpressionEvaluator: Sendable {
  /// Fraction digits kept in the result — the scale of the `*_e4` money columns.
  public static let fractionDigits = 4

  /// Largest result one amount may have: `AmountE4.inputLimit`, a trillion whole units.
  /// Decimal arithmetic does not trap on overflow — it quietly returns a NaN — so a formula
  /// that runs past it is rejected here instead of travelling on as a number. The limit sits
  /// far below `Int64.max` stored units on purpose: two amounts that each fit the column
  /// must still fit it together, in the total of a day or of a split.
  static let maxMagnitude = AmountE4.inputLimit.decimal

  /// - Throws: `CoreError.emptyInput` for blank text, `CoreError.divisionByZero`,
  ///   `CoreError.amountOutOfRange` when the result overflows or is larger than one amount
  ///   may be, `CoreError.malformedExpression(position:)` with the offset of the offending
  ///   character (the length of the text when the formula ends too early).
  public static func evaluate(_ text: String) throws -> Decimal {
    let characters = Array(text)
    guard characters.contains(where: { !ExpressionLexer.isSpace($0) }) else {
      throw CoreError.emptyInput
    }
    let tokens = try ExpressionLexer.tokenize(characters)
    guard !tokens.isEmpty else { throw CoreError.emptyInput }
    var parser = ExpressionParser(tokens: tokens, endPosition: characters.count)
    let value = try parser.parseExpression()
    try parser.expectEnd()
    guard !value.isNaN else { throw CoreError.amountOutOfRange }
    let rounded = DecimalMath.round(value, scale: fractionDigits)
    guard rounded.magnitude <= maxMagnitude else { throw CoreError.amountOutOfRange }
    return rounded
  }

  /// The text with every number in it written the way the app writes numbers, and everything
  /// else — signs, brackets, spaces, the `k` of thousands — as typed: «1500,5+2,50» becomes
  /// «1,500.5+2.50», «(1 000+600)/2» becomes «(1,000+600)/2», «2,5k» becomes «2.5k». It comes
  /// to the same value as the text. Nil for text that is not made of numbers and signs.
  public static func canonical(_ text: String) -> String? {
    let characters = Array(text)
    guard let tokens = try? ExpressionLexer.tokenize(characters) else { return nil }
    var result = ""
    var cursor = 0
    for token in tokens {
      guard case .number = token.kind else { continue }
      result += String(characters[cursor..<token.position]) + token.canonical
      cursor = token.end
    }
    return result + String(characters[cursor...])
  }

  /// True when the text is a formula rather than a plain number, so the entry keeps it in
  /// `amount_expr`. A single leading sign does not make a formula: `+50000` marks income.
  public static func isFormula(_ text: String) -> Bool {
    var characters = Array(text.trimmingCharacters(in: .whitespaces))
    if let first = characters.first, first == "+" || ExpressionLexer.operatorKind(first) == .minus {
      characters.removeFirst()
    }
    return characters.contains { ExpressionLexer.operatorKind($0) != nil }
  }
}

/// Recursive descent over the token list: `+ -` bind loosest, then `* /`, then unary signs,
/// then numbers and parentheses.
struct ExpressionParser {
  /// How far brackets and signs may nest. Both nest by recursion, so without a ceiling a
  /// line pasted with a few hundred opening brackets runs the stack out and kills the
  /// process instead of raising an error. A formula a person types never comes close.
  static let maxDepth = 32

  private let tokens: [ExpressionToken]
  private let endPosition: Int
  private var index = 0
  private var depth = 0

  init(tokens: [ExpressionToken], endPosition: Int) {
    self.tokens = tokens
    self.endPosition = endPosition
  }

  private func peek() -> ExpressionToken? {
    index < tokens.count ? tokens[index] : nil
  }

  private mutating func advance() {
    index += 1
  }

  mutating func expectEnd() throws {
    if let token = peek() {
      throw CoreError.malformedExpression(position: token.position)
    }
  }

  mutating func parseExpression() throws -> Decimal {
    var value = try parseTerm()
    while let token = peek() {
      switch token.kind {
      case .plus:
        advance()
        let right = try parseTerm()
        value = value + right
      case .minus:
        advance()
        let right = try parseTerm()
        value = value - right
      default:
        return value
      }
    }
    return value
  }

  private mutating func parseTerm() throws -> Decimal {
    var value = try parseUnary()
    while let token = peek() {
      switch token.kind {
      case .times:
        advance()
        let right = try parseUnary()
        value = value * right
      case .divide:
        advance()
        let right = try parseUnary()
        guard right != Decimal.zero else { throw CoreError.divisionByZero }
        value = value / right
      default:
        return value
      }
    }
    return value
  }

  private mutating func parseUnary() throws -> Decimal {
    guard let token = peek() else {
      throw CoreError.malformedExpression(position: endPosition)
    }
    switch token.kind {
    case .plus, .minus:
      advance()
      try descend(from: token.position)
      defer { depth -= 1 }
      let value = try parseUnary()
      return token.kind == .minus ? -value : value
    default:
      return try parsePrimary()
    }
  }

  /// Enters one more level of nesting, or refuses to.
  private mutating func descend(from position: Int) throws {
    depth += 1
    guard depth <= ExpressionParser.maxDepth else {
      throw CoreError.malformedExpression(position: position)
    }
  }

  private mutating func parsePrimary() throws -> Decimal {
    guard let token = peek() else {
      throw CoreError.malformedExpression(position: endPosition)
    }
    switch token.kind {
    case .number(let value):
      advance()
      return value
    case .openParen:
      advance()
      try descend(from: token.position)
      defer { depth -= 1 }
      let value = try parseExpression()
      guard let closing = peek(), closing.kind == .closeParen else {
        throw CoreError.malformedExpression(position: peek()?.position ?? endPosition)
      }
      advance()
      return value
    default:
      throw CoreError.malformedExpression(position: token.position)
    }
  }
}
