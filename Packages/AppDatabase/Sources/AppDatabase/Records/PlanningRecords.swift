import AppCore
import CoreKit
import Foundation
import GRDB

// The tables of the planning and the debts (`Schema/0001_initial.sql`,
// `Schema/0002_planning.sql`), mapped by hand like every other record (`RowMapping`).

extension ScheduledPayment: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "scheduled_payments"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      kind: ScheduledKind(rawValue: row["kind"] ?? "bill") ?? .bill,
      amountE4: try RowMapping.amount(row, "amount_e4"),
      currency: CurrencyCode(row["currency"] ?? "RUB"),
      categoryId: RowMapping.optionalUUID(row, "category_id"),
      paymentMethodId: RowMapping.optionalUUID(row, "payment_method_id"),
      forWhom: ForWhom(rawValue: row["for_whom"] ?? "me") ?? .me,
      forPersonId: RowMapping.optionalUUID(row, "for_person_id"),
      reimbursable: try RowMapping.flag(row, "reimbursable", fallback: false),
      debtorPersonId: RowMapping.optionalUUID(row, "debtor_person_id"),
      reimbursementAmountE4: try RowMapping.optionalAmount(row, "reimbursement_amount_e4"),
      reimbursementCurrency: (row["reimbursement_currency"] as String?).map(CurrencyCode.init),
      freq: Frequency(rawValue: row["freq"] ?? "monthly") ?? .monthly,
      interval: try RowMapping.optionalInteger(row, "interval") ?? 1,
      day: try RowMapping.optionalInteger(row, "day"),
      month: try RowMapping.optionalInteger(row, "month"),
      nextDate: RowMapping.day(row, "next_date"),
      endDate: RowMapping.day(row, "end_date"),
      trialEnd: RowMapping.day(row, "trial_end"),
      cancelURL: row["cancel_url"],
      remindDaysBefore: try RowMapping.optionalInteger(row, "remind_days_before"),
      active: try RowMapping.flag(row, "active", fallback: true))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["kind"] = kind.rawValue
    container["amount_e4"] = amountE4.raw
    container["currency"] = currency.code
    container["category_id"] = categoryId?.uuidString
    container["payment_method_id"] = paymentMethodId?.uuidString
    container["for_whom"] = forWhom.rawValue
    container["for_person_id"] = forPersonId?.uuidString
    container["reimbursable"] = reimbursable
    container["debtor_person_id"] = debtorPersonId?.uuidString
    container["reimbursement_amount_e4"] = reimbursementAmountE4?.raw
    container["reimbursement_currency"] = reimbursementCurrency?.code
    container["freq"] = freq.rawValue
    container["interval"] = interval
    container["day"] = day
    container["month"] = month
    container["next_date"] = nextDate?.iso
    container["end_date"] = endDate?.iso
    container["trial_end"] = trialEnd?.iso
    container["cancel_url"] = cancelURL
    container["remind_days_before"] = remindDaysBefore
    container["active"] = active
  }
}

extension SubscriptionPrice: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "subscription_prices"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      paymentId: try RowMapping.uuid(row, "payment_id"),
      date: RowMapping.day(row, "date") ?? DateOnly(year: 1970, month: 1, day: 1),
      amountE4: try RowMapping.amount(row, "amount_e4"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["payment_id"] = paymentId.uuidString
    container["date"] = date.iso
    container["amount_e4"] = amountE4.raw
  }
}

