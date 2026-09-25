import CoreKit
import Foundation

// Column names drop the `_e4` suffix the SQL schema uses: the files carry amounts as
// decimal strings with a dot, not stored units of 1/10000, and a header that said `amount_e4`
// would promise something the value is not. The way back is plain: the CSV value times
// 10 000, rounded, is what the `*_e4` column of the database holds.

/// One CSV file: its file name and its column order. This is the single source of truth
/// for both the Export feature and the `data/csv/` folder of the transfer archive, so
/// column order must never change once a table ships — old exports and old archives must
/// keep meaning the same thing. Column names are the field names of the SQL schema
/// (`Schema/0001_initial.sql`) in snake_case, in the order the schema declares them; a column
/// a later migration adds goes last, and a table it adds goes at the end of the list.
public struct ExportTable: Hashable, Sendable {
  public let fileName: String
  public let columns: [String]

  public init(fileName: String, columns: [String]) {
    self.fileName = fileName
    self.columns = columns
  }
}

/// The 21 files of Export, always in the same order.
public enum ExportTables {
  /// `account_currency` and `account_amount` came with `Schema/0004_accounts.sql`: what the
  /// account moved when it does not hold the operation's currency.
  public static let transactions = ExportTable(
    fileName: "transactions.csv",
    columns: [
      "id", "kind", "occurred_at", "currency", "amount", "amount_expr", "rate",
      "rate_date", "rate_source", "rate_provisional", "amount_rub", "note", "place_id",
      "payment_method_id", "period_month", "debt_id", "credit_debt_id", "import_batch_id",
      "external_id", "created_at", "updated_at", "deleted_at", "account_currency",
      "account_amount",
    ])

  /// `refund_of_part_id` came with `Schema/0004_accounts.sql`: the purchase part a refund
  /// takes money back from.
  public static let transactionParts = ExportTable(
    fileName: "transaction_parts.csv",
    columns: [
      "id", "transaction_id", "category_id", "category_source", "quality", "quality_source",
      "amount", "amount_rub", "for_whom", "for_person_id", "reimbursable",
      "debtor_person_id", "reimbursement_status", "event_id", "goal_id", "note",
      "refund_of_part_id",
    ])

  public static let reimbursementLinks = ExportTable(
    fileName: "reimbursement_links.csv",
    columns: ["id", "reimbursement_tx_id", "part_id", "amount"])

  public static let people = ExportTable(
    fileName: "people.csv",
    columns: ["id", "name", "relation", "aliases", "archived"])

  /// The accounts. `group_id`, `sort` and `other_currencies` came with
  /// `Schema/0004_accounts.sql`; `other_currencies` holds the codes after the main one,
  /// joined by commas as the database keeps them (`USD,RUB,KZT`).
  public static let paymentMethods = ExportTable(
    fileName: "payment_methods.csv",
    columns: [
      "id", "name", "kind", "currency", "aliases", "is_default", "archived", "group_id", "sort",
      "other_currencies",
    ])

  public static let places = ExportTable(
    fileName: "places.csv",
    columns: ["id", "name", "aliases", "archived"])

  public static let events = ExportTable(
    fileName: "events.csv",
    columns: [
      "id", "name", "kind", "start_date", "end_date", "budget", "recurring_yearly",
      "series_id", "archived",
    ])

  public static let categories = ExportTable(
    fileName: "categories.csv",
    columns: ["id", "parent_id", "kind", "name", "sort", "archived", "quality", "system_role"])

  /// `archived` came with `Schema/0004_accounts.sql`.
  public static let templates = ExportTable(
    fileName: "templates.csv",
    columns: [
      "id", "text", "category_id", "amount", "currency", "pinned", "use_count", "archived",
    ])

  /// Columns match `Schema/0001_initial.sql`.
  public static let scheduledPayments = ExportTable(
    fileName: "scheduled_payments.csv",
    columns: [
      "id", "name", "kind", "amount", "currency", "category_id", "payment_method_id",
      "for_whom", "for_person_id", "reimbursable", "debtor_person_id",
      "reimbursement_amount", "reimbursement_currency", "freq", "interval", "day",
      "month", "next_date", "end_date", "trial_end", "cancel_url", "remind_days_before",
      "active",
    ])

  /// Columns match `Schema/0001_initial.sql`.
  public static let subscriptionPrices = ExportTable(
    fileName: "subscription_prices.csv",
    columns: ["id", "payment_id", "date", "amount"])

