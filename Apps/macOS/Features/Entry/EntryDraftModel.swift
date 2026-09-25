import AppCore
import AppDatabase
import Foundation
import Observation

/// Everything the ↓ panel edits: one draft operation plus the dictionaries it offers.
///
/// The model owns no views and no database writes — it prepares a `TransactionDraft` and
/// hands it back to the store, so the same rules can be exercised from tests.
@MainActor
@Observable
public final class EntryDraftModel {
  public var draft = TransactionDraft() {
    didSet {
      guard draft.creditDebtId != oldValue.creditDebtId else { return }
      kindWithTheCredit = draft.creditDebtId == nil ? nil : draft.kind
    }
  }
  /// Categories that can be chosen: the archived ones are left out.
  public var categories: [CoreKit.Category] = []
  /// Categories retired since. They are never offered, but an operation saved under one of
  /// them still reads back as filed there instead of showing an empty picker.
  public private(set) var archivedCategories: [CoreKit.Category] = []
  public var people: [Person] = []
  /// For income: the expected income it is tied to («привязка к ожидаемому
  /// поступлению»). Saved with the operation in one write.
  public var expectedIncomeId: UUID?
  public var places: [Place] = []
  public var paymentMethods: [PaymentMethod] = []
  public var events: [Event] = []
  public var goals: [Goal] = []
  public var debts: [Debt] = []

  /// Buying on credit or in instalments: which debt the purchase joins, or a new one, and
  /// how it will be repaid. The expense itself is recorded once, now, in its own category;
  /// the payments only reduce the debt.
  public struct CreditPlan: Hashable, Sendable {
    /// `nil` means a debt is created for this purchase.
    public var debtId: UUID?
    public var payments: Int
    public var monthlyAmount: AmountE4

    public init(debtId: UUID? = nil, payments: Int = 12, monthlyAmount: AmountE4 = .zero) {
      self.debtId = debtId
      self.payments = payments
      self.monthlyAmount = monthlyAmount
    }
  }

  public var creditPlan: CreditPlan?

  /// Up to three categories offered next to the picker, taken from history.
  public private(set) var categorySuggestions: [CoreKit.Category] = []

  private let references: ReferenceRepository?
  private let transactions: TransactionRepository?
  private let calendar: CalendarContext
  /// The draft is a saved operation in the editor — the sheet or the inspector — not the
  /// entry line's new one.
  private let editsSavedOperation: Bool
  /// The kind the draft had when its debt «on credit» came with it. In the editor the debt
  /// only ever comes with the saved operation, so this is the kind it was saved with.
  private var kindWithTheCredit: TransactionKind?
  /// Off by default, as the specification requires: an event covering the day is only
  /// offered, and the panel shows it as a suggestion until it is picked.
  private let assignsEventAutomatically: Bool

  /// My own ratings by description, for rule 2 of the qualities: an operation described the
  /// way one I rated by hand was keeps my last rating.
  private var qualityHistory = ManualQualityHistory.empty

  /// The event covering the day of the operation, offered rather than applied.
  public private(set) var suggestedEvent: Event?
  /// Names the entry line read but could not match to a dictionary. They are offered as
  /// the starting text when a person or a place is created on the spot.
  public private(set) var suggestedPersonName: String?
  public private(set) var suggestedPlaceName: String?
  /// The words that named them, as typed («для Пети», «в Кофемании»). They stay in the note
  /// until «Add…» of a menu makes a person or a place of the name.
  private var unmatchedPersonPhrase: String?
  private var unmatchedPlacePhrase: String?

  /// What the line last wrote into the note and the date — before any line, what the draft
  /// started with. A value still equal to it is one the panel left alone, and the next Enter
  /// writes over it; a value the panel changed is the owner's and stays
  /// («комментарий, дата» are fields of the panel).
  private var noteFromTheLine: String?
  private var dateFromTheLine: Date?
  /// The date nobody chose: the one the draft was made with, or «now» the line wrote for a
  /// line that names no day. While the draft still holds it, the operation is dated the moment
  /// it is saved — the draft is made when the line appears or right after the last save, and
  /// may wait hours for the next one.
  private var dateFollowsTheClock = true
  /// The payment method the defaults last chose — of the place, otherwise the default one.
  /// While the draft still holds it, a better default replaces it (another place was chosen);
  /// a method the line named or the owner picked is never replaced.
  private var paymentMethodFromDefaults: UUID?
  /// «For whom» of the first part as the defaults last laid it: «Me» for a new operation, then
  /// the last choice made for the operation most like it. While the part still holds it, the
  /// defaults lay another; a value the line named or the owner chose stays, and so does the one
  /// a saved operation was recorded with — nil in the editor.
  private var forWhomFromDefaults: ForWhomChoice?

  /// A value of «for whom» and the person it names, as one choice.
  private struct ForWhomChoice: Equatable {
    var value: ForWhom
    var personId: UUID?

    static let me = ForWhomChoice(value: .me, personId: nil)

    init(value: ForWhom, personId: UUID?) {
      self.value = value
      self.personId = personId
    }

    init(of part: PartDraft) {
      self.init(value: part.forWhom, personId: part.forPersonId)
    }
  }

  public init(
    references: ReferenceRepository?,
    transactions: TransactionRepository?,
    calendar: CalendarContext,
    assignsEventAutomatically: Bool = false,
    editsSavedOperation: Bool = false
  ) {
    self.references = references
    self.transactions = transactions
    self.calendar = calendar
    self.assignsEventAutomatically = assignsEventAutomatically
    self.editsSavedOperation = editsSavedOperation
    self.forWhomFromDefaults = editsSavedOperation ? nil : .me
    self.draft.normalizeSinglePart()
    self.dateFromTheLine = draft.occurredAt
  }

  /// The panel as the application makes it — for the entry line and for the editor of a
  /// saved operation alike: the repositories, the calendar, the owner's setting for events,
  /// and the category model the pipeline trains («1. история;
  /// 2. модель; 3. ручной выбор»). Both go through here, so neither can leave one out.
  convenience init(environment: AppEnvironment, editsSavedOperation: Bool = false) {
    self.init(
      references: environment.references,
      transactions: environment.transactions,
      calendar: environment.calendar,
      assignsEventAutomatically: environment.assignsEventAutomatically,
      editsSavedOperation: editsSavedOperation)
    predictor = environment.categoryModel
    // The rate is read from the cache only: asking the bank is the save's business, not a
    // keystroke's.
    converting = { [weak environment] draft in
      var rated = draft
      guard let environment else {
        return Conversion(draft: rated, rubles: { _ in throw MoneyConversionError.rateMissing })
      }
      if rated.currency != .rub, rated.rateSource != .manual {
        AppEnvironment.applyRate(
          to: &rated, from: RateTable(rates: (try? environment.rates?.allRates()) ?? []),
          calendar: environment.calendar)
      }
      return Conversion(draft: rated, rubles: environment.rublesConverter(for: rated))
    }
  }

  public func reload() {
    reloadQualityRules()
    guard let references else { return }
    people = (try? references.people()) ?? []
    places = (try? references.places()) ?? []
    paymentMethods = (try? references.paymentMethods()) ?? []
    events = (try? references.events()) ?? []
    goals = (try? references.goals()) ?? []
    debts = (try? references.debts()) ?? []
  }

