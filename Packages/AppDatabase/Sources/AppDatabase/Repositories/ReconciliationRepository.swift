import CoreKit
import Foundation
import GRDB

/// Reconciliations of the total with what the owner actually has. Overview asks when the
/// last one was; the planning reads them all.
public struct ReconciliationRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// The day of the latest reconciliation, `nil` when there has been none.
  public func latestDate() throws -> DateOnly? {
    try writer.read { db in
      try String.fetchOne(db, sql: "SELECT MAX(date) FROM reconciliations")
        .flatMap(DateOnly.init(iso:))
    }
  }

  /// Every reconciliation, oldest first.
  public func all() throws -> [Reconciliation] {
    try writer.read { db in try Self.all(db) }
  }

  /// Oldest first: by day, then by the instant within the day. A reconciliation made before
  /// the instant was recorded (NULL) comes first among those of its day — SQLite sorts NULL
  /// first — and rows equal in both keep the order they were made in.
  static func all(_ db: Database) throws -> [Reconciliation] {
    try Reconciliation.order(Column("date"), Column("reconciled_at"), Column.rowID).fetchAll(db)
  }
}
