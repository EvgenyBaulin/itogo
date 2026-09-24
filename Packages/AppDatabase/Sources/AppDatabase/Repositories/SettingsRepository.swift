import CoreKit
import Foundation
import GRDB

/// Key-value settings that belong to the data, not to the machine: language, enabled
/// currencies, thresholds. Window positions and folder bookmarks stay out of here.
public struct SettingsRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func string(_ key: String) throws -> String? {
    try writer.read { db in
      try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
    }
  }

  public func set(_ key: String, to value: String) throws {
    try writer.write { db in try Self.set(key, to: value, in: db) }
  }

  /// The same inside a write already open — a history batch sets what it points at with it.
  static func set(_ key: String, to value: String, in db: Database) throws {
    try db.execute(
      sql: """
        INSERT INTO settings (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
      arguments: [key, value])
  }

  public func enabledCurrencies() throws -> [CurrencyCode] {
    let codes = try writer.read { db in
      try String.fetchAll(
        db, sql: "SELECT code FROM currencies WHERE enabled = 1 ORDER BY sort, code")
    }
    return codes.isEmpty ? CurrencyCode.defaultEnabled : codes.map(CurrencyCode.init)
  }

  /// Enables at most ten currencies, as the specification requires.
  public func setEnabledCurrencies(_ currencies: [CurrencyCode]) throws {
    let limited = Array(currencies.prefix(CurrencyCode.maxEnabled))
    _ = try writer.write { db in
      try db.execute(sql: "UPDATE currencies SET enabled = 0")
      for (index, currency) in limited.enumerated() {
        try db.execute(
          sql: """
            INSERT INTO currencies (code, enabled, sort) VALUES (?, 1, ?)
            ON CONFLICT(code) DO UPDATE SET enabled = 1, sort = excluded.sort
            """,
          arguments: [currency.code, index])
      }
    }
  }
}