  /// Columns match `Schema/0001_initial.sql`. `expected_income_links` is not one of the 18
  /// files: the links travel in the archive's database.
  public static let expectedIncome = ExportTable(
    fileName: "expected_income.csv",
    columns: [
      "id", "name", "category_id", "person_id", "kind", "total", "currency", "due_date",
      "freq", "day", "parts_expected", "closed",
    ])

  /// Columns match `Schema/0001_initial.sql`; `start_month` came with
  /// `Schema/0002_planning.sql` and goes last, so every older column keeps its place.
  public static let budgets = ExportTable(
    fileName: "budgets.csv",
    columns: ["id", "scope", "category_id", "for_whom", "amount", "rollover", "start_month"])

  /// `currency` came with `Schema/0004_accounts.sql`: the target, the plan and the progress
  /// are in it.
  public static let goals = ExportTable(
    fileName: "goals.csv",
    columns: [
      "id", "name", "target", "target_date", "monthly_plan", "subcategory_id",
      "archived", "currency",
    ])

  public static let debts = ExportTable(
    fileName: "debts.csv",
    columns: [
      "id", "direction", "type", "name", "person_id", "currency", "interest_rate",
      "monthly_payment", "payment_day", "remind_days_before", "payments_are_expenses",
      "origin", "note", "closed", "loans_subcategory_id",
    ])

  /// `payment_method_id`, `occurred_at`, `account_currency` and `account_amount` came with
  /// `Schema/0004_accounts.sql`: the account money borrowed or lent through the journal alone
  /// went into or out of, when, and what moved on it.
  public static let debtEntries = ExportTable(
    fileName: "debt_entries.csv",
    columns: [
      "id", "debt_id", "group_name", "date", "description", "full_amount", "share",
      "amount", "kind", "transaction_id", "note", "payment_method_id", "occurred_at",
      "account_currency", "account_amount",
    ])

  /// Columns match `Schema/0001_initial.sql`; `reconciled_at` and `breakdown` came with
  /// `Schema/0002_planning.sql` and go last, so every older column keeps its place. The
  /// breakdown is the JSON text of the database column (`ReconciliationBreakdown`). `kind`
  /// came with `Schema/0004_accounts.sql`.
  public static let reconciliations = ExportTable(
    fileName: "reconciliations.csv",
    columns: [
      "id", "date", "actual_total_rub", "expected_total_rub", "difference",
      "transaction_id", "reconciled_at", "breakdown", "kind",
    ])

  /// No `id` column: the schema's primary key is `(date, currency, source)`. `rub_per_unit`
  /// keeps the schema's name but carries the rate as published — rubles per `nominal` units
  /// (56.2349 for 100 JPY); per one unit it is `rub_per_unit / nominal`.
  public static let rates = ExportTable(
    fileName: "rates.csv",
    columns: ["date", "currency", "rub_per_unit", "nominal", "source", "fetched_at"])

  /// Columns match `Schema/0004_accounts.sql`.
  public static let accountGroups = ExportTable(
    fileName: "account_groups.csv",
    columns: ["id", "name", "in_summary", "sort", "archived"])

  /// Columns match `Schema/0004_accounts.sql`.
  public static let transfers = ExportTable(
    fileName: "transfers.csv",
    columns: [
      "id", "occurred_at", "from_payment_method_id", "from_currency", "from_amount",
      "to_payment_method_id", "to_currency", "to_amount", "note", "created_at", "updated_at",
    ])

  /// Columns match `Schema/0004_accounts.sql`. Amounts are in the row's currency; an empty
  /// `expected` marks the first count of the account and currency.
  public static let reconciliationBalances = ExportTable(
    fileName: "reconciliation_balances.csv",
    columns: [
      "id", "reconciliation_id", "payment_method_id", "currency", "actual", "expected",
      "difference", "transaction_id",
    ])

  /// All 21 tables, in the fixed order of the export: the 18 of the first schema, then the
  /// three the accounts brought.
  public static let all: [ExportTable] = [
    transactions, transactionParts, reimbursementLinks, people, paymentMethods, places,
    events, categories, templates, scheduledPayments, subscriptionPrices, expectedIncome,
    budgets, goals, debts, debtEntries, reconciliations, rates, accountGroups, transfers,
    reconciliationBalances,
  ]
}

// MARK: - Row serialization

