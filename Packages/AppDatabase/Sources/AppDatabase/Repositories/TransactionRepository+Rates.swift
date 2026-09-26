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
  /// A refund taken back from a purchase is not among them: it keeps the rate of its purchase,
  /// and follows that purchase when it is refined, never the rate of its own day.
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
            AND id NOT IN (
              SELECT transaction_id FROM transaction_parts WHERE refund_of_part_id IS NOT NULL)
          ORDER BY occurred_at
          """,
        arguments: [CurrencyCode.rub.code] + StatementArguments(Self.protectedSources)
      ).compactMap { row -> RateTable.RateUsage? in
        guard let id = RowMapping.optionalUUID(row, "id"),
          let moment = RowMapping.readableInstant(row, "occurred_at")
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
  /// still provisional. Money back typed part by part can still reach such a part; when its
  /// refined rubles leave nothing more to wait for, it is settled (`settleCoveredParts`).
  ///
  /// What a ruble account was charged is the operation's rubles, so a charge in rubles follows
  /// the refined rubles; a rate typed from the statement is a manual one, never refined. A
  /// charge in another currency is never refined. The refunds taken back from a refined
  /// purchase take its rate too, and their stored rubles are worked out again from its parts,
  /// oldest refund first (`RefundRules.rubles`): they are for display, the figures follow the
  /// purchase anyway.
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
                amount_rub_e4 = ?, updated_at = ?,
                account_amount_e4 = CASE WHEN account_currency = ? THEN ?
                                         ELSE account_amount_e4 END
            WHERE id = ? AND rate_provisional = 1 AND currency = ? AND rate_date IS ?
              AND (rate_source IS NULL OR rate_source NOT IN (\(Self.protectedMarks)))
            """,
          arguments: [
            RowMapping.string(refinement.rate.perUnit), refinement.rate.date.iso,
            refinement.rate.source.rawValue, refinement.isProvisional, rubles.raw,
            StoredInstant.databaseValue(instant),
            CurrencyCode.rub.code, rubles.raw,
            usage.id.uuidString, usage.currency.code, usage.appliedRateDate?.iso,
          ] + StatementArguments(Self.protectedSources))
        guard db.changesCount == 1 else { continue }

        let shares = rubles.allocated(
          proportionallyTo: fresh.parts.map(\.amountE4), outOf: fresh.transaction.amountE4)
        var refined: [TransactionPart] = []
        for (part, share) in zip(fresh.parts, shares) {
          var part = part
          if part.amountRubE4 != share {
            try db.execute(
              sql: "UPDATE transaction_parts SET amount_rub_e4 = ? WHERE id = ?",
              arguments: [share.raw, part.id.uuidString])
            part.amountRubE4 = share
          }
          refined.append(part)
        }
        try Self.settleCoveredParts(refined, db: db)
        if fresh.transaction.kind == .expense {
          try Self.refineRefunds(
            of: refined, rate: refinement.rate, isProvisional: refinement.isProvisional,
            at: instant, db: db)
        }
        applied += 1
      }
      return applied
    }
  }

  /// A part some money already came back for, which its refined rubles leave with nothing more
  /// to wait for, is settled: `returned`. A lower rate of the day can take the part's rubles to
  /// what came back or below; left waiting, the part would be owed nothing and could be neither
  /// closed nor written off. The drift of a rate is neither spending nor income, so nothing else
  /// is written, and deleting the money back reopens the part as it reopens any part it closed.
  /// A part the new rubles still leave something of keeps waiting for the rest.
  private static func settleCoveredParts(_ parts: [TransactionPart], db: Database) throws {
    for part in parts
    where part.reimbursable && (part.reimbursementStatus ?? .expected) == .expected {
      let back = try returnedRub(ofPart: part.id, db: db)
      guard back.raw > 0, part.amountRubE4 <= back else { continue }
      try db.execute(
        sql: "UPDATE transaction_parts SET reimbursement_status = ? WHERE id = ?",
        arguments: [ReimbursementStatus.returned.rawValue, part.id.uuidString])
    }
  }

  /// The refunds taken back from these parts of a refined purchase take its rate, and store
  /// rubles worked out again from the parts, oldest refund first.
  private static func refineRefunds(
    of parts: [TransactionPart], rate: Rate, isProvisional: Bool, at instant: Date,
    db: Database
  ) throws {
    var touched: [UUID] = []
    for part in parts {
      let refundParts = try TransactionPart.fetchAll(
        db,
        sql: """
          SELECT p.* FROM transaction_parts p JOIN transactions t ON t.id = p.transaction_id
          WHERE p.refund_of_part_id = ? AND t.deleted_at IS NULL AND t.kind = ?
          ORDER BY t.occurred_at, t.rowid, p.rowid
          """,
        arguments: [part.id.uuidString, TransactionKind.refund.rawValue])
      var before = (amount: AmountE4.zero, rub: AmountE4.zero)
      for refundPart in refundParts {
        let rubles = RefundRules.rubles(
          refundAmount: refundPart.amountE4, part: part, refundedBefore: before)
        before = (before.amount + refundPart.amountE4, before.rub + rubles)
        if refundPart.amountRubE4 != rubles {
          try db.execute(
            sql: "UPDATE transaction_parts SET amount_rub_e4 = ? WHERE id = ?",
            arguments: [rubles.raw, refundPart.id.uuidString])
        }
        if !touched.contains(refundPart.transactionId) { touched.append(refundPart.transactionId) }
      }
    }
    for refundId in touched {
      try db.execute(
        sql: """
          UPDATE transactions
          SET rate = ?, rate_date = ?, rate_source = ?, rate_provisional = ?, updated_at = ?,
              amount_rub_e4 = (
                SELECT COALESCE(SUM(amount_rub_e4), 0) FROM transaction_parts
                WHERE transaction_id = transactions.id)
          WHERE id = ?
          """,
        arguments: [
          RowMapping.string(rate.perUnit), rate.date.iso, rate.source.rawValue, isProvisional,
          StoredInstant.databaseValue(instant), refundId.uuidString,
        ])
    }
  }

  /// Sources whose rates are never overwritten automatically — a rate entered by hand or
  /// brought by an import — straight from `RateSource.isProtected`.
  private static let protectedSources = RateSource.allCases.filter(\.isProtected).map(\.rawValue)
  private static let protectedMarks = databaseQuestionMarks(count: protectedSources.count)
}
