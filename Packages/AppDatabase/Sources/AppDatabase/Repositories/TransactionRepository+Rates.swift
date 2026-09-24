import AppCore
import CoreKit
import Foundation
import GRDB

/// The storage half of refining provisional rates. The rule — which operations a table can
/// now settle — is `RateTable.refinement` in the core; the pipeline's rate step reads the
/// usages here, asks the bank, runs the rule and writes the answer back
/// here.
extension TransactionRepository {
  /// Operations still carrying a provisional rate that the rule may refine: live, not in
  /// rubles, their rate neither entered by hand nor brought by an import. Oldest first.
  ///
  /// `day` of each usage is the day of the operation in `calendar` — the calendar the entry
  /// panel resolved the rate with.
  public func provisionalUsages(calendar: CalendarContext) throws -> [RateTable.RateUsage] {
    try writer.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT id, currency, occurred_at, rate_source, rate_date FROM transactions
          WHERE deleted_at IS NULL AND rate_provisional = 1 AND currency <> ?
            AND (rate_source IS NULL OR rate_source NOT IN (\(Self.protectedMarks)))
          ORDER BY occurred_at
          """,
        arguments: [CurrencyCode.rub.code] + StatementArguments(Self.protectedSources)
      ).compactMap { row -> RateTable.RateUsage? in
        guard let id = RowMapping.optionalUUID(row, "id"), let moment: Date = row["occurred_at"]
        else { return nil }
        return RateTable.RateUsage(
          id: id,
          currency: CurrencyCode(row["currency"] ?? CurrencyCode.rub.code),
          day: calendar.day(of: moment),
          source: (row["rate_source"] as String?).flatMap(RateSource.init(rawValue:)),
          isProvisional: true,
          appliedRateDate: RowMapping.day(row, "rate_date"))
      }
    }
  }

  /// Writes refined rates in one transaction and returns how many operations took one.
  ///
  /// Compare and set: an operation takes its refinement only while it still carries what
  /// its usage was read with — provisional, the same currency, the same rate date, a rate
  /// not entered by hand and not imported, the same day. The rate step talks to the
  /// network between the read and this write; an operation edited in the meantime, given
  /// a rate by hand, or already refined by another run is left as it is.
  ///
  /// The rubles are worked out again from the row as it is inside the write: the
  /// operation's from its amount and the new rate, its parts' in proportion, the last one
  /// taking the rest (`AmountE4.allocated`). `rate_provisional` becomes the refinement's
  /// flag — what the table says of the day. A rate still published before the day of the
  /// operation keeps the flag, and a later run refines it again or settles it. Settling a
  /// day the bank never publishes writes the rate the operation already carries: only the
  /// flag and `updated_at` change.
  ///
  /// Reimbursement links are not touched: they hold the rubles that came back, fixed when
  /// the money arrived, and the reimbursement sheet does not close a part whose rate is
  /// still provisional.
  @discardableResult
  public func applyRefinements(
    _ refinements: [RateTable.RateRefinement],
    of usages: [RateTable.RateUsage],
    calendar: CalendarContext,
    at instant: Date = Date()
  ) throws -> Int {
    let usageById = Dictionary(usages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return try writer.write { db in
      var applied = 0
      for refinement in refinements {
        guard let usage = usageById[refinement.usageId],
          refinement.rate.currency == usage.currency,
          let fresh = try Self.entry(id: usage.id, db: db),
          calendar.day(of: fresh.transaction.occurredAt) == usage.day,
          let rubles = try? refinement.rate.toRubles(fresh.transaction.amountE4)
        else { continue }

        try db.execute(
          sql: """
            UPDATE transactions
            SET rate = ?, rate_date = ?, rate_source = ?, rate_provisional = ?,
                amount_rub_e4 = ?, updated_at = ?
            WHERE id = ? AND rate_provisional = 1 AND currency = ? AND rate_date IS ?
              AND (rate_source IS NULL OR rate_source NOT IN (\(Self.protectedMarks)))
            """,
          arguments: [
            RowMapping.string(refinement.rate.perUnit), refinement.rate.date.iso,
            refinement.rate.source.rawValue, refinement.isProvisional, rubles.raw, instant,
            usage.id.uuidString, usage.currency.code, usage.appliedRateDate?.iso,
          ] + StatementArguments(Self.protectedSources))
        guard db.changesCount == 1 else { continue }

        let shares = rubles.allocated(
          proportionallyTo: fresh.parts.map(\.amountE4), outOf: fresh.transaction.amountE4)
        for (part, share) in zip(fresh.parts, shares) where part.amountRubE4 != share {
          try db.execute(
            sql: "UPDATE transaction_parts SET amount_rub_e4 = ? WHERE id = ?",
            arguments: [share.raw, part.id.uuidString])
        }
        applied += 1
      }
      return applied
    }
  }

  /// Sources whose rates are never overwritten automatically — a rate entered by hand or
  /// brought by an import — straight from `RateSource.isProtected`.
  private static let protectedSources = RateSource.allCases.filter(\.isProtected).map(\.rawValue)
  private static let protectedMarks = databaseQuestionMarks(count: protectedSources.count)
}