  /// What a quality is decided by: my manual ratings and the categories. Both change behind
  /// the back of a model that lives as long as the entry line — a bulk rating from the list,
  /// a rating in the edit sheet, ⌘Z, a category re-rated or archived in Settings — so they
  /// are asked for again every time the defaults are worked out, not only when the model is
  /// made. The ratings come from the repository's cache, read again only after a write:
  /// this runs at every change of a picker in the panel.
  private func reloadQualityRules() {
    qualityHistory = (try? transactions?.manualQualityHistory()) ?? .empty
    guard let references else { return }
    let allCategories = (try? references.categories(includeArchived: true)) ?? []
    categories = allCategories.filter { !$0.archived }
    archivedCategories = allCategories.filter(\.archived)
  }

  // MARK: Parsed line

  /// Fills the draft from a parsed entry line, keeping whatever the panel already set: its
  /// kind, place, payment method, people, event, goal — and its note and date, which the line
  /// takes over only while the panel has left them as the line wrote them. A date the line
  /// names always wins.
  public func apply(_ parsed: ParsedInput, amount: AmountE4, today: DateOnly) {
    // A kind chosen in the panel is not overwritten by a line that says nothing about it:
    // the parser reports `.expense` both when it read nothing and when it read "расход".
    if parsed.kind != .expense || draft.kind == .expense {
      draft.kind = parsed.kind
    }
    draft.amount = amount
    followTheAmountInTheCreditPlan()
    // Kept with its numbers written the way the app writes them: «1500,5+2» is «1,500.5+2».
    draft.amountExpression = parsed.amountExpression.map {
      ExpressionEvaluator.canonical($0) ?? $0
    }
    draft.currency = parsed.currency ?? draft.currency
    // A name the dictionaries do not know leaves the note like every word the parser read,
    // but nothing else keeps it: it goes back into the note as typed, and Enter no longer
    // saves «кофе» for «кофе 300 в Кофемании».
    unmatchedPersonPhrase = parsed.unknownPersonName == nil ? nil : parsed.unknownPersonPhrase
    unmatchedPlacePhrase = parsed.unknownPlaceName == nil ? nil : parsed.unknownPlacePhrase
    let lineNote = [parsed.note, unmatchedPersonPhrase ?? "", unmatchedPlacePhrase ?? ""]
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    if !lineNote.isEmpty, draft.note == noteFromTheLine {
      draft.note = lineNote
      noteFromTheLine = lineNote
    }
    draft.placeId = parsed.placeId ?? draft.placeId
    if let named = parsed.paymentMethodId {
      draft.paymentMethodId = named
      paymentMethodFromDefaults = nil
    }
    draft.debtId = parsed.debtId ?? draft.debtId
    if parsed.date != nil || draft.occurredAt == dateFromTheLine {
      draft.occurredAt = occurredAt(for: parsed.date, today: today)
      dateFromTheLine = draft.occurredAt
      dateFollowsTheClock = parsed.date == nil || parsed.date == today
    }
    suggestedPersonName = parsed.unknownPersonName
    suggestedPlaceName = parsed.unknownPlaceName
    draft.normalizeSinglePart()
    draft.parts[0].forWhom = parsed.forWhom ?? draft.parts[0].forWhom
    draft.parts[0].forPersonId = parsed.personId ?? draft.parts[0].forPersonId
    // «Для кого» the line names — «себе» too — is the owner's word, not history's.
    if parsed.forWhom != nil || parsed.personId != nil { forWhomFromDefaults = nil }
    draft.parts[0].eventId = parsed.eventId ?? draft.parts[0].eventId
    // A goal the line names files the part under it, as a contribution from Planning is.
    if let goalId = parsed.goalId { setGoal(goalId, forPartAt: 0) }
    applyDefaults(today: today)
  }

  /// Defaults from history and from the dictionaries, in the order the specification lists.
  public func applyDefaults(today: DateOnly) {
    guard !draft.parts.isEmpty else { return }
    reloadQualityRules()
    dropTheCreditTheKindCannotCarry()

    // A category of the other kind is dropped first: after switching an expense to income
    // it would match nothing the picker offers and file the money on the wrong side.
    dropCategoriesOfTheOtherKind()

    // The operation most like this one — the same place or the same words — brings its
    // category («1. история: то же место или то же описание → последняя категория»), only
    // while none is chosen, and only one that can still be chosen: of the right kind and not
    // retired since.
    let history = otherOperations()
    if let alike = mostAlike(in: history), draft.parts[0].categoryId == nil,
      let categoryId = alike.parts.first?.categoryId, isOffered(categoryId)
    {
      draft.parts[0].categoryId = categoryId
      draft.parts[0].categorySource = .history
      nameTheGoal(ofPartAt: 0)
    }

    // «Для кого»: «по умолчанию «Я»; по истории (то же место или описание → последний мой
    // выбор); из строки ввода».
    layForWhom(from: history)

    // The payment method: the last one used at that place, otherwise the one marked as
    // default — unless the line named one or the owner chose one by hand.
    if draft.paymentMethodId == nil || draft.paymentMethodId == paymentMethodFromDefaults {
      let atThePlace = draft.placeId.flatMap { place in
        history.first { $0.transaction.placeId == place }
      }
      let chosen =
        atThePlace?.transaction.paymentMethodId ?? paymentMethods.first(where: \.isDefault)?.id
      draft.paymentMethodId = chosen
      paymentMethodFromDefaults = chosen
    }

    // An event covering the date of the operation is offered; it is applied only when
    // the owner turned that on in the settings.
    let day = calendar.day(of: draft.occurredAt)
    suggestedEvent = events.first { $0.covers(day) }
    if draft.parts[0].eventId == nil, assignsEventAutomatically {
      draft.parts[0].eventId = suggestedEvent?.id
    }

    // A payment against a debt that records its payments as expenses belongs to the
    // system Loans category — that is how the owner used to keep loans before the app.
    if let debtId = draft.debtId,
      let debt = debts.first(where: { $0.id == debtId }),
      DebtRules.paymentIsExpense(on: debt),
      draft.kind.categoryKind == .expense,
      draft.parts[0].categoryId == nil
    {
      draft.parts[0].categoryId =
        debt.loansSubcategoryId
        ?? categories.first { $0.systemRole == .loans && $0.kind == .expense }?.id
      draft.parts[0].categorySource = .system
    }

    // Every part has a quality of its own: the second part of a split in Fees is bad
    // even when the first is ordinary groceries.
    let tree = categoryTree
    for index in draft.parts.indices {
      resolveQuality(ofPartAt: index, in: tree)
    }

    refreshSuggestions()
  }

  /// Income and a reimbursement have no quality; a goal contribution is always good and
  /// cannot be changed; a rating set by hand stays; a description I rated by hand before
  /// keeps my last rating; everything else takes the quality of its category.
  private func resolveQuality(ofPartAt index: Int, in tree: CategoryTree) {
    guard draft.parts.indices.contains(index) else { return }
    guard hasQuality else {
      draft.parts[index].quality = nil
      draft.parts[index].qualitySource = nil
      return
    }
    let decision = QualityResolver.resolve(
      draft: draft.parts[index], description: draft.note, categories: tree,
      history: qualityHistory)
    draft.parts[index].quality = decision.quality
    draft.parts[index].qualitySource = decision.source
  }

