import CoreKit
import Foundation
import GRDB

// The cards of the accounts and their cashback rules (`Schema/0005_cards.sql`), mapped by hand
// like every other record (`RowMapping`).

/// `aliases` is one other name per line, as for the accounts.
extension PaymentCard: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "cards"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      accountId: try RowMapping.uuid(row, "payment_method_id"),
      name: row["name"] ?? "",
      aliases: RowMapping.aliases(row, "aliases"),
      sort: try RowMapping.optionalInteger(row, "sort") ?? 0,
      archived: try RowMapping.flag(row, "archived", fallback: false))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["payment_method_id"] = accountId.uuidString
    container["name"] = name
    container["aliases"] = RowMapping.join(aliases)
    container["sort"] = sort
    container["archived"] = archived
  }
}

/// `month` is 'YYYY-MM' or NULL for «always»; `percent_e4` is in 1/10000 of a percent. A
/// percent that does not read, or reads outside 0…100 % — only a hand edit leaves one — reads as
/// 0 %: a rule is an expectation, and one damaged value must not stop the whole history from
/// being read.
extension CashbackRule: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "cashback_rules"

  public init(row: Row) throws {
    let stored = (try? RowMapping.optionalInteger(row, "percent_e4")) ?? nil
    self.init(
      id: try RowMapping.uuid(row, "id"),
      accountId: try RowMapping.uuid(row, "payment_method_id"),
      cardId: RowMapping.optionalUUID(row, "card_id"),
      categoryId: RowMapping.optionalUUID(row, "category_id"),
      month: RowMapping.month(row, "month"),
      percent: stored.flatMap { CashbackPercent(e4: Int64($0)) } ?? .zero)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["payment_method_id"] = accountId.uuidString
    container["card_id"] = cardId?.uuidString
    container["category_id"] = categoryId?.uuidString
    container["month"] = month?.iso
    container["percent_e4"] = percent.e4
  }
}
