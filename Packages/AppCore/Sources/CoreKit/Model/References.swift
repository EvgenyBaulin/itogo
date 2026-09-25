import Foundation

/// Two levels: category → subcategory. A category is never deleted from under an operation:
/// its operations move to another category first, or it is archived; one still named by a
/// deleted operation can only be archived. System categories, and the subcategories of goals
/// and debts under them, cannot be renamed or removed.
public struct Category: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var parentId: UUID?
  public var kind: CategoryKind
  public var name: String
  public var sort: Int
  public var archived: Bool
  /// Empty on a subcategory: it inherits the quality of its parent.
  public var quality: Quality?
  public var systemRole: SystemRole?

  public init(
    id: UUID = UUID(),
    parentId: UUID? = nil,
    kind: CategoryKind,
    name: String,
    sort: Int = 0,
    archived: Bool = false,
    quality: Quality? = nil,
    systemRole: SystemRole? = nil
  ) {
    self.id = id
    self.parentId = parentId
    self.kind = kind
    self.name = name
    self.sort = sort
    self.archived = archived
    self.quality = quality
    self.systemRole = systemRole
  }

  public var isSystem: Bool { systemRole != nil }
  public var isSubcategory: Bool { parentId != nil }
  /// Limits are forbidden on system categories.
  public var acceptsLimit: Bool { systemRole == nil }
}

public struct Person: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  public var relation: PersonRelation
  public var aliases: [String]
  public var archived: Bool

  public init(
    id: UUID = UUID(), name: String, relation: PersonRelation = .other,
    aliases: [String] = [], archived: Bool = false
  ) {
    self.id = id
    self.name = name
    self.relation = relation
    self.aliases = aliases
    self.archived = archived
  }
}

public struct Place: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  public var aliases: [String]
  public var archived: Bool

  public init(id: UUID = UUID(), name: String, aliases: [String] = [], archived: Bool = false) {
    self.id = id
    self.name = name
    self.aliases = aliases
    self.archived = archived
  }
}

/// An account: a card, cash, a bank account. The table keeps its old name, and so does every
/// `payment_method_id` that points at it.
///
/// An account holds an ordered set of currencies: `currency` is the first, its main one, and
/// `otherCurrencies` the rest in the owner's order. Money is kept per account and currency.
/// `isDefault` marks the main account — exactly one live account has it — which comes first
/// in every list.
public struct PaymentMethod: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  public var kind: PaymentMethodKind
  /// The main currency. `nil` on an account saved without one, which counts as rubles.
  public var currency: CurrencyCode?
  public var aliases: [String]
  public var isDefault: Bool
  public var archived: Bool
  /// The group the account is filed under, if any.
  public var groupId: UUID?
  /// The place the owner dragged it to; 0 everywhere means alphabetical.
  public var sort: Int
  /// The currencies after the main one, in the owner's order.
  public var otherCurrencies: [CurrencyCode]

  public init(
    id: UUID = UUID(), name: String, kind: PaymentMethodKind = .card,
    currency: CurrencyCode? = nil, aliases: [String] = [], isDefault: Bool = false,
    archived: Bool = false, groupId: UUID? = nil, sort: Int = 0,
    otherCurrencies: [CurrencyCode] = []
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.currency = currency
    self.aliases = aliases
    self.isDefault = isDefault
    self.archived = archived
    self.groupId = groupId
    self.sort = sort
    self.otherCurrencies = otherCurrencies
  }

  /// The one account every operation without an account of its own belongs to.
  public var isMain: Bool { isDefault }

  /// The currency the account moves when an operation is in one it does not hold.
  public var mainCurrency: CurrencyCode { currency ?? .rub }

  /// Every currency the account holds, the main one first, each once.
  public var currencies: [CurrencyCode] {
    var seen: Set<CurrencyCode> = []
    return ([mainCurrency] + otherCurrencies).filter { seen.insert($0).inserted }
  }

  public func holds(_ currency: CurrencyCode) -> Bool {
    currency == mainCurrency || otherCurrencies.contains(currency)
  }
}

