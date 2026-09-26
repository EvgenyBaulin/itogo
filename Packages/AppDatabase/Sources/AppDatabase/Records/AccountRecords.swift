import CoreKit
import Foundation
import GRDB

// The tables of the accounts (`Schema/0004_accounts.sql`), mapped by hand like every other
// record (`RowMapping`).

extension AccountGroup: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "account_groups"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      inSummary: try RowMapping.flag(row, "in_summary", fallback: true),
      sort: try RowMapping.optionalInteger(row, "sort") ?? 0,
      archived: try RowMapping.flag(row, "archived", fallback: false))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["in_summary"] = inSummary
    container["sort"] = sort
    container["archived"] = archived
  }
}

/// `occurred_at`, `created_at` and `updated_at` are instants, written the way GRDB writes those
/// of an operation.
extension Transfer: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "transfers"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      occurredAt: try RowMapping.instant(row, "occurred_at"),
      fromAccountId: try RowMapping.uuid(row, "from_payment_method_id"),
      fromCurrency: CurrencyCode(row["from_currency"] ?? "RUB"),
      fromAmountE4: try RowMapping.amount(row, "from_amount_e4"),
      toAccountId: try RowMapping.uuid(row, "to_payment_method_id"),
      toCurrency: CurrencyCode(row["to_currency"] ?? "RUB"),
      toAmountE4: try RowMapping.amount(row, "to_amount_e4"),
      note: row["note"],
      createdAt: try RowMapping.instant(row, "created_at"),
      updatedAt: try RowMapping.instant(row, "updated_at"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["occurred_at"] = occurredAt
    container["from_payment_method_id"] = fromAccountId.uuidString
    container["from_currency"] = fromCurrency.code
    container["from_amount_e4"] = fromAmountE4.raw
    container["to_payment_method_id"] = toAccountId.uuidString
    container["to_currency"] = toCurrency.code
    container["to_amount_e4"] = toAmountE4.raw
    container["note"] = note
    container["created_at"] = createdAt
    container["updated_at"] = updatedAt
  }
}

extension ReconciledBalance: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "reconciliation_balances"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      reconciliationId: try RowMapping.uuid(row, "reconciliation_id"),
      accountId: try RowMapping.uuid(row, "payment_method_id"),
      currency: CurrencyCode(row["currency"] ?? "RUB"),
      actualE4: try RowMapping.amount(row, "actual_e4"),
      expectedE4: try RowMapping.optionalAmount(row, "expected_e4"),
      differenceE4: try RowMapping.optionalAmount(row, "difference_e4"),
      transactionId: RowMapping.optionalUUID(row, "transaction_id"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["reconciliation_id"] = reconciliationId.uuidString
    container["payment_method_id"] = accountId.uuidString
    container["currency"] = currency.code
    container["actual_e4"] = actualE4.raw
    container["expected_e4"] = expectedE4?.raw
    container["difference_e4"] = differenceE4?.raw
    container["transaction_id"] = transactionId?.uuidString
  }
}