/// Turns one `CoreKit` record into a CSV row matching the column order declared above.
extension ExportTables {
  public static func row(_ transaction: Transaction) -> [String] {
    [
      transaction.id.uuidString,
      transaction.kind.rawValue,
      CSVValue.string(instant: transaction.occurredAt),
      transaction.currency.code,
      CSVValue.string(amount: transaction.amountE4),
      CSVValue.string(transaction.amountExpr),
      CSVValue.string(decimal: transaction.rate),
      CSVValue.string(day: transaction.rateDate),
      CSVValue.string(transaction.rateSource?.rawValue),
      CSVValue.string(bool: transaction.rateProvisional),
      CSVValue.string(amount: transaction.amountRubE4),
      CSVValue.string(transaction.note),
      CSVValue.string(transaction.placeId),
      CSVValue.string(transaction.paymentMethodId),
      CSVValue.string(month: transaction.periodMonth),
      CSVValue.string(transaction.debtId),
      CSVValue.string(transaction.creditDebtId),
      CSVValue.string(transaction.importBatchId),
      CSVValue.string(transaction.externalId),
      CSVValue.string(instant: transaction.createdAt),
      CSVValue.string(instant: transaction.updatedAt),
      CSVValue.string(instant: transaction.deletedAt),
      CSVValue.string(transaction.accountCurrency?.code),
      CSVValue.string(amount: transaction.accountAmountE4),
    ]
  }

  public static func row(_ part: TransactionPart) -> [String] {
    [
      part.id.uuidString,
      part.transactionId.uuidString,
      CSVValue.string(part.categoryId),
      part.categorySource.rawValue,
      CSVValue.string(part.quality?.rawValue),
      CSVValue.string(part.qualitySource?.rawValue),
      CSVValue.string(amount: part.amountE4),
      CSVValue.string(amount: part.amountRubE4),
      part.forWhom.rawValue,
      CSVValue.string(part.forPersonId),
      CSVValue.string(bool: part.reimbursable),
      CSVValue.string(part.debtorPersonId),
      CSVValue.string(part.reimbursementStatus?.rawValue),
      CSVValue.string(part.eventId),
      CSVValue.string(part.goalId),
      CSVValue.string(part.note),
      CSVValue.string(part.refundOfPartId),
    ]
  }

  public static func row(_ link: ReimbursementLink) -> [String] {
    [
      link.id.uuidString,
      link.reimbursementTxId.uuidString,
      link.partId.uuidString,
      CSVValue.string(amount: link.amountE4),
    ]
  }

  public static func row(_ person: Person) -> [String] {
    [
      person.id.uuidString,
      person.name,
      person.relation.rawValue,
      CSVValue.string(joining: person.aliases),
      CSVValue.string(bool: person.archived),
    ]
  }

  public static func row(_ method: PaymentMethod) -> [String] {
    [
      method.id.uuidString,
      method.name,
      method.kind.rawValue,
      CSVValue.string(method.currency?.code),
      CSVValue.string(joining: method.aliases),
      CSVValue.string(bool: method.isDefault),
      CSVValue.string(bool: method.archived),
      CSVValue.string(method.groupId),
      String(method.sort),
      method.otherCurrencies.map(\.code).joined(separator: ","),
    ]
  }

  public static func row(_ place: Place) -> [String] {
    [
      place.id.uuidString,
      place.name,
      CSVValue.string(joining: place.aliases),
      CSVValue.string(bool: place.archived),
    ]
  }

  public static func row(_ event: Event) -> [String] {
    [
      event.id.uuidString,
      event.name,
      event.kind.rawValue,
      CSVValue.string(day: event.startDate),
      CSVValue.string(day: event.endDate),
      CSVValue.string(amount: event.budgetE4),
      CSVValue.string(bool: event.recurringYearly),
      CSVValue.string(event.seriesId),
      CSVValue.string(bool: event.archived),
    ]
  }

  public static func row(_ category: CoreKit.Category) -> [String] {
    [
      category.id.uuidString,
      CSVValue.string(category.parentId),
      category.kind.rawValue,
      category.name,
      String(category.sort),
      CSVValue.string(bool: category.archived),
      CSVValue.string(category.quality?.rawValue),
      CSVValue.string(category.systemRole?.rawValue),
    ]
  }

  public static func row(_ template: Template) -> [String] {
    [
      template.id.uuidString,
      template.text,
      CSVValue.string(template.categoryId),
      CSVValue.string(amount: template.amountE4),
      CSVValue.string(template.currency?.code),
      CSVValue.string(bool: template.pinned),
      String(template.useCount),
      CSVValue.string(bool: template.archived),
    ]
  }

  public static func row(_ goal: Goal) -> [String] {
    [
      goal.id.uuidString,
      goal.name,
      CSVValue.string(amount: goal.targetE4),
      CSVValue.string(day: goal.targetDate),
      CSVValue.string(amount: goal.monthlyPlanE4),
      CSVValue.string(goal.subcategoryId),
      CSVValue.string(bool: goal.archived),
      goal.currency.code,
    ]
  }