  /// A category whose kind does not match the operation — an expense category on an income
  /// or the other way round — is dropped from every part. A category the dictionary does
  /// not know is left alone: there is nothing to judge it by.
  private func dropCategoriesOfTheOtherKind() {
    for index in draft.parts.indices {
      guard let categoryId = draft.parts[index].categoryId, !fitsTheKind(categoryId) else {
        continue
      }
      draft.parts[index].categoryId = nil
      draft.parts[index].categorySource = .manual
    }
  }

  private func fitsTheKind(_ categoryId: UUID) -> Bool {
    guard let category = category(withId: categoryId) else { return true }
    return category.kind == draft.kind.categoryKind
  }

  /// Could the picker offer this category right now? Only a live category of the kind of
  /// the operation: history never brings back a retired one or one of the other side.
  private func isOffered(_ categoryId: UUID) -> Bool {
    categories.contains { $0.id == categoryId && $0.kind == draft.kind.categoryKind }
  }

  /// Whether the operation is rated at all: spending is, income and a reimbursement are not.
  public var hasQuality: Bool { draft.kind.hasQuality }

  /// A contribution to a goal — by its goal or by sitting under Goals — is always good, so
  /// its quality is not offered for a choice.
  public func canRateByHand(_ part: PartDraft) -> Bool {
    QualityResolver.canRateByHand(
      goalId: part.goalId, categoryId: part.categoryId, categories: categoryTree)
  }

  /// Quality of the subcategory, or of its parent when the subcategory has none.
  public func inheritedQuality(for categoryId: UUID?) -> Quality? {
    categoryTree.effectiveQuality(of: categoryId)
  }

  /// The whole dictionary, archived categories included, for the rules of `CoreAccounting`.
  private var categoryTree: CategoryTree { CategoryTree(categories + archivedCategories) }

  /// Any category the operation may point at, archived ones included.
  private func category(withId id: UUID) -> CoreKit.Category? {
    categories.first { $0.id == id } ?? archivedCategories.first { $0.id == id }
  }

  // MARK: Category and subcategory

  // A part keeps a single `categoryId`: the most specific choice made — the subcategory
  // when one is chosen, the top-level category otherwise. The panel shows that as two
  // pickers, and the methods below are the whole translation between the two shapes.

  /// The part a picker is editing, or an empty one when the index is stale.
  public func part(at index: Int) -> PartDraft {
    draft.parts.indices.contains(index) ? draft.parts[index] : PartDraft()
  }

  /// The top-level category of a part: the stored id itself, or the parent of the
  /// subcategory it names.
  public func categoryOfPart(_ part: PartDraft) -> UUID? {
    guard let categoryId = part.categoryId else { return nil }
    // A category the dictionary does not know at all is taken as it is.
    guard let category = category(withId: categoryId) else { return categoryId }
    return category.parentId ?? category.id
  }

  /// The subcategory of a part: the stored id when it names a child, nothing otherwise.
  public func subcategoryOfPart(_ part: PartDraft) -> UUID? {
    guard let categoryId = part.categoryId,
      let category = category(withId: categoryId),
      category.parentId != nil
    else { return nil }
    return category.id
  }

  /// What the category picker of a part offers: the top-level categories of the kind of
  /// the operation, plus the one the part is already filed under when that has been
  /// archived since — the saved operation shows its category, not an empty picker.
  public func categoryOptions(forPartAt index: Int) -> [CoreKit.Category] {
    var options = topLevelCategories(for: draft.kind)
    if let current = categoryOfPart(part(at: index)),
      !options.contains(where: { $0.id == current }),
      let retired = archivedCategories.first(where: { $0.id == current })
    {
      options.append(retired)
    }
    return options
  }

  /// What the subcategory picker of a part offers: the children of its category, plus an
  /// archived child the part is already filed under.
  public func subcategoryOptions(forPartAt index: Int) -> [CoreKit.Category] {
    var options = subcategories(of: categoryOfPart(part(at: index)))
    if let current = subcategoryOfPart(part(at: index)),
      !options.contains(where: { $0.id == current }),
      let retired = archivedCategories.first(where: { $0.id == current })
    {
      options.append(retired)
    }
    return options
  }

  /// Top-level categories an operation of this kind can go into.
  public func topLevelCategories(for kind: TransactionKind) -> [CoreKit.Category] {
    categories.filter { $0.parentId == nil && $0.kind == kind.categoryKind }
  }

  /// Children of a category, in the order the dictionary keeps them.
  public func subcategories(of categoryId: UUID?) -> [CoreKit.Category] {
    guard let categoryId else { return [] }
    return categories.filter { $0.parentId == categoryId }
  }

  /// Choosing a category stores it and drops the subcategory, which belonged to the
  /// category that was there before. Choosing the same category again changes nothing.
  public func setCategory(
    _ id: UUID?, forPartAt index: Int, source: CategorySource = .manual
  ) {
    guard draft.parts.indices.contains(index) else { return }
    guard categoryOfPart(draft.parts[index]) != id else { return }
    draft.parts[index].categoryId = id
    draft.parts[index].categorySource = source
    nameTheGoal(ofPartAt: index)
  }

  /// Choosing a subcategory stores the child. The dash means the operation hangs on the
  /// category itself, so the stored id goes back to the parent.
  public func setSubcategory(
    _ id: UUID?, forPartAt index: Int, source: CategorySource = .manual
  ) {
    guard draft.parts.indices.contains(index) else { return }
    guard let id else {
      draft.parts[index].categoryId = categoryOfPart(draft.parts[index])
      draft.parts[index].categorySource = source
      return
    }
    // Only a real child may be stored here: a top-level id would lose the pair silently.
    // An archived child is accepted only when it is the one already there.
    guard let child = category(withId: id), child.parentId != nil,
      !child.archived || draft.parts[index].categoryId == id
    else {
      return
    }
    draft.parts[index].categoryId = child.id
    draft.parts[index].categorySource = source
    nameTheGoal(ofPartAt: index)
  }

  /// A suggestion taken from history fills both pickers at once: it is stored as the most
  /// specific category, and the pair is read back from it.
  ///
  /// A chip history offered stays history's. A chip the model offered, pressed, is the
  /// owner's choice — `.manual`, evidence for the next training like any choice of theirs —
  /// and not `.history`, which would say history had filed it; that it was the model's
  /// suggestion is for `category_feedback` to keep.
  public func applySuggestion(_ category: CoreKit.Category, forPartAt index: Int = 0) {
    guard draft.parts.indices.contains(index) else { return }
    draft.parts[index].categoryId = category.id
    draft.parts[index].categorySource =
      suggestionSources[category.id] == .model ? .manual : .history
    nameTheGoal(ofPartAt: index)
  }

  /// Where the trained category model waits (step 4 of the pipeline); the app hands it over in
  /// `init(environment:)`. Asking it is a lookup in counters, so typing never waits on anything.
  var predictor: CategoryModelBox?
  /// What the model last said, for the chip's wording and for the quality figures later.
  public private(set) var lastPrediction: CategoryPrediction?
  /// What it was asked then.
  private var lastQuestion: CategoryQuery?