/// Birthdays, New Year, trips. Yearly events are recreated next year with the same
/// `seriesId` so the two years can be compared.
public struct Event: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  public var kind: EventKind
  public var startDate: DateOnly
  public var endDate: DateOnly
  public var budgetE4: AmountE4?
  public var recurringYearly: Bool
  public var seriesId: UUID?
  public var archived: Bool

  public init(
    id: UUID = UUID(), name: String, kind: EventKind = .other,
    startDate: DateOnly, endDate: DateOnly, budgetE4: AmountE4? = nil,
    recurringYearly: Bool = false, seriesId: UUID? = nil, archived: Bool = false
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.startDate = startDate
    self.endDate = endDate
    self.budgetE4 = budgetE4
    self.recurringYearly = recurringYearly
    self.seriesId = seriesId
    self.archived = archived
  }

  public func covers(_ day: DateOnly) -> Bool {
    day >= startDate && day <= endDate
  }
}

public struct Template: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var text: String
  public var categoryId: UUID?
  public var amountE4: AmountE4?
  public var currency: CurrencyCode?
  public var pinned: Bool
  public var useCount: Int
  /// Put away rather than deleted, so it can be brought back.
  public var archived: Bool

  public init(
    id: UUID = UUID(), text: String, categoryId: UUID? = nil, amountE4: AmountE4? = nil,
    currency: CurrencyCode? = nil, pinned: Bool = false, useCount: Int = 0,
    archived: Bool = false
  ) {
    self.id = id
    self.text = text
    self.categoryId = categoryId
    self.amountE4 = amountE4
    self.currency = currency
    self.pinned = pinned
    self.useCount = useCount
    self.archived = archived
  }
}

/// A saving goal. Contributions are good expenses in an automatically created
/// subcategory of the system Goals category.
public struct Goal: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  public var targetE4: AmountE4
  public var targetDate: DateOnly?
  public var monthlyPlanE4: AmountE4?
  public var subcategoryId: UUID?
  public var archived: Bool
  /// The currency of the target, the plan and the progress.
  public var currency: CurrencyCode

  public init(
    id: UUID = UUID(), name: String, targetE4: AmountE4, targetDate: DateOnly? = nil,
    monthlyPlanE4: AmountE4? = nil, subcategoryId: UUID? = nil, archived: Bool = false,
    currency: CurrencyCode = .rub
  ) {
    self.id = id
    self.name = name
    self.targetE4 = targetE4
    self.targetDate = targetDate
    self.monthlyPlanE4 = monthlyPlanE4
    self.subcategoryId = subcategoryId
    self.archived = archived
    self.currency = currency
  }
}

public struct Debt: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var direction: DebtDirection
  public var type: DebtType
  public var name: String
  public var personId: UUID?
  public var currency: CurrencyCode
  public var interestRate: Decimal?
  public var monthlyPaymentE4: AmountE4?
  public var paymentDay: Int?
  public var remindDaysBefore: Int?
  /// `true` for debts that existed before the app: their payments are expenses in Loans.
  public var paymentsAreExpenses: Bool
  public var origin: DebtOrigin
  public var note: String?
  public var closed: Bool
  public var loansSubcategoryId: UUID?

  public init(
    id: UUID = UUID(), direction: DebtDirection, type: DebtType, name: String,
    personId: UUID? = nil, currency: CurrencyCode = .rub, interestRate: Decimal? = nil,
    monthlyPaymentE4: AmountE4? = nil, paymentDay: Int? = nil, remindDaysBefore: Int? = nil,
    paymentsAreExpenses: Bool = true, origin: DebtOrigin = .existing, note: String? = nil,
    closed: Bool = false, loansSubcategoryId: UUID? = nil
  ) {
    self.id = id
    self.direction = direction
    self.type = type
    self.name = name
    self.personId = personId
    self.currency = currency
    self.interestRate = interestRate
    self.monthlyPaymentE4 = monthlyPaymentE4
    self.paymentDay = paymentDay
    self.remindDaysBefore = remindDaysBefore
    self.paymentsAreExpenses = paymentsAreExpenses
    self.origin = origin
    self.note = note
    self.closed = closed
    self.loansSubcategoryId = loansSubcategoryId
  }
}