  public static func row(_ debt: Debt) -> [String] {
    [
      debt.id.uuidString,
      debt.direction.rawValue,
      debt.type.rawValue,
      debt.name,
      CSVValue.string(debt.personId),
      debt.currency.code,
      CSVValue.string(decimal: debt.interestRate),
      CSVValue.string(amount: debt.monthlyPaymentE4),
      CSVValue.string(debt.paymentDay),
      CSVValue.string(debt.remindDaysBefore),
      CSVValue.string(bool: debt.paymentsAreExpenses),
      debt.origin.rawValue,
      CSVValue.string(debt.note),
      CSVValue.string(bool: debt.closed),
      CSVValue.string(debt.loansSubcategoryId),
    ]
  }

  public static func row(_ entry: DebtEntry) -> [String] {
    [
      entry.id.uuidString,
      entry.debtId.uuidString,
      CSVValue.string(entry.groupName),
      CSVValue.string(day: entry.date),
      CSVValue.string(entry.description),
      CSVValue.string(amount: entry.fullAmountE4),
      CSVValue.string(decimal: entry.share),
      CSVValue.string(amount: entry.amountE4),
      entry.kind.rawValue,
      CSVValue.string(entry.transactionId),
      CSVValue.string(entry.note),
      CSVValue.string(entry.paymentMethodId),
      CSVValue.string(instant: entry.occurredAt),
      CSVValue.string(entry.accountCurrency?.code),
      CSVValue.string(amount: entry.accountAmountE4),
    ]
  }

  public static func row(_ payment: ScheduledPayment) -> [String] {
    [
      payment.id.uuidString,
      payment.name,
      payment.kind.rawValue,
      CSVValue.string(amount: payment.amountE4),
      payment.currency.code,
      CSVValue.string(payment.categoryId),
      CSVValue.string(payment.paymentMethodId),
      payment.forWhom.rawValue,
      CSVValue.string(payment.forPersonId),
      CSVValue.string(bool: payment.reimbursable),
      CSVValue.string(payment.debtorPersonId),
      CSVValue.string(amount: payment.reimbursementAmountE4),
      CSVValue.string(payment.reimbursementCurrency?.code),
      payment.freq.rawValue,
      String(payment.interval),
      CSVValue.string(payment.day),
      CSVValue.string(payment.month),
      CSVValue.string(day: payment.nextDate),
      CSVValue.string(day: payment.endDate),
      CSVValue.string(day: payment.trialEnd),
      CSVValue.string(payment.cancelURL),
      CSVValue.string(payment.remindDaysBefore),
      CSVValue.string(bool: payment.active),
    ]
  }

  public static func row(_ price: SubscriptionPrice) -> [String] {
    [
      price.id.uuidString,
      price.paymentId.uuidString,
      CSVValue.string(day: price.date),
      CSVValue.string(amount: price.amountE4),
    ]
  }

  public static func row(_ income: ExpectedIncome) -> [String] {
    [
      income.id.uuidString,
      income.name,
      CSVValue.string(income.categoryId),
      CSVValue.string(income.personId),
      income.kind.rawValue,
      CSVValue.string(amount: income.totalE4),
      income.currency.code,
      CSVValue.string(day: income.dueDate),
      CSVValue.string(income.freq?.rawValue),
      CSVValue.string(income.day),
      String(income.partsExpected),
      CSVValue.string(bool: income.closed),
    ]
  }

  public static func row(_ budget: Budget) -> [String] {
    [
      budget.id.uuidString,
      budget.scope.rawValue,
      CSVValue.string(budget.categoryId),
      CSVValue.string(budget.forWhom?.rawValue),
      CSVValue.string(amount: budget.amountE4),
      CSVValue.string(bool: budget.rollover),
      CSVValue.string(month: budget.startMonth),
    ]
  }

  public static func row(_ reconciliation: Reconciliation) -> [String] {
    [
      reconciliation.id.uuidString,
      CSVValue.string(day: reconciliation.date),
      CSVValue.string(amount: reconciliation.actualTotalRubE4),
      CSVValue.string(amount: reconciliation.expectedTotalRubE4),
      CSVValue.string(amount: reconciliation.differenceE4),
      CSVValue.string(reconciliation.transactionId),
      CSVValue.string(instant: reconciliation.reconciledAt),
      CSVValue.string(ReconciliationBreakdown.json(reconciliation.breakdown)),
      reconciliation.kind.rawValue,
    ]
  }

