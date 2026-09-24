import CoreKit
import Foundation
import GRDB

extension CoreKit.Transaction: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "transactions"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      kind: TransactionKind(rawValue: row["kind"] ?? "expense") ?? .expense,
      occurredAt: row["occurred_at"] ?? Date(timeIntervalSince1970: 0),
      currency: CurrencyCode(row["currency"] ?? "RUB"),
      amountE4: RowMapping.amount(row, "amount_e4"),
      amountExpr: row["amount_expr"],
      rate: RowMapping.decimal(row, "rate"),
      rateDate: RowMapping.day(row, "rate_date"),
      rateSource: (row["rate_source"] as String?).flatMap(RateSource.init(rawValue:)),
      rateProvisional: row["rate_provisional"] ?? false,
      amountRubE4: RowMapping.amount(row, "amount_rub_e4"),
      note: row["note"],
      placeId: RowMapping.optionalUUID(row, "place_id"),
      paymentMethodId: RowMapping.optionalUUID(row, "payment_method_id"),
      periodMonth: RowMapping.month(row, "period_month"),
      debtId: RowMapping.optionalUUID(row, "debt_id"),
      creditDebtId: RowMapping.optionalUUID(row, "credit_debt_id"),
      importBatchId: RowMapping.optionalUUID(row, "import_batch_id"),
      externalId: row["external_id"],
      createdAt: row["created_at"] ?? Date(timeIntervalSince1970: 0),
      updatedAt: row["updated_at"] ?? Date(timeIntervalSince1970: 0),
      deletedAt: row["deleted_at"])
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["kind"] = kind.rawValue
    container["occurred_at"] = occurredAt
    container["currency"] = currency.code
    container["amount_e4"] = amountE4.raw
    container["amount_expr"] = amountExpr
    container["rate"] = RowMapping.string(rate)
    container["rate_date"] = rateDate?.iso
    container["rate_source"] = rateSource?.rawValue
    container["rate_provisional"] = rateProvisional
    container["amount_rub_e4"] = amountRubE4.raw
    container["note"] = note
    container["place_id"] = placeId?.uuidString
    container["payment_method_id"] = paymentMethodId?.uuidString
    container["period_month"] = periodMonth?.iso
    container["debt_id"] = debtId?.uuidString
    container["credit_debt_id"] = creditDebtId?.uuidString
    container["import_batch_id"] = importBatchId?.uuidString
    container["external_id"] = externalId
    container["created_at"] = createdAt
    container["updated_at"] = updatedAt
    container["deleted_at"] = deletedAt
  }
}

extension TransactionPart: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "transaction_parts"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      transactionId: try RowMapping.uuid(row, "transaction_id"),
      categoryId: RowMapping.optionalUUID(row, "category_id"),
      categorySource: CategorySource(rawValue: row["category_source"] ?? "manual") ?? .manual,
      quality: (row["quality"] as String?).flatMap(Quality.init(rawValue:)),
      qualitySource: (row["quality_source"] as String?).flatMap(QualitySource.init(rawValue:)),
      amountE4: RowMapping.amount(row, "amount_e4"),
      amountRubE4: RowMapping.amount(row, "amount_rub_e4"),
      forWhom: ForWhom(rawValue: row["for_whom"] ?? "me") ?? .me,
      forPersonId: RowMapping.optionalUUID(row, "for_person_id"),
      reimbursable: row["reimbursable"] ?? false,
      debtorPersonId: RowMapping.optionalUUID(row, "debtor_person_id"),
      reimbursementStatus: (row["reimbursement_status"] as String?)
        .flatMap(ReimbursementStatus.init(rawValue:)),
      eventId: RowMapping.optionalUUID(row, "event_id"),
      goalId: RowMapping.optionalUUID(row, "goal_id"),
      note: row["note"])
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["transaction_id"] = transactionId.uuidString
    container["category_id"] = categoryId?.uuidString
    container["category_source"] = categorySource.rawValue
    container["quality"] = quality?.rawValue
    container["quality_source"] = qualitySource?.rawValue
    container["amount_e4"] = amountE4.raw
    container["amount_rub_e4"] = amountRubE4.raw
    container["for_whom"] = forWhom.rawValue
    container["for_person_id"] = forPersonId?.uuidString
    container["reimbursable"] = reimbursable
    container["debtor_person_id"] = debtorPersonId?.uuidString
    container["reimbursement_status"] = reimbursementStatus?.rawValue
    container["event_id"] = eventId?.uuidString
    container["goal_id"] = goalId?.uuidString
    container["note"] = note
  }
}

extension ReimbursementLink: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "reimbursement_links"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      reimbursementTxId: try RowMapping.uuid(row, "reimbursement_tx_id"),
      partId: try RowMapping.uuid(row, "part_id"),
      amountE4: RowMapping.amount(row, "amount_e4"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["reimbursement_tx_id"] = reimbursementTxId.uuidString
    container["part_id"] = partId.uuidString
    container["amount_e4"] = amountE4.raw
  }
}

extension Debt: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "debts"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      direction: DebtDirection(rawValue: row["direction"] ?? "i_owe") ?? .iOwe,
      type: DebtType(rawValue: row["type"] ?? "personal") ?? .personal,
      name: row["name"] ?? "",
      personId: RowMapping.optionalUUID(row, "person_id"),
      currency: CurrencyCode(row["currency"] ?? "RUB"),
      interestRate: RowMapping.decimal(row, "interest_rate"),
      monthlyPaymentE4: RowMapping.optionalAmount(row, "monthly_payment_e4"),
      paymentDay: row["payment_day"],
      remindDaysBefore: row["remind_days_before"],
      paymentsAreExpenses: row["payments_are_expenses"] ?? true,
      origin: DebtOrigin(rawValue: row["origin"] ?? "existing") ?? .existing,
      note: row["note"],
      closed: row["closed"] ?? false,
      loansSubcategoryId: RowMapping.optionalUUID(row, "loans_subcategory_id"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["direction"] = direction.rawValue
    container["type"] = type.rawValue
    container["name"] = name
    container["person_id"] = personId?.uuidString
    container["currency"] = currency.code
    container["interest_rate"] = RowMapping.string(interestRate)
    container["monthly_payment_e4"] = monthlyPaymentE4?.raw
    container["payment_day"] = paymentDay
    container["remind_days_before"] = remindDaysBefore
    container["payments_are_expenses"] = paymentsAreExpenses
    container["origin"] = origin.rawValue
    container["note"] = note
    container["closed"] = closed
    container["loans_subcategory_id"] = loansSubcategoryId?.uuidString
  }
}

extension DebtEntry: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "debt_entries"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      debtId: try RowMapping.uuid(row, "debt_id"),
      groupName: row["group_name"],
      date: RowMapping.day(row, "date"),
      description: row["description"],
      fullAmountE4: RowMapping.optionalAmount(row, "full_amount_e4"),
      share: RowMapping.decimal(row, "share"),
      amountE4: RowMapping.amount(row, "amount_e4"),
      kind: DebtEntryKind(rawValue: row["kind"] ?? "adjustment") ?? .adjustment,
      transactionId: RowMapping.optionalUUID(row, "transaction_id"),
      note: row["note"])
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["debt_id"] = debtId.uuidString
    container["group_name"] = groupName
    container["date"] = date?.iso
    container["description"] = description
    container["full_amount_e4"] = fullAmountE4?.raw
    container["share"] = RowMapping.string(share)
    container["amount_e4"] = amountE4.raw
    container["kind"] = kind.rawValue
    container["transaction_id"] = transactionId?.uuidString
    container["note"] = note
  }
}