/// One line of a debt journal. `amountE4` is signed: plus grows the debt, minus reduces it.
public struct DebtEntry: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var debtId: UUID
  public var groupName: String?
  public var date: DateOnly?
  public var description: String?
  public var fullAmountE4: AmountE4?
  public var share: Decimal?
  public var amountE4: AmountE4
  public var kind: DebtEntryKind
  public var transactionId: UUID?
  public var note: String?
  /// Money borrowed or lent through the journal alone, with no operation: the account it went
  /// into or out of (`nil` — the main account), when, and what moved on that account when it
  /// does not hold the debt's currency.
  public var paymentMethodId: UUID?
  public var occurredAt: Date?
  public var accountCurrency: CurrencyCode?
  public var accountAmountE4: AmountE4?

  public init(
    id: UUID = UUID(), debtId: UUID, groupName: String? = nil, date: DateOnly? = nil,
    description: String? = nil, fullAmountE4: AmountE4? = nil, share: Decimal? = nil,
    amountE4: AmountE4, kind: DebtEntryKind, transactionId: UUID? = nil, note: String? = nil,
    paymentMethodId: UUID? = nil, occurredAt: Date? = nil, accountCurrency: CurrencyCode? = nil,
    accountAmountE4: AmountE4? = nil
  ) {
    self.id = id
    self.debtId = debtId
    self.groupName = groupName
    self.date = date
    self.description = description
    self.fullAmountE4 = fullAmountE4
    self.share = share
    self.amountE4 = amountE4
    self.kind = kind
    self.transactionId = transactionId
    self.note = note
    self.paymentMethodId = paymentMethodId
    self.occurredAt = occurredAt
    self.accountCurrency = accountCurrency
    self.accountAmountE4 = accountAmountE4
  }
}

/// Links a reimbursement operation to the parts it closes.
public struct ReimbursementLink: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var reimbursementTxId: UUID
  public var partId: UUID
  public var amountE4: AmountE4

  public init(
    id: UUID = UUID(), reimbursementTxId: UUID, partId: UUID, amountE4: AmountE4
  ) {
    self.id = id
    self.reimbursementTxId = reimbursementTxId
    self.partId = partId
    self.amountE4 = amountE4
  }
}

/// Bank of Russia rate for one day. Rates are decimal strings in the database.
public struct Rate: Hashable, Sendable, Codable {
  public var date: DateOnly
  public var currency: CurrencyCode
  /// Rubles per `nominal` units, exactly as published (56.2349 for 100 JPY) — despite the
  /// name, which is the schema's; `perUnit` is the rate for one unit.
  public var rubPerUnit: Decimal
  public var nominal: Int
  public var source: RateSource
  public var fetchedAt: Date?

  public init(
    date: DateOnly, currency: CurrencyCode, rubPerUnit: Decimal, nominal: Int = 1,
    source: RateSource = .cbr, fetchedAt: Date? = nil
  ) {
    self.date = date
    self.currency = currency
    self.rubPerUnit = rubPerUnit
    self.nominal = nominal
    self.source = source
    self.fetchedAt = fetchedAt
  }

  /// Rubles for one unit of the currency, with the nominal already applied.
  public var perUnit: Decimal {
    nominal <= 1 ? rubPerUnit : rubPerUnit / Decimal(nominal)
  }

  /// Converts an amount in this currency into rubles, rounded to stored units.
  public func toRubles(_ amount: AmountE4) throws -> AmountE4 {
    try AmountE4(decimal: amount.decimal * perUnit)
  }
}