  public static func row(_ rate: Rate) -> [String] {
    [
      CSVValue.string(day: rate.date),
      rate.currency.code,
      CSVValue.string(decimal: rate.rubPerUnit),
      String(rate.nominal),
      rate.source.rawValue,
      CSVValue.string(instant: rate.fetchedAt),
    ]
  }

  public static func row(_ group: AccountGroup) -> [String] {
    [
      group.id.uuidString,
      group.name,
      CSVValue.string(bool: group.inSummary),
      String(group.sort),
      CSVValue.string(bool: group.archived),
    ]
  }

  public static func row(_ transfer: Transfer) -> [String] {
    [
      transfer.id.uuidString,
      CSVValue.string(instant: transfer.occurredAt),
      transfer.fromAccountId.uuidString,
      transfer.fromCurrency.code,
      CSVValue.string(amount: transfer.fromAmountE4),
      transfer.toAccountId.uuidString,
      transfer.toCurrency.code,
      CSVValue.string(amount: transfer.toAmountE4),
      CSVValue.string(transfer.note),
      CSVValue.string(instant: transfer.createdAt),
      CSVValue.string(instant: transfer.updatedAt),
    ]
  }

  public static func row(_ balance: ReconciledBalance) -> [String] {
    [
      balance.id.uuidString,
      balance.reconciliationId.uuidString,
      balance.accountId.uuidString,
      balance.currency.code,
      CSVValue.string(amount: balance.actualE4),
      CSVValue.string(amount: balance.expectedE4),
      CSVValue.string(amount: balance.differenceE4),
      CSVValue.string(balance.transactionId),
    ]
  }
}

// MARK: - Breakdown of a reconciliation

/// A reconciliation's breakdown by currency as one JSON text — the way the
/// `reconciliations.breakdown` column keeps it (`Schema/0002_planning.sql`) and the way
/// `reconciliations.csv` carries it, so the database, the export and the archive spell it
/// alike and the Windows port needs one reader:
///
///     [{"amount_e4":1000000,"currency":"USD","rub_e4":81430000,"rub_per_unit":"81.43"}]
///
/// Keys are sorted, so the same breakdown is always the same text. The amounts are integers
/// in 1/10000, as their names say — the one place a file carries stored units, and the key
/// tells so. The rate is a decimal string with a dot, never a JSON number, which a reader
/// would take for a floating-point value; it is `null` for rubles. No breakdown is no text.
public enum ReconciliationBreakdown {
  public static func json(_ amounts: [ReconciliationAmount]) -> String? {
    guard !amounts.isEmpty else { return nil }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(amounts.map(Line.init)) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  /// The breakdown a column or a cell holds; empty for no text and for text that is not a
  /// breakdown. A line whose rate does not read as a number keeps no rate.
  public static func amounts(fromJSON text: String?) -> [ReconciliationAmount] {
    guard let text, !text.isEmpty,
      let lines = try? JSONDecoder().decode([Line].self, from: Data(text.utf8))
    else { return [] }
    return lines.map(\.amount)
  }

  private static let posix = Locale(identifier: "en_US_POSIX")

  private struct Line: Codable {
    var currency: String
    var amountE4: Int64
    var rubPerUnit: String?
    var rubE4: Int64

    enum CodingKeys: String, CodingKey {
      case currency
      case amountE4 = "amount_e4"
      case rubPerUnit = "rub_per_unit"
      case rubE4 = "rub_e4"
    }

    init(_ amount: ReconciliationAmount) {
      currency = amount.currency.code
      amountE4 = amount.amountE4.raw
      rubPerUnit = amount.rubPerUnit.map { CSVValue.string(decimal: $0) }
      rubE4 = amount.rubE4.raw
    }

    init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      currency = try container.decode(String.self, forKey: .currency)
      amountE4 = try container.decode(Int64.self, forKey: .amountE4)
      rubPerUnit = try container.decodeIfPresent(String.self, forKey: .rubPerUnit)
      rubE4 = try container.decode(Int64.self, forKey: .rubE4)
    }

    /// Every line has all four keys: an absent rate is written as `null`, not left out.
    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(currency, forKey: .currency)
      try container.encode(amountE4, forKey: .amountE4)
      try container.encode(rubPerUnit, forKey: .rubPerUnit)
      try container.encode(rubE4, forKey: .rubE4)
    }

    var amount: ReconciliationAmount {
      ReconciliationAmount(
        currency: CurrencyCode(currency),
        amountE4: AmountE4(raw: amountE4),
        rubPerUnit: rubPerUnit.flatMap {
          Decimal(string: $0, locale: ReconciliationBreakdown.posix)
        },
        rubE4: AmountE4(raw: rubE4))
    }
  }
}
