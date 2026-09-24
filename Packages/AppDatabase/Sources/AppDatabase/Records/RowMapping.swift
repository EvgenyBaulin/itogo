import CoreKit
import Foundation
import GRDB

/// Explicit row mapping helpers.
///
/// Everything is mapped by hand on purpose: identifiers must land in TEXT columns (GRDB
/// would store `UUID` as a blob), amounts in INTEGER `*_e4` columns, rates as decimal
/// strings and calendar days as `YYYY-MM-DD`. The SQL schema in `Schema/` is the contract
/// shared with the future Windows port, so the storage format may not drift.
enum RowMapping {
  /// An id the row cannot do without. One that is not a UUID fails the whole read with
  /// `UnreadableValue` rather than being skipped: a row left out would take its money out of
  /// every figure without a word.
  static func uuid(_ row: Row, _ column: String) throws -> UUID {
    guard let text: String = row[column], let value = UUID(uuidString: text) else {
      throw UnreadableValue(column: column)
    }
    return value
  }

  static func optionalUUID(_ row: Row, _ column: String) -> UUID? {
    guard let text: String = row[column] else { return nil }
    return UUID(uuidString: text)
  }

  static func amount(_ row: Row, _ column: String) -> AmountE4 {
    AmountE4(raw: row[column] ?? 0)
  }

  static func optionalAmount(_ row: Row, _ column: String) -> AmountE4? {
    guard let raw: Int64 = row[column] else { return nil }
    return AmountE4(raw: raw)
  }

  static func decimal(_ row: Row, _ column: String) -> Decimal? {
    guard let text: String = row[column] else { return nil }
    return Decimal(string: text, locale: posix)
  }

  /// Rates are written with a dot whatever the machine's language. Built once rather than
  /// for every row that carries a rate: making a `Locale` costs far more than reading the
  /// number, and the whole history is read on every load.
  private static let posix = Locale(identifier: "en_US_POSIX")

  static func day(_ row: Row, _ column: String) -> DateOnly? {
    guard let text: String = row[column] else { return nil }
    return DateOnly(iso: text)
  }

  static func month(_ row: Row, _ column: String) -> MonthKey? {
    guard let text: String = row[column] else { return nil }
    return MonthKey(iso: text)
  }

  /// The column keeps one alias per line, so any newline separates aliases. `\r\n` counts
  /// as one separator, because the Windows port writes the same column.
  static func aliases(_ row: Row, _ column: String) -> [String] {
    let text: String = row[column] ?? ""
    return split(text)
  }

  static func split(_ text: String) -> [String] {
    text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
  }

  /// A newline inside a single alias would silently turn it into two aliases — and the
  /// parser would then match either half on its own. It becomes a space instead; spaces
  /// around an alias are the owner's and are kept.
  static func join(_ aliases: [String]) -> String {
    aliases.map(singleLine).filter { !$0.isEmpty }.joined(separator: "\n")
  }

  private static func singleLine(_ alias: String) -> String {
    guard alias.contains(where: \.isNewline) else { return alias }
    var result = ""
    result.reserveCapacity(alias.count)
    for character in alias {
      result.append(character.isNewline ? " " : character)
    }
    return result
  }

  /// Decimal written back as a plain string, so the value survives a round trip untouched.
  static func string(_ value: Decimal?) -> String? {
    guard let value else { return nil }
    return "\(value)"
  }
}

/// A value the app cannot read where it needs one: an id that is not a UUID. Only a writer
/// other than the app makes such a row — a hand edit, another program. The error names the
/// column, never the value, and its type is what the journal of a failed read records, so
/// the report says «a damaged row», not «not found».
public struct UnreadableValue: Error, Equatable, Sendable {
  public let column: String

  public init(column: String) {
    self.column = column
  }
}