  /// The owner's choice for the first part, the one the model answers for, as
  /// `category_feedback` keeps it («мой выбор пишется в `category_feedback`»): what the model
  /// offered first and how sure it was, what was chosen. Nothing when the model offered
  /// nothing, or the category was not the owner's to choose: left as the model filled it, put
  /// there by the app, or none at all.
  public func categoryChoice(at now: Date = Date()) -> CategoryFeedback? {
    guard let offered = lastPrediction?.suggestions.first, let question = lastQuestion,
      let part = draft.parts.first, let chosen = part.categoryId,
      part.categorySource != .model, part.categorySource != .system
    else { return nil }
    return CategoryFeedback(
      text: question.text, predictedCategoryId: offered.categoryId, chosenCategoryId: chosen,
      partId: part.id, confidenceBp: offered.confidenceBp, at: now)
  }
  /// Where each suggestion came from, so the chip can say — and so a suggestion the model
  /// filled in is marked `.model` and never taught back to it.
  public private(set) var suggestionSources: [UUID: CategorySource] = [:]

  private func refreshSuggestions() {
    guard let transactions else {
      categorySuggestions = []
      suggestionSources = [:]
      return
    }
    let words = wordsOfTheDraft
    let recent = (try? transactions.recentEntries(limit: 200)) ?? []
    var counts: [UUID: Int] = [:]
    for entry in recent {
      let sameNote = words != nil && Self.words(of: entry) == words
      let samePlace = draft.placeId != nil && entry.transaction.placeId == draft.placeId
      guard sameNote || samePlace else { continue }
      for part in entry.parts {
        guard let categoryId = part.categoryId else { continue }
        counts[categoryId, default: 0] += 1
      }
    }
    // Only what the picker could hold: a category of another kind or a retired one would be
    // a chip that files the money somewhere it cannot go.
    let fromHistory =
      counts
      .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.uuidString < $1.key.uuidString }
      .compactMap { pair in categories.first { $0.id == pair.key } }
      .filter { isOffered($0.id) }

    // Level one is history — the same place or the same words, filed the same way before —
    // and it wins, as the specification orders the levels. The model fills what is left.
    var sources: [UUID: CategorySource] = [:]
    for category in fromHistory { sources[category.id] = .history }
    var offered = fromHistory
    for category in modelSuggestions() where !offered.contains(where: { $0.id == category.id }) {
      offered.append(category)
      sources[category.id] = .model
    }