extension ExpectedIncome: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "expected_income"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      name: row["name"] ?? "",
      categoryId: RowMapping.optionalUUID(row, "category_id"),
      personId: RowMapping.optionalUUID(row, "person_id"),
      kind: ExpectedIncomeKind(rawValue: row["kind"] ?? "one_off") ?? .oneOff,
      totalE4: try RowMapping.amount(row, "total_e4"),
      currency: CurrencyCode(row["currency"] ?? "RUB"),
      dueDate: RowMapping.day(row, "due_date"),
      freq: (row["freq"] as String?).flatMap(Frequency.init(rawValue:)),
      day: try RowMapping.optionalInteger(row, "day"),
      partsExpected: try RowMapping.optionalInteger(row, "parts_expected") ?? 1,
      closed: try RowMapping.flag(row, "closed", fallback: false))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["category_id"] = categoryId?.uuidString
    container["person_id"] = personId?.uuidString
    container["kind"] = kind.rawValue
    container["total_e4"] = totalE4.raw
    container["currency"] = currency.code
    container["due_date"] = dueDate?.iso
    container["freq"] = freq?.rawValue
    container["day"] = day
    container["parts_expected"] = partsExpected
    container["closed"] = closed
  }
}

extension ExpectedIncomeLink: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "expected_income_links"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      expectedIncomeId: try RowMapping.uuid(row, "expected_income_id"),
      transactionId: try RowMapping.uuid(row, "transaction_id"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["expected_income_id"] = expectedIncomeId.uuidString
    container["transaction_id"] = transactionId.uuidString
  }
}

extension Budget: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "budgets"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      scope: BudgetScope(rawValue: row["scope"] ?? "category") ?? .category,
      categoryId: RowMapping.optionalUUID(row, "category_id"),
      forWhom: (row["for_whom"] as String?).flatMap(ForWhom.init(rawValue:)),
      amountE4: try RowMapping.amount(row, "amount_e4"),
      rollover: try RowMapping.flag(row, "rollover", fallback: false),
      startMonth: RowMapping.month(row, "start_month"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["scope"] = scope.rawValue
    container["category_id"] = categoryId?.uuidString
    container["for_whom"] = forWhom?.rawValue
    container["amount_e4"] = amountE4.raw
    container["rollover"] = rollover
    container["start_month"] = startMonth?.iso
  }
}

/// `reconciled_at` is an instant like `created_at` of an operation, so GRDB writes it the same
/// way — UTC text `YYYY-MM-DD HH:MM:SS.SSS`. The breakdown is one JSON text, spelled by
/// `ReconciliationBreakdown` so the database and the export files agree; NULL when there is
/// none. A `kind` this build does not know reads as a total, which anchors nothing.
extension Reconciliation: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "reconciliations"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      date: RowMapping.day(row, "date") ?? DateOnly(year: 1970, month: 1, day: 1),
      reconciledAt: try RowMapping.optionalInstant(row, "reconciled_at"),
      actualTotalRubE4: try RowMapping.amount(row, "actual_total_rub_e4"),
      expectedTotalRubE4: try RowMapping.optionalAmount(row, "expected_total_rub_e4"),
      differenceE4: try RowMapping.optionalAmount(row, "difference_e4"),
      transactionId: RowMapping.optionalUUID(row, "transaction_id"),
      breakdown: ReconciliationBreakdown.amounts(fromJSON: row["breakdown"]),
      kind: ReconciliationKind(rawValue: row["kind"] ?? "total") ?? .total)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["date"] = date.iso
    container["reconciled_at"] = reconciledAt
    container["actual_total_rub_e4"] = actualTotalRubE4.raw
    container["expected_total_rub_e4"] = expectedTotalRubE4?.raw
    container["difference_e4"] = differenceE4?.raw
    container["transaction_id"] = transactionId?.uuidString
    container["breakdown"] = ReconciliationBreakdown.json(breakdown)
    container["kind"] = kind.rawValue
  }
}

// MARK: Settings of the planning

/// `PlanningSettings` as rows of `settings`: numbers in decimal digits, switches as `1`/`0`
/// like the other switches of the table, the dismissed reminders one id per line, and so the
/// operations said not to pay a due date. How many limits to show is a number or `all`.
extension PlanningSettings {
  /// Every key the planning settings live under.
  public static let storageKeys = [
    reconcileEveryDaysKey, savingsTargetKey, reserveGoalPlanKey,
    reconcileIncludesGoalSavingsKey, dismissedRemindersKey, limitsTopNKey,
    scheduledMatchRejectionsKey,
  ]

