import CoreKit
import Foundation
import GRDB

extension CoreKit.Category: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "categories"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      parentId: RowMapping.optionalUUID(row, "parent_id"),
      kind: CategoryKind(rawValue: row["kind"] ?? "expense") ?? .expense,
      name: row["name"] ?? "",
      sort: try RowMapping.optionalInteger(row, "sort") ?? 0,
      archived: try RowMapping.flag(row, "archived", fallback: false),
      quality: (row["quality"] as String?).flatMap(Quality.init(rawValue:)),
      systemRole: (row["system_role"] as String?).flatMap(SystemRole.init(rawValue:)))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["parent_id"] = parentId?.uuidString
    container["kind"] = kind.rawValue
    container["name"] = name
    container["sort"] = sort
    container["archived"] = archived
    container["quality"] = quality?.rawValue
    container["system_role"] = systemRole?.rawValue
  }
}

extension Person: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "people"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      relation: PersonRelation(rawValue: row["relation"] ?? "other") ?? .other,
      aliases: RowMapping.aliases(row, "aliases"),
      archived: try RowMapping.flag(row, "archived", fallback: false))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["relation"] = relation.rawValue
    container["aliases"] = RowMapping.join(aliases)
    container["archived"] = archived
  }
}

extension Place: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "places"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      aliases: RowMapping.aliases(row, "aliases"),
      archived: try RowMapping.flag(row, "archived", fallback: false))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["aliases"] = RowMapping.join(aliases)
    container["archived"] = archived
  }
}

/// An account. A main currency left NULL, empty or blank by an older build reads as none —
/// which counts as rubles (`PaymentMethod.mainCurrency`) — and is written back only when the
/// owner saves the account. `other_currencies` is the codes after the main one, joined by
/// commas.
extension PaymentMethod: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "payment_methods"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      kind: PaymentMethodKind(rawValue: row["kind"] ?? "card") ?? .card,
      currency: RowMapping.currency(row, "currency"),
      aliases: RowMapping.aliases(row, "aliases"),
      isDefault: try RowMapping.flag(row, "is_default", fallback: false),
      archived: try RowMapping.flag(row, "archived", fallback: false),
      groupId: RowMapping.optionalUUID(row, "group_id"),
      sort: try RowMapping.optionalInteger(row, "sort") ?? 0,
      otherCurrencies: RowMapping.currencies(row, "other_currencies"),
      bankId: RowMapping.optionalUUID(row, "bank_id"),
      cashbackRounding: Self.cashbackRounding(row),
      cashbackPayout: Self.cashbackPayout(row),
      cashbackPointsAccountId: RowMapping.optionalUUID(row, "cashback_points_account_id"))
  }

  /// How the account's bank rounds. A word the app never writes — only a hand edit leaves one —
  /// reads as the default: one damaged cell must not stop the history from being read.
  private static func cashbackRounding(_ row: Row) -> CashbackRounding {
    let precision = (row["cashback_precision"] as String?)
      .flatMap(CashbackRounding.Precision.init(rawValue:))
    let direction = (row["cashback_direction"] as String?)
      .flatMap(CashbackRounding.Direction.init(rawValue:))
    return CashbackRounding(precision: precision ?? .whole, direction: direction ?? .nearest)
  }

  /// When the bank pays. A word or a day that does not read, or a day that does not belong with
  /// the word, reads as «not said».
  private static func cashbackPayout(_ row: Row) -> CashbackPayout? {
    guard
      let timing = (row["cashback_payout"] as String?)
        .flatMap(CashbackPayout.Timing.init(rawValue:))
    else { return nil }
    let day = (try? RowMapping.optionalInteger(row, "cashback_payout_day")) ?? nil
    return CashbackPayout(timing: timing, storedDay: day)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["kind"] = kind.rawValue
    container["currency"] = currency?.code
    container["aliases"] = RowMapping.join(aliases)
    container["is_default"] = isDefault
    container["archived"] = archived
    container["group_id"] = groupId?.uuidString
    container["sort"] = sort
    container["other_currencies"] = otherCurrencies.map(\.code).joined(separator: ",")
    container["bank_id"] = bankId?.uuidString
    container["cashback_precision"] = cashbackRounding.precision.rawValue
    container["cashback_direction"] = cashbackRounding.direction.rawValue
    container["cashback_payout"] = cashbackPayout?.timing.rawValue
    container["cashback_payout_day"] = cashbackPayout?.day
    container["cashback_points_account_id"] = cashbackPointsAccountId?.uuidString
  }
}