    categorySuggestions = Array(offered.prefix(3))
    suggestionSources = sources
    applyTheModelIfItIsSure()
  }

  /// What the model would offer for the draft as it stands.
  private func modelSuggestions() -> [CoreKit.Category] {
    guard let predictor, let query = modelQuery() else {
      // Not asked this time: what it said about the draft before no longer stands.
      lastQuestion = nil
      lastPrediction = nil
      return []
    }
    let candidates = categories.filter { isOffered($0.id) }
    lastQuestion = query
    lastPrediction = predictor.predict(query, among: candidates.map(\.id))
    return lastPrediction?.suggestions.compactMap { suggestion in
      candidates.first { $0.id == suggestion.categoryId }
    } ?? []
  }

  /// «Уверенность не ниже порога → категория подставляется» — but only when nothing is
  /// there yet and history had nothing to say. A suggestion the model made is marked as its
  /// own, so it is never taught back to the model as though the owner had chosen it.
  private func applyTheModelIfItIsSure() {
    guard let prediction = lastPrediction, prediction.appliesTop,
      let best = prediction.suggestions.first,
      suggestionSources[best.categoryId] == .model,
      draft.parts.indices.contains(0), draft.parts[0].categoryId == nil
    else { return }
    draft.parts[0].categoryId = best.categoryId
    draft.parts[0].categorySource = .model
    nameTheGoal(ofPartAt: 0)
  }

  /// The question the model is asked about the first part, built by `LedgerTraining` — the
  /// same code that builds it when the model is taught, so the two cannot drift apart (a test
  /// compares them) — about the draft as the save writes it: the one part the whole amount,
  /// its rate laid on from the cache as the save lays it (`converting`). The amount is in
  /// rubles and the words are the part's own note before the operation's. A foreign amount
  /// with no rate to put it in rubles is not asked about: its bucket would be one the model
  /// was never taught.
  func modelQuery() -> CategoryQuery? {
    guard !draft.parts.isEmpty else { return nil }
    var asked = draft
    // The one part is the whole amount, as it is when it is saved.
    asked.normalizeSinglePart()
    guard let converted = conversion(of: asked), (try? converted.rubles(asked.amount)) != nil
    else { return nil }
    return LedgerTraining.query(draft: converted.draft, calendar: calendar)
  }

  /// How the save turns the draft's money into rubles: its rate laid on as the save lays it,
  /// and the converter of its currency (`AppEnvironment.applyRate`, `rublesConverter`). The
  /// app hands it over in `init(environment:)`.
  var converting: ((TransactionDraft) -> Conversion)?

  /// The draft with its rate, and what turns its amounts into rubles.
  struct Conversion {
    var draft: TransactionDraft
    var rubles: (AmountE4) throws -> AmountE4
  }

  private func conversion(of draft: TransactionDraft) -> Conversion? {
    if let converting { return converting(draft) }
    // Made without the app: rubles are rubles, and nothing else can be converted.
    return draft.currency == .rub ? Conversion(draft: draft, rubles: { $0 }) : nil
  }

  /// What history is read from: the last 200 operations, newest first, without the one the
  /// editor has open — a saved operation is not history of itself.
  private func otherOperations() -> [TransactionEntry] {
    guard let transactions else { return [] }
    let own = Set(draft.parts.map(\.id))
    return ((try? transactions.recentEntries(limit: 200)) ?? []).filter { entry in
      !entry.parts.contains { own.contains($0.id) }
    }
  }

  /// The operation the draft is most like, for what history brings: the last one at the same
  /// place with the same words, else the last with the same words, else the last at the same
  /// place. The words come before the place, as in the model's exact match:
  /// «coffee» at the canteen is the coffee of before, not the canteen's last lunch.
  private func mostAlike(in history: [TransactionEntry]) -> TransactionEntry? {
    let words = wordsOfTheDraft
    var best: (entry: TransactionEntry, likeness: Int)?
    for entry in history {
      let sameWords = words != nil && Self.words(of: entry) == words
      let samePlace = draft.placeId != nil && entry.transaction.placeId == draft.placeId
      let likeness = (sameWords ? 2 : 0) + (samePlace ? 1 : 0)
      if likeness > (best?.likeness ?? 0) { best = (entry, likeness) }
      if likeness == 3 { break }
    }
    return best?.entry
  }

  /// «For whom» of the first part from history, while the part still holds what the defaults
  /// laid there: the choice made for the operation of the same kind most like this one, or «Me»
  /// when there is none. Money given back names who paid, not whom it was for,
  /// so a reimbursement neither brings a choice nor takes one: its draft stays at «Me». A person
  /// the picker can no longer offer is left out; the value of the choice stays.
  private func layForWhom(from history: [TransactionEntry]) {
    guard let laid = forWhomFromDefaults, ForWhomChoice(of: draft.parts[0]) == laid else {
      return
    }
    let alike =
      draft.kind == .reimbursement
      ? nil : mostAlike(in: history.filter { $0.transaction.kind == draft.kind })
    let choice = alike?.parts.first.map { part in
      ForWhomChoice(
        value: part.forWhom, personId: part.forPersonId.flatMap { isOfferedPerson($0) ? $0 : nil })
    }
    let chosen = choice ?? .me
    draft.parts[0].forWhom = chosen.value
    draft.parts[0].forPersonId = chosen.personId
    forWhomFromDefaults = chosen
  }

  /// Could the person picker offer this person? Only a live one. The list is read again when
  /// it does not know the person: it was read when the model was made, and people are added in
  /// Settings behind its back.
  private func isOfferedPerson(_ id: UUID) -> Bool {
    if people.contains(where: { $0.id == id }) { return true }
    guard let references, let live = try? references.people() else { return false }
    people = live
    return people.contains { $0.id == id }
  }

  /// «The same description», compared the way rule 2 of the qualities compares it
  /// (`ManualQualityHistory`): the note of the first part, otherwise of the operation, with
  /// case and runs of spaces not counting.
  private var wordsOfTheDraft: String? {
    ManualQualityHistory.normalized(draft.parts.first?.note ?? draft.note)
  }

  private static func words(of entry: TransactionEntry) -> String? {
    ManualQualityHistory.normalized(
      entry.parts.first.flatMap { ManualQualityHistory.description(of: $0, in: entry.transaction) }
        ?? entry.transaction.note)
  }

  private func occurredAt(for day: DateOnly?, today: DateOnly) -> Date {
    guard let day, day != today else { return Date() }
    return calendar.startOfDay(day).addingTimeInterval(12 * 3600)
  }

  // MARK: Goal

  /// Whether a part contributes to a goal — it names one, or it is filed under Goals — and so
  /// whether the panel shows the goal row («цель — если выбрана категория
  /// Goals»). A named goal counts wherever the part is filed: the goal the line matched is seen,
  /// and a goal left on a part filed elsewhere can be cleared.
  public func isGoalContribution(_ part: PartDraft) -> Bool {
    QualityResolver.isGoalContribution(
      goalId: part.goalId, categoryId: part.categoryId, categories: categoryTree)
  }

  /// A goal chosen — named in the line or picked in the panel — files the part where Planning
  /// files a contribution (`GoalRules.contributionDraft`): under the goal's own subcategory of
  /// Goals, or under Goals itself for a goal that has none. No goal leaves the category alone;
  /// a part still under Goals then asks for one (`saveRefusalKey`).
  public func setGoal(_ goalId: UUID?, forPartAt index: Int) {
    guard draft.parts.indices.contains(index) else { return }
    draft.parts[index].goalId = goalId
    guard let goalId, let categoryId = category(ofGoal: goalId) else { return }
    draft.parts[index].categoryId = categoryId
    draft.parts[index].categorySource = .system
  }

  /// Where a contribution to the goal is filed. The goal and its subcategory may have been
  /// made in Planning since the dictionaries were read, so they are read again then.
  private func category(ofGoal goalId: UUID) -> UUID? {
    var goal = goals.first { $0.id == goalId }
    if goal == nil || goal?.subcategoryId.map(isLive) == false {
      reload()
      goal = goals.first { $0.id == goalId }
    }
    if let subcategoryId = goal?.subcategoryId, isLive(subcategoryId) { return subcategoryId }
    return categories.first { $0.parentId == nil && $0.systemRole == .goals }?.id
  }

  private func isLive(_ categoryId: UUID) -> Bool {
    categories.contains { $0.id == categoryId }
  }

  /// A part filed under the subcategory of a goal — by hand, by a chip, by history or by the
  /// model — names that goal: the subcategory belongs to it alone, and Planning counts the part
  /// toward it either way. A goal already named, or cleared by hand, is left as it is.
  private func nameTheGoal(ofPartAt index: Int) {
    guard draft.parts.indices.contains(index), draft.parts[index].goalId == nil,
      let categoryId = draft.parts[index].categoryId,
      let goal = goals.first(where: { $0.subcategoryId == categoryId })
    else { return }
    draft.parts[index].goalId = goal.id
  }

  // MARK: Fields of the panel that bring defaults

  /// The ↓ panel is opening. An operation entered in the panel alone — an empty line and
  /// Enter — never passes through the line, so the defaults are laid now, where they can be
  /// seen: the default payment method, the event of the day. A date nobody chose is the
  /// moment the panel opens, so the panel shows the time the operation will be saved with
  /// rather than the time the draft was made.
  public func prepareForPanel(today: DateOnly, now: Date = Date()) {
    reload()
    takeTheMomentOfSaving(now: now)
    applyDefaults(today: today)
  }

  /// Dates the new operation by the moment it is saved, unless somebody chose the date: the
  /// panel (`setDate`) or a day the line named. An operation entered in the panel alone never
  /// passes through the line, which is what writes «now» — without this it was saved at the
  /// moment its draft was made, the morning the window opened, and after midnight on the day
  /// before. A saved operation in the editor keeps its own date.
  public func takeTheMomentOfSaving(now: Date = Date()) {
    guard !editsSavedOperation, dateFollowsTheClock, draft.occurredAt == dateFromTheLine else {
      return
    }
    draft.occurredAt = now
    dateFromTheLine = now
  }

  /// A place chosen in the panel brings what a place named in the line brings: its category
  /// while none is chosen, and its last payment method unless one was chosen by hand.
  public func setPlace(_ id: UUID?, today: DateOnly) {
    guard draft.placeId != id else { return }
    draft.placeId = id
    applyDefaults(today: today)
  }

  /// A payment method chosen by hand stays whatever place is chosen after it.
  public func setPaymentMethod(_ id: UUID?) {
    draft.paymentMethodId = id
    paymentMethodFromDefaults = nil
  }

  /// A new date is a new day: the event covering it is offered instead of the old one's.
  public func setDate(_ date: Date, today: DateOnly) {
    guard draft.occurredAt != date else { return }
    draft.occurredAt = date
    applyDefaults(today: today)
  }

  // MARK: The month an income is for

  /// The month an income is for as the panel shows it: the one chosen, otherwise the month
  /// of its date («за какой месяц» — «по умолчанию месяц даты»).
  public var shownPeriodMonth: MonthKey {
    draft.periodMonth ?? calendar.day(of: draft.occurredAt).monthKey
  }

  /// What the «for month» picker offers: the month of the date, the two before it and the
  /// one after — and, in its place in time, the month the income is already for when it is
  /// none of these: chosen before the date moved, or saved that way (an import, a transfer
  /// archive). Without it the picker showed a blank while that month was what would be saved.
  public var periodMonthOptions: [MonthKey] {
    let current = calendar.day(of: draft.occurredAt).monthKey
    let around = [current.previous.previous, current.previous, current, current.next]
    guard let chosen = draft.periodMonth, !around.contains(chosen) else { return around }
    return (around + [chosen]).sorted()
  }

  // MARK: Rate typed by hand

  /// What the rate field of the ↓ panel does with whatever is in it.
  ///
  /// Only a number that can actually convert money is accepted. Half-typed and mistyped
  /// text leaves the rate exactly as it was, because a draft with no rate and the source
  /// set to `manual` is the one combination that converts a foreign amount one to one.
  /// An empty field means "use the rate of the bank again", not "there is no rate".
  public func setManualRate(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty {
      draft.rate = nil
      draft.rateDate = nil
      draft.rateSource = nil
      return
    }
    guard let value = DecimalMath.parse(trimmed), value > 0 else { return }
    draft.rate = value
    draft.rateDate = calendar.day(of: draft.occurredAt)
    draft.rateSource = .manual
    draft.rateProvisional = false
  }

  // MARK: Creating on the spot

  /// Why the last record asked for from a picker was not written, as the key of the words that
  /// say so (table «Entry»); nil once one was added or the draft started over. The sheet that
  /// asked shows it, and so does the panel.
  public private(set) var creationFailureKey: String?

  /// Adds a place and returns its id, so the picker can select it immediately. The words of
  /// the line that named it leave the note: the place carries them now.
  ///
  /// A write the database refused returns nil — an id of a row that is not there would reach
  /// Enter and fail on the foreign key with no reason — and leaves the name offered and in
  /// the note, for the next «Add…».
  public func createPlace(named name: String) -> UUID? {
    guard let references else { return nil }
    return createPlace(named: name, saving: references.save)
  }

  public func createPerson(named name: String) -> UUID? {
    guard let references else { return nil }
    return createPerson(named: name, saving: references.save)
  }

  /// Adds the person who gives a part paid for someone back and names them its debtor: «Paid
  /// for someone» takes a person from `people`, and one can be added on the spot.
  /// False when nothing was written, and the part names nobody new.
  public func createDebtor(named name: String, forPartAt index: Int) -> Bool {
    guard draft.parts.indices.contains(index), let person = createPerson(named: name) else {
      return false
    }
    draft.parts[index].debtorPersonId = person
    return true
  }

  // MARK: Adding from a picker

  /// The sheet «Add…» of a picker asked for, while it is open: which kind of record it makes and
  /// which field of the draft the new record goes into. The panel presents the sheet from this
  /// and the sheet clears it when it closes.
  var adding: AddFromPicker.Kind?

  /// Whether the subcategory menu of a part offers «Add…»: the part has a live top-level category
  /// of the owner's, of the kind of the operation. Not with no category, and not under a system
  /// one: everything under Goals or Loans belongs to the app, and a row added there could never
  /// be renamed or deleted in Settings.
  public func canAddSubcategory(forPartAt index: Int) -> Bool {
    guard draft.parts.indices.contains(index),
      let parent = categoryOfPart(draft.parts[index]),
      categoryTree.systemRole(of: parent) == nil
    else { return false }
    return NewReference.acceptsParent(parent, for: draft.kind.categoryKind, in: categories)
  }

  /// Adds a category of the operation's kind — a subcategory under `parent` — and returns its
  /// id, so the picker can choose it at once. Nil when nothing was written: `parent` cannot take
  /// it, or the database refused (`creationFailureKey` says so).
  public func createCategory(named name: String, under parent: UUID?) -> UUID? {
    guard let references else { return nil }
    return createCategory(named: name, under: parent, saving: references.save)
  }

  func createCategory(
    named name: String, under parent: UUID?, saving save: (CoreKit.Category) throws -> Void
  ) -> UUID? {
    let all =
      (try? references?.categories(includeArchived: true)) ?? categories + archivedCategories
    guard
      let category = NewReference.category(
        named: name, kind: draft.kind.categoryKind, parent: parent, among: all),
      written({ try save(category) }, what: "category")
    else {
      creationFailureKey = "entry.error.categoryNotCreated"
      return nil
    }
    creationFailureKey = nil
    reload()
    return category.id
  }

  /// Adds an event of the days given and returns its id.
  public func createEvent(named name: String, from start: DateOnly, to end: DateOnly) -> UUID? {
    guard let references else { return nil }
    return createEvent(named: name, from: start, to: end, saving: references.save)
  }

  func createEvent(
    named name: String, from start: DateOnly, to end: DateOnly,
    saving save: (Event) throws -> Void
  ) -> UUID? {
    let event = NewReference.event(named: name, from: start, to: end)
    guard written({ try save(event) }, what: "event") else {
      creationFailureKey = "entry.error.eventNotCreated"
      return nil
    }
    creationFailureKey = nil
    reload()
    return event.id
  }

  /// Adds a payment method of `kind` and returns its id. The first one in the book becomes the
  /// default, as it does in Settings.
  public func createPaymentMethod(named name: String, kind: PaymentMethodKind) -> UUID? {
    guard let references else { return nil }
    return createPaymentMethod(named: name, kind: kind, saving: references.save)
  }

  func createPaymentMethod(
    named name: String, kind: PaymentMethodKind, saving save: (PaymentMethod) throws -> Void
  ) -> UUID? {
    let live = (try? references?.paymentMethods()) ?? paymentMethods
    let method = NewReference.paymentMethod(named: name, kind: kind, among: live)
    guard written({ try save(method) }, what: "paymentMethod") else {
      creationFailureKey = "entry.error.paymentMethodNotCreated"
      return nil
    }
    creationFailureKey = nil
    reload()
    return method.id
  }

  /// `save` writes the place: the repository's, or a refusal in a test. A name an archived
  /// place answers to brings that place back instead of a second one of the same name.
  func createPlace(named name: String, saving save: (Place) throws -> Void) -> UUID? {
    var place = archivedPlace(answeringTo: name) ?? Place(name: name)
    place.archived = false
    guard written({ try save(place) }, what: "place") else {
      creationFailureKey = "entry.error.placeNotCreated"
      return nil
    }
    creationFailureKey = nil
    reload()
    suggestedPlaceName = nil
    dropFromTheNote(unmatchedPlacePhrase)
    unmatchedPlacePhrase = nil
    return place.id
  }

  func createPerson(named name: String, saving save: (Person) throws -> Void) -> UUID? {
    var person = archivedPerson(answeringTo: name) ?? Person(name: name)
    person.archived = false
    guard written({ try save(person) }, what: "person") else {
      creationFailureKey = "entry.error.personNotCreated"
      return nil
    }
    creationFailureKey = nil
    reload()
    suggestedPersonName = nil
    dropFromTheNote(unmatchedPersonPhrase)
    unmatchedPersonPhrase = nil
    return person.id
  }

  /// The archived place the line would read `name` as, were it not archived: its name or an
  /// alias, a declined form included («Пятёрочке» is «Пятёрочка»). The line leaves archived
  /// names out — archiving is how a name stops matching — so the only way such a place is
  /// named again is «Add…» of the panel, and nothing else in the app takes a row out of the
  /// archive.
  private func archivedPlace(answeringTo name: String) -> Place? {
    let archived = ((try? references?.places(includeArchived: true)) ?? []).filter(\.archived)
    guard !archived.isEmpty else { return nil }
    let vocabulary = ParserVocabulary(
      places: archived.map { .init(id: $0.id, name: $0.name, aliases: $0.aliases) })
    let id = readsAs(vocabulary, "в \(name)").placeId
    return archived.first { $0.id == id }
  }

  /// The archived person the line would read `name` as; see `archivedPlace(answeringTo:)`.
  private func archivedPerson(answeringTo name: String) -> Person? {
    let archived = ((try? references?.people(includeArchived: true)) ?? []).filter(\.archived)
    guard !archived.isEmpty else { return nil }
    let vocabulary = ParserVocabulary(
      people: archived.map { .init(id: $0.id, name: $0.name, aliases: $0.aliases) })
    let id = readsAs(vocabulary, "для \(name)").personId
    return archived.first { $0.id == id }
  }

  /// A name behind its marker, read by the line's own rules against `vocabulary` alone.
  private func readsAs(_ vocabulary: ParserVocabulary, _ phrase: String) -> ParsedInput {
    InputLineParser(vocabulary: vocabulary, calendar: calendar)
      .parse(phrase, today: calendar.day(of: Date()))
  }

  /// Runs a write of a new name; a refusal goes to the journal with its type, never the name.
  private func written(_ write: () throws -> Void, what: String) -> Bool {
    do {
      try write()
      return true
    } catch {
      AppLog.error(
        "references.saveFailed", .db, "a new name was not saved",
        [
          LogPair("reference", .token(what)),
          LogPair("error", .error(error)),
        ])
      return false
    }
  }

  /// Takes the words of an unknown name back out of the note, where `apply` put them — the
  /// last time they occur, which is where they were added. Only a note the line wrote is
  /// touched, and it stays the line's: the next line still writes over it.
  private func dropFromTheNote(_ phrase: String?) {
    guard let phrase, let note = draft.note, note == noteFromTheLine,
      let range = note.range(of: phrase, options: .backwards)
    else { return }
    var rest = note
    rest.removeSubrange(range)
    let words = rest.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    draft.note = words.isEmpty ? nil : words
    noteFromTheLine = draft.note
  }

  // MARK: Split

  public var isSplit: Bool { draft.parts.count > 1 }

  /// A new part takes what is left of the total and starts with a quality, like every
  /// other part of an operation.
  public func addPart() {
    let remainder = draft.unallocated
    draft.parts.append(PartDraft(amount: remainder.isNegative ? .zero : remainder))
    resolveQuality(ofPartAt: draft.parts.count - 1, in: categoryTree)
  }

  /// «Paid for someone» of the panel. An operation of one part gets a second one — empty, the
  /// total is all mine until an amount is typed into it — and the last part is paid for someone.
  /// An empty part is never saved (`saveRefusalKey`: every part above zero), so the button
  /// cannot leave an owed part of nothing in «Owed to me».
  public func markLastPartPaidForSomeone() {
    if !isSplit { addPart() }
    guard let last = draft.parts.indices.last else { return }
    draft.parts[last].reimbursable = true
  }

  public func removePart(id: UUID) {
    guard canRemovePart(id: id) else { return }
    draft.parts.removeAll { $0.id == id }
    if draft.parts.count == 1 {
      draft.parts[0].amount = draft.amount
    }
  }

  /// A part can go while another stays — unless someone gave the money back for it: a
  /// reimbursement closes it through a link, and taking it away would leave that
  /// reimbursement closing nothing. The status is the one the editor was
  /// opened with; the store asks the row as it is when saving.
  public func canRemovePart(id: UUID) -> Bool {
    draft.parts.count > 1 && !isClosedPart(id: id)
  }

  /// A part someone gave the money back for, as the editor was opened: its amount and
  /// «paid for someone» stay as they are, and so do the currency and the type of the
  /// operation. The store asks the row as it is when saving.
  public func isClosedPart(id: UUID) -> Bool {
    draft.parts.first { $0.id == id }?.reimbursementStatus == .returned
  }

  /// Whether any part is closed that way.
  public var hasClosedPart: Bool {
    draft.parts.contains { $0.reimbursementStatus == .returned }
  }

  public func splitEqually(into count: Int) {
    guard count > 1 else { return }
    let shares = draft.amount.split(into: count)
    let template = draft.parts.first ?? PartDraft()
    draft.parts = shares.map { share in
      var part = template
      part.id = UUID()
      part.amount = share
      return part
    }
  }

  /// Saving is only allowed when nothing stops it.
  public var canSave: Bool { saveRefusalKey == nil }

  /// Why the draft cannot be saved yet, as the key of the words that say so (table «Entry»);
  /// `nil` once it can. The sign is the kind, never the amount: the total and every part are
  /// above zero — the line refuses «кофе 100-250» the same way — the parts add up to the
  /// total, a part paid for someone names who gives it back, a part under
  /// Goals names its goal and a part naming a goal stays under Goals. The rules are
  /// `SplitValidator`'s. A missing category is not one of them: an operation may stay
  /// uncategorised.
  public var saveRefusalKey: String? {
    guard !draft.amount.isZero else { return "entry.error.amountMissing" }
    guard !draft.amount.isNegative else { return "entry.error.amountNotPositive" }
    guard !isOnCredit || draft.kind.canBeBoughtOnCredit || keepsTheSavedCredit else {
      return "entry.error.creditNotPurchase"
    }
    for problem in SplitValidator.validate(draft, categories: categoryTree).problems {
      switch problem {
      case .noParts, .unbalanced: return "entry.error.notBalanced"
      case .emptyPart: return "entry.error.amountNotPositive"
      case .debtorMissing: return "entry.error.debtorMissing"
      case .goalMissing: return "entry.error.goalMissing"
      case .goalCategoryMismatch: return "entry.error.goalCategoryMismatch"
      case .categoryMissing: continue
      }
    }
    return nil
  }

  /// A reason the panel shows by itself, next to its fields: «Save» is inactive for it and
  /// nothing else on screen says why. An empty amount and parts that do not add up say so
  /// already — the field is empty, «Unallocated» turns red.
  public var shownRefusalKey: String? {
    switch saveRefusalKey {
    case "entry.error.amountNotPositive", "entry.error.debtorMissing", "entry.error.goalMissing",
      "entry.error.goalCategoryMismatch", "entry.error.creditNotPurchase":
      saveRefusalKey
    default: nil
    }
  }

  /// Whether the next line would carry something it does not say itself. Esc closes the
  /// panel and keeps its draft, and `apply` keeps what the panel chose — a kind, a place, a
  /// split, a note or a date — as well as a place or a debt a refused line left behind. The ↓
  /// button of the capsule shows it, so none of that goes into the next operation unseen.
  /// What the line writes over — the amount, a note and a date it wrote itself — and a
  /// payment method or a «for whom» the defaults laid, which the next line's defaults lay
  /// again, are not counted.
  public var carriesChoices: Bool {
    let first = draft.parts.first ?? PartDraft()
    let byTheDraft =
      draft.kind != .expense || isSplit || draft.placeId != nil || draft.debtId != nil
      || draft.currency != .rub || draft.periodMonth != nil
      || (draft.paymentMethodId != nil && draft.paymentMethodId != paymentMethodFromDefaults)
      || (draft.note != nil && draft.note != noteFromTheLine)
      || draft.occurredAt != dateFromTheLine
    let forWhom = ForWhomChoice(of: first)
    let byThePart =
      first.categoryId != nil || first.qualitySource == .manual
      || (forWhom != .me && forWhom != forWhomFromDefaults) || first.eventId != nil
      || first.goalId != nil || first.reimbursable
    return byTheDraft || byThePart || creditPlan != nil || expectedIncomeId != nil
  }

  /// Money back from a person is not written by Enter: it closes the parts the person owed
  /// through links and is not income, and the person and the parts are chosen in the
  /// reimbursement sheet («Кнопка … или тип в панели ↓»). The line hands the draft over to
  /// it, prefilled (`ReimbursementPrefill`); on its own it would write a reimbursement that
  /// closes nothing. Money given back on a debt owed to me is that debt's payment and stays
  /// with the line.
  public var recordsThroughReimbursementSheet: Bool {
    draft.kind == .reimbursement && draft.debtId == nil
  }

  /// Whether the purchase is on credit: a plan being made in the line, or a debt the saved
  /// purchase joined. The box of the panel reads this, in the line and in the editor alike.
  public var isOnCredit: Bool { creditPlan != nil || draft.creditDebtId != nil }

  /// A purchase is put on credit when it is recorded: the line opens the debt, or joins one,
  /// in the same write. The editor writes the operation and its journal line only — a plan
  /// made there was never written, and taking a purchase off its debt from there made it
  /// deletable, though a purchase that moved a debt is never deleted from the list — so a
  /// saved purchase is changed in Debts.
  public var canChangeCredit: Bool { !editsSavedOperation }

  /// Only a purchase is bought on credit: an income or a refund on credit opened an instalment
  /// debt that nothing bought. The switch is offered for a purchase in the entry line.
  public var offersCredit: Bool { canChangeCredit && draft.kind.canBeBoughtOnCredit }

  /// An income or a refund saved on credit before only a purchase could be — such rows exist —
  /// is edited as it is: its note or category changes, and the debt stays as it was saved.
  /// What is refused is turning an operation on credit into another kind that is never bought
  /// on credit.
  private var keepsTheSavedCredit: Bool {
    editsSavedOperation && creditPlan == nil && draft.kind == kindWithTheCredit
  }

  /// A kind that cannot be bought on credit drops the plan made for the purchase it was — in
  /// the panel and by a line that says «+» alike. A saved operation keeps its debt: the editor
  /// refuses the change instead (`saveRefusalKey`).
  private func dropTheCreditTheKindCannotCarry() {
    guard canChangeCredit, !draft.kind.canBeBoughtOnCredit else { return }
    creditPlan = nil
    draft.creditDebtId = nil
  }

  /// The link of income to an expected one is written by the line with the income. An income
  /// already saved is tied to what was expected in Planning.
  public var linksExpectedIncome: Bool { !editsSavedOperation }

  // MARK: Credit plan

  /// A debt keeps no term: it is paid off in ⌈balance ÷ monthly payment⌉ months (`DebtPayoff`,
  /// the payoff scenario of the Debts card). The count of payments the panel shows is therefore kept in
  /// the instalment it gives, and the two move together: the count chosen makes
  /// the instalment, an instalment typed makes the count, and the amount corrected keeps the
  /// count and moves the instalment.
  public static let creditPaymentsRange = 1...120

  /// The count chosen with the stepper: the instalment is the amount split into that many.
  public func setCreditPayments(_ payments: Int) {
    guard var plan = creditPlan else { return }
    plan.payments = Self.withinRange(payments)
    plan.monthlyAmount = Self.instalment(of: draft.amount, over: plan.payments)
    creditPlan = plan
  }

  /// An instalment typed by hand: the count is how many of them pay the amount off, the last
  /// one smaller. An empty field leaves the count as it was.
  public func setCreditMonthly(_ monthly: AmountE4) {
    guard var plan = creditPlan, plan.monthlyAmount != monthly else { return }
    plan.monthlyAmount = monthly
    if monthly.raw > 0, draft.amount.raw > 0 {
      let count = (draft.amount.raw + monthly.raw - 1) / monthly.raw
      plan.payments = Self.withinRange(Int(clamping: count))
    }
    creditPlan = plan
  }

  /// The total of the operation, as the amount field of the panel sets it. A draft with a
  /// single part keeps that part in step; a split keeps its parts and shows what is left.
  ///
  /// `typed` is the text of the field. `amount_expr` is the formula the amount was worked out
  /// from: a formula typed in the field becomes it, and one that no longer
  /// comes to the total goes, instead of standing in the table over another amount. The field
  /// writing back the amount it shows is not a correction and keeps it.
  public func setTotal(_ amount: AmountE4, typed text: String? = nil) {
    draft.amount = amount
    if draft.parts.count == 1 { draft.parts[0].amount = amount }
    draft.amountExpression = Self.formula(
      typed: text, keeping: draft.amountExpression, for: amount)
    followTheAmountInTheCreditPlan()
  }

  /// The formula behind `amount`: the one typed, when the text is one, its numbers written the
  /// way the app writes them; otherwise the one kept, while it still comes to the amount. The
  /// one kept stays exactly as it is: the field writes back the amount it shows as soon as an
  /// operation is opened, and that is not an edit to save (the editor rewrites it on save).
  private static func formula(
    typed text: String?, keeping kept: String?, for amount: AmountE4
  )
    -> String?
  {
    if let typed = text?.trimmingCharacters(in: .whitespaces),
      ExpressionEvaluator.isFormula(typed), comes(typed, to: amount)
    {
      return ExpressionEvaluator.canonical(typed) ?? typed
    }
    guard let kept, comes(kept, to: amount) else { return nil }
    return kept
  }

  private static func comes(_ formula: String, to amount: AmountE4) -> Bool {
    guard let value = try? ExpressionEvaluator.evaluate(formula) else { return false }
    return (try? AmountE4(decimal: value)) == amount
  }

  /// The count stands and the instalment follows a new amount.
  private func followTheAmountInTheCreditPlan() {
    guard var plan = creditPlan else { return }
    let monthly = Self.instalment(of: draft.amount, over: plan.payments)
    guard plan.monthlyAmount != monthly else { return }
    plan.monthlyAmount = monthly
    creditPlan = plan
  }

  private static func withinRange(_ payments: Int) -> Int {
    min(max(payments, creditPaymentsRange.lowerBound), creditPaymentsRange.upperBound)
  }

  /// The largest share of `amount` split into `payments`: that many of it pay the amount off.
  private static func instalment(of amount: AmountE4, over payments: Int) -> AmountE4 {
    guard amount.raw > 0 else { return .zero }
    return amount.split(into: payments).first ?? .zero
  }

  /// Turns the plan on with a sensible instalment: the whole amount split evenly.
  public func startCreditPlan() {
    guard offersCredit, creditPlan == nil else { return }
    let payments = 12
    creditPlan = CreditPlan(
      debtId: nil, payments: payments,
      monthlyAmount: Self.instalment(of: draft.amount, over: payments))
  }

  public func stopCreditPlan() {
    guard canChangeCredit else { return }
    creditPlan = nil
    draft.creditDebtId = nil
  }

  public func reset() {
    draft = TransactionDraft()
    draft.normalizeSinglePart()
    // The names belonged to the line just saved: the next operation is not offered them.
    suggestedPersonName = nil
    suggestedPlaceName = nil
    unmatchedPersonPhrase = nil
    unmatchedPlacePhrase = nil
    noteFromTheLine = nil
    dateFromTheLine = draft.occurredAt
    dateFollowsTheClock = true
    paymentMethodFromDefaults = nil
    forWhomFromDefaults = .me
    // So were the suggestions: the event, the chips, where each came from, what the model said.
    suggestedEvent = nil
    categorySuggestions = []
    suggestionSources = [:]
    lastPrediction = nil
    lastQuestion = nil
    creditPlan = nil
    expectedIncomeId = nil
    creationFailureKey = nil
  }
}

extension TransactionKind {
  /// Only a purchase is bought on credit: an income, a refund or money back buys nothing, and a
  /// debt opened for one would be paid off by nothing.
  var canBeBoughtOnCredit: Bool { self == .expense }
}