  /// The settings the rows give. A key that is missing, or whose value does not read — or
  /// makes no sense, like a reminder every 0 days or a negative savings target — keeps its
  /// default: a damaged value must not stop the planning from being computed.
  public init(storedValues values: [String: String]) {
    let defaults = PlanningSettings()
    self.init(
      reconcileEveryDays: values[Self.reconcileEveryDaysKey].flatMap(Self.number)
        .flatMap { $0 > 0 ? $0 : nil } ?? defaults.reconcileEveryDays,
      savingsTargetBp: values[Self.savingsTargetKey].flatMap(Self.number)
        .flatMap { $0 >= 0 ? $0 : nil } ?? defaults.savingsTargetBp,
      reserveGoalPlan: values[Self.reserveGoalPlanKey].flatMap(Self.switchValue)
        ?? defaults.reserveGoalPlan,
      reconcileIncludesGoalSavings: values[Self.reconcileIncludesGoalSavingsKey]
        .flatMap(Self.switchValue) ?? defaults.reconcileIncludesGoalSavings,
      dismissedReminders: Set(RowMapping.split(values[Self.dismissedRemindersKey] ?? "")),
      limitsTopN: Self.limitsTopN(values[Self.limitsTopNKey], default: defaults.limitsTopN),
      scheduledMatchRejections: Set(
        RowMapping.split(values[Self.scheduledMatchRejectionsKey] ?? "")))
  }

  /// The rows to write, ready for `PlanningChange.settings`. No dismissed reminder deletes
  /// the key (`nil`): the table keeps no empty values. The ids are sorted, so the same set is
  /// always the same text.
  public var storedValues: [String: String?] {
    let dismissed = dismissedReminders.map(Self.singleLine).filter { !$0.isEmpty }.sorted()
    let rejections = scheduledMatchRejections.map(Self.singleLine).filter { !$0.isEmpty }
      .sorted()
    return [
      Self.reconcileEveryDaysKey: String(reconcileEveryDays),
      Self.savingsTargetKey: String(savingsTargetBp),
      Self.reserveGoalPlanKey: reserveGoalPlan ? "1" : "0",
      Self.reconcileIncludesGoalSavingsKey: reconcileIncludesGoalSavings ? "1" : "0",
      Self.dismissedRemindersKey: dismissed.isEmpty ? nil : dismissed.joined(separator: "\n"),
      Self.limitsTopNKey: limitsTopN.map { String($0) } ?? Self.allLimits,
      Self.scheduledMatchRejectionsKey: rejections.isEmpty
        ? nil : rejections.joined(separator: "\n"),
    ]
  }

  /// The value of `limitsTopNKey` that shows every limit.
  private static let allLimits = "all"

  /// A number above zero, or `all` for every limit (`nil`); anything else keeps the default.
  private static func limitsTopN(_ text: String?, default fallback: Int?) -> Int? {
    guard let text else { return fallback }
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.lowercased() == allLimits { return nil }
    guard let count = number(trimmed), count > 0 else { return fallback }
    return count
  }

  private static func number(_ text: String) -> Int? {
    Int(text.trimmingCharacters(in: .whitespaces))
  }

  /// `1`/`0` as the app writes switches; `true`/`false` as a person or the Windows port
  /// might.
  private static func switchValue(_ text: String) -> Bool? {
    switch text.trimmingCharacters(in: .whitespaces).lowercased() {
    case "1", "true": true
    case "0", "false": false
    default: nil
    }
  }

  /// A newline inside an id would read back as two ids.
  private static func singleLine(_ id: String) -> String {
    id.split(whereSeparator: \.isNewline).joined(separator: " ")
  }
}
