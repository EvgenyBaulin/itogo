import AppCore
import Foundation

/// The filters of the Transactions window and the text of its search box, as the sidebar
/// edits them. Pure, so the rules of resetting are tested without a window:
///
/// * the type narrows the categories on offer to its kind, and a category of the other kind
///   is dropped together with its subcategory — it would filter everything out, and the
///   picker could no longer show it;
/// * another category drops the subcategory, exactly as the ↓ panel does;
/// * a value archived after it was chosen is dropped (`keep(within:)`) — but a place, which the
///   filter goes on offering from the archive, is kept;
/// * «Reset» brings everything back, the search included.
struct TransactionFilters: Hashable, Sendable {
  enum PeriodChoice: String, CaseIterable, Hashable, Sendable {
    case thisMonth, lastMonth, thisYear, allTime, custom

    var titleKey: String {
      switch self {
      case .thisMonth: "filters.thisMonth"
      case .lastMonth: "filters.lastMonth"
      case .thisYear: "filters.thisYear"
      case .allTime: "filters.allTime"
      case .custom: "filters.custom"
      }
    }
  }

  var period: PeriodChoice = .thisMonth
  /// The two days of «Custom range». Kept when another period is chosen, so going back to
  /// the custom one finds them as they were.
  var customStart: DateOnly
  var customEnd: DateOnly
  private(set) var kind: TransactionKind?
  private(set) var categoryId: UUID?
  var subcategoryId: UUID?
  var quality: Quality?
  var forWhom: ForWhom?
  var personId: UUID?
  var placeId: UUID?
  var eventId: UUID?
  /// The account: its operations, and the transfers from it or to it.
  var paymentMethodId: UUID?
  /// A card of the account: only the operations it paid. No transfer is paid by a card.
  var cardId: UUID?
  var status: ReimbursementStatus?
  var search = ""

  /// The custom range starts as this month so far.
  init(today: DateOnly) {
    customStart = today.monthKey.firstDay
    customEnd = today
  }

  /// A type, and whatever category it leaves no room for.
  mutating func setKind(_ kind: TransactionKind?, tree: [CoreKit.Category]) {
    self.kind = kind
    guard let categoryId,
      !Self.filterCategories(tree, kind: kind).contains(where: { $0.id == categoryId })
    else { return }
    self.categoryId = nil
    subcategoryId = nil
  }

  /// Another category drops the subcategory: a child of the category that was there before
  /// would leave the pair mismatched.
  mutating func setCategory(_ categoryId: UUID?) {
    guard categoryId != self.categoryId else { return }
    self.categoryId = categoryId
    subcategoryId = nil
  }

  /// The account picker's choice: a card, or an account.
  var accountOrCard: UUID? { cardId ?? paymentMethodId }

  /// Picks an account — every operation of it and its cards — or one card, which brings its
  /// account.
  mutating func setAccountOrCard(_ id: UUID?, cards: [PaymentCard]) {
    let resolved = CardRules.resolve(selection: id, cards: cards)
    paymentMethodId = resolved.accountId
    cardId = resolved.cardId
  }

  /// Keeps only the values `choices` still offers. One chosen here and archived since — in
  /// Settings, or gone with a restore — is not offered any more, so its picker shows «Any»:
  /// kept, it went on filtering the table with nothing on screen to say so.
  mutating func keep(within choices: FilterChoices) {
    if let categoryId, !choices.topLevel(for: kind).contains(where: { $0.id == categoryId }) {
      self.categoryId = nil
    }
    if let subcategoryId,
      !choices.subcategories(of: categoryId).contains(where: { $0.id == subcategoryId })
    {
      self.subcategoryId = nil
    }
    if let personId, !choices.people.contains(where: { $0.id == personId }) {
      self.personId = nil
    }
    if let placeId, !choices.places.contains(where: { $0.id == placeId }) {
      self.placeId = nil
    }
    if let eventId, !choices.events.contains(where: { $0.id == eventId }) {
      self.eventId = nil
    }
    if let paymentMethodId,
      !choices.paymentMethods.contains(where: { $0.id == paymentMethodId })
    {
      self.paymentMethodId = nil
      cardId = nil
    }
    // A card archived since, or one of another account, is no longer offered: the account
    // alone stays.
    if let cardId,
      !choices.cards.contains(where: { $0.id == cardId && $0.accountId == paymentMethodId })
    {
      self.cardId = nil
    }
  }