extension Event: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "events"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      kind: EventKind(rawValue: row["kind"] ?? "other") ?? .other,
      startDate: RowMapping.day(row, "start_date") ?? DateOnly(year: 1970, month: 1, day: 1),
      endDate: RowMapping.day(row, "end_date") ?? DateOnly(year: 1970, month: 1, day: 1),
      budgetE4: try RowMapping.optionalAmount(row, "budget_e4"),
      recurringYearly: try RowMapping.flag(row, "recurring_yearly", fallback: false),
      seriesId: RowMapping.optionalUUID(row, "series_id"),
      archived: try RowMapping.flag(row, "archived", fallback: false))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["kind"] = kind.rawValue
    container["start_date"] = startDate.iso
    container["end_date"] = endDate.iso
    container["budget_e4"] = budgetE4?.raw
    container["recurring_yearly"] = recurringYearly
    container["series_id"] = seriesId?.uuidString
    container["archived"] = archived
  }
}

extension Template: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "templates"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      text: row["text"] ?? "",
      categoryId: RowMapping.optionalUUID(row, "category_id"),
      amountE4: try RowMapping.optionalAmount(row, "amount_e4"),
      currency: (row["currency"] as String?).map(CurrencyCode.init),
      pinned: try RowMapping.flag(row, "pinned", fallback: false),
      useCount: try RowMapping.optionalInteger(row, "use_count") ?? 0,
      archived: try RowMapping.flag(row, "archived", fallback: false))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["text"] = text
    container["category_id"] = categoryId?.uuidString
    container["amount_e4"] = amountE4?.raw
    container["currency"] = currency?.code
    container["pinned"] = pinned
    container["use_count"] = useCount
    container["archived"] = archived
  }
}

/// `plan_start_month` is 'YYYY-MM', or NULL for a plan counted from the first contribution.
extension Goal: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "goals"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      targetE4: try RowMapping.amount(row, "target_e4"),
      targetDate: RowMapping.day(row, "target_date"),
      monthlyPlanE4: try RowMapping.optionalAmount(row, "monthly_plan_e4"),
      subcategoryId: RowMapping.optionalUUID(row, "subcategory_id"),
      archived: try RowMapping.flag(row, "archived", fallback: false),
      currency: CurrencyCode(row["currency"] ?? "RUB"),
      planStartMonth: RowMapping.month(row, "plan_start_month"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["target_e4"] = targetE4.raw
    container["target_date"] = targetDate?.iso
    container["monthly_plan_e4"] = monthlyPlanE4?.raw
    container["subcategory_id"] = subcategoryId?.uuidString
    container["archived"] = archived
    container["currency"] = currency.code
    container["plan_start_month"] = planStartMonth?.iso
  }
}

extension Rate: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "rates"

  public init(row: Row) throws {
    self.init(
      date: RowMapping.day(row, "date") ?? DateOnly(year: 1970, month: 1, day: 1),
      currency: CurrencyCode(row["currency"] ?? "RUB"),
      rubPerUnit: RowMapping.decimal(row, "rub_per_unit") ?? 0,
      nominal: try RowMapping.optionalInteger(row, "nominal") ?? 1,
      source: RateSource(rawValue: row["source"] ?? "cbr") ?? .cbr,
      fetchedAt: RowMapping.readableInstant(row, "fetched_at"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["date"] = date.iso
    container["currency"] = currency.code
    container["rub_per_unit"] = RowMapping.string(rubPerUnit)
    container["nominal"] = nominal
    container["source"] = source.rawValue
    container["fetched_at"] = StoredInstant.databaseValue(fetchedAt)
  }
}