  /// Whether «Reset» has anything to do. The days of a custom range count only while it is
  /// the period chosen.
  var canReset: Bool {
    var plain = self
    plain.reset()
    plain.customStart = customStart
    plain.customEnd = customEnd
    return plain != self
  }

  /// Back to this month, nothing else chosen, nothing searched. The custom days stay.
  mutating func reset() {
    let (start, end) = (customStart, customEnd)
    self = TransactionFilters(today: start)
    customStart = start
    customEnd = end
  }

  /// The period as the core reads it. The months take income by the month it is for, like
  /// every monthly figure; a custom range is its days, in either order.
  func period(today: DateOnly) -> Period? {
    let month = today.monthKey
    switch period {
    case .thisMonth: return .month(month)
    case .lastMonth: return .month(month.previous)
    case .thisYear: return .year(today.year)
    case .allTime: return nil
    case .custom:
      return .days(DayRange(min(customStart, customEnd), max(customStart, customEnd)))
    }
  }

  /// The filter of the core over the whole history.
  func entryFilter(today: DateOnly) -> EntryFilter {
    EntryFilter(
      period: period(today: today), kind: kind, categoryId: categoryId,
      subcategoryId: subcategoryId, quality: quality, forWhom: forWhom, personId: personId,
      placeId: placeId, eventId: eventId, paymentMethodId: paymentMethodId,
      reimbursementStatus: status, text: search.trimmingCharacters(in: .whitespaces),
      cardId: cardId)
  }

  /// Top-level categories the category filter offers: those of the kind the type filter
  /// chose — a refund and a reimbursement live among the spending ones — and all of them
  /// while the type is «any».
  static func filterCategories(
    _ tree: [CoreKit.Category], kind: TransactionKind?
  ) -> [CoreKit.Category] {
    tree.filter { category in
      category.parentId == nil && (kind.map { $0.categoryKind == category.kind } ?? true)
    }
  }
}

/// The values the filters offer, taken from the data the table shows whenever it changes.
/// Archived categories, people, events, accounts and cards are not offered, though an operation filed
/// under an archived subcategory is still found by its live parent. Places in the archive are:
/// their operations keep them, and the table is where the owner finds those — the live places
/// first, then the archived ones (`archivedPlaceIds`).
struct FilterChoices: Sendable {
  var categories: [CoreKit.Category] = []
  var people: [Person] = []
  var places: [Place] = []
  var events: [Event] = []
  var paymentMethods: [PaymentMethod] = []
  /// The live cards of the accounts offered.
  var cards: [PaymentCard] = []
  /// The places of `places` that are in the archive, named «(архив)» by the picker.
  var archivedPlaceIds: Set<UUID> = []

  init() {}

  /// `locale` orders the accounts by name the way the interface language does.
  init(_ dataset: Dataset, locale: Locale = Locale(identifier: "en")) {
    categories = dataset.categories.filter { !$0.archived }
    people = dataset.people.filter { !$0.archived }.sorted { $0.name < $1.name }
    let archivedPlaces = dataset.places.filter(\.archived).sorted { $0.name < $1.name }
    places =
      dataset.places.filter { !$0.archived }.sorted { $0.name < $1.name } + archivedPlaces
    archivedPlaceIds = Set(archivedPlaces.map(\.id))
    // The latest first: the event one looks for is usually the last one.
    events = dataset.events.filter { !$0.archived }.sorted { $0.startDate > $1.startDate }
    // The order of every list of accounts: the main one first, then the owner's order.
    paymentMethods = AccountRules.ordered(dataset.paymentMethods, locale: locale)
    let offered = Set(paymentMethods.map(\.id))
    cards = dataset.cards.filter { !$0.archived && offered.contains($0.accountId) }
    self.locale = locale
  }

  private var locale = Locale(identifier: "en")

  /// The account filter's choices: each account followed by its cards.
  var accountItems: [AccountCardChoices.Item] {
    AccountCardChoices.items(accounts: paymentMethods, cards: cards, locale: locale)
  }

  func topLevel(for kind: TransactionKind?) -> [CoreKit.Category] {
    TransactionFilters.filterCategories(categories, kind: kind)
  }

  func subcategories(of categoryId: UUID?) -> [CoreKit.Category] {
    guard let categoryId else { return [] }
    return categories.filter { $0.parentId == categoryId }
  }
}
