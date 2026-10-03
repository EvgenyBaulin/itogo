import AppCore
import AppDatabase
import Foundation
import SwiftUI

/// Why an action on a card or on cashback rules was not taken.
enum CardRefusal: Error, Hashable, Sendable {
  /// The name, another name, or the account of the card.
  case card(CardIssue)
  /// Operations or scheduled payments name the card: it can only go to the archive.
  case inUse(CardUsage)
  case rules(CashbackRuleIssue)
  /// The account the cashback comes to as points.
  case points(CashbackPointsIssue)
  case notFound
}

/// What came of an action on a card or on the rules.
enum CardActionOutcome: Hashable, Sendable {
  case done
  case refused(CardRefusal)
  /// The database did not take the write; the journal says why.
  case failed
}

/// The actions on the cards of an account and on the cashback rules. Each one is a
/// `PlanningChange` — one write and one step of ⌘Z —, and the entry line learns the new names at
/// once.
@MainActor
struct CardActions {
  let environment: AppEnvironment
  let store: TransactionsStore

  init(environment: AppEnvironment, store: TransactionsStore) {
    self.environment = environment
    self.store = store
  }

  // MARK: Reading

  private var repository: CardRepository? {
    environment.stack.map { CardRepository(writer: $0.writer) }
  }

  /// Every card, archived ones too, in the owner's order.
  var cards: [PaymentCard] { (try? repository?.cards(includeArchived: true)) ?? [] }

  /// Every cashback rule.
  var rules: [CashbackRule] { (try? repository?.rules()) ?? [] }

  /// Every account, archived ones too.
  var accounts: [PaymentMethod] {
    (try? environment.accounts?.accounts(includeArchived: true)) ?? []
  }

  /// Every category, archived ones too.
  var categories: [CoreKit.Category] {
    (try? environment.references?.categories(includeArchived: true)) ?? []
  }

  /// The categories of the reconciliation differences: a rule never names them.
  var reconcileCategoryIds: Set<UUID> {
    guard let settings = environment.settings else { return [] }
    let keys = [
      PlanningSettings.reconcileExpenseCategoryKey, PlanningSettings.reconcileIncomeCategoryKey,
    ]
    return Set(
      keys.compactMap { key in (try? settings.string(key)).flatMap { UUID(uuidString: $0) } })
  }

  // MARK: Cards

  /// Saves a new card (`previous == nil`) or an edit of one. A card keeps no rules of its own to
  /// begin with: it follows the rules of its account, whatever cards the account has had.
  func save(_ card: PaymentCard, previous: PaymentCard?) -> CardActionOutcome {
    var card = card
    card.name = card.name.trimmingCharacters(in: .whitespacesAndNewlines)
    card.aliases = Self.tidied(card.aliases)
    let cards = self.cards
    let issues = CardRules.validate(card, previous: previous, cards: cards, accounts: accounts)
    if let issue = issues.first { return refuse(.card(issue)) }
    if previous == nil {
      let siblings = cards.filter { $0.accountId == card.accountId }
      if siblings.contains(where: { $0.sort > 0 }) {
        card.sort = (siblings.map(\.sort).max() ?? 0) + 1
      }
    }
    let outcome = apply(
      PlanningChange(upsert: PlanningRows(cards: [card]), at: environment.now()))
    if outcome == .done {
      AppLog.info(
        "cards.saved", .db, "a card was saved",
        [
          LogPair("card", .id(card.id)), LogPair("new", .flag(previous == nil)),
        ])
    }
    return outcome
  }

  /// «В архив»: the card leaves the pickers and the entry line; its operations keep it.
  func archive(_ id: UUID) -> CardActionOutcome {
    guard var card = cards.first(where: { $0.id == id }) else { return refuse(.notFound) }
    guard !card.archived else { return .done }
    card.archived = true
    return apply(PlanningChange(upsert: PlanningRows(cards: [card]), at: environment.now()))
  }

  /// «Вернуть»: refused while another account or live card has taken the name, or while the
  /// account is in the archive. The card comes back with the rules of its own it kept.
  func restore(_ id: UUID) -> CardActionOutcome {
    let cards = self.cards
    guard let previous = cards.first(where: { $0.id == id }) else { return refuse(.notFound) }
    guard previous.archived else { return .done }
    var card = previous
    card.archived = false
    let issues = CardRules.validate(card, previous: previous, cards: cards, accounts: accounts)
    if let issue = issues.first { return refuse(.card(issue)) }
    return apply(PlanningChange(upsert: PlanningRows(cards: [card]), at: environment.now()))
  }

  /// Deletes a card nothing names, with its rules; ⌘Z brings both back. A card an operation — in
  /// the bin too — or a scheduled payment names can only go to the archive.
  func delete(_ id: UUID) -> CardActionOutcome {
    guard let repository, cards.contains(where: { $0.id == id }) else {
      return refuse(.notFound)
    }
    guard let usage = try? repository.usage(of: id) else { return .failed }
    guard !usage.isUsed else { return refuse(.inUse(usage)) }
    let outcome = apply(
      PlanningChange(delete: PlanningRowIDs(cards: [id]), at: environment.now()))
    if outcome == .done {
      AppLog.info("cards.deleted", .db, "an unused card was deleted", [LogPair("card", .id(id))])
    }
    return outcome
  }

  // MARK: Rules

  /// The save of the rules sheet: `edited` are the rules of `holders` as the sheet holds them.
  /// They are written by key (`CashbackRules.diff`), in one step; nothing changed, nothing is
  /// written. `account` is the account with the settings of its cashback the sheet holds
  /// (`CashbackAccountSettings`), written in the same step when they differ from what is stored.
  func saveRules(
    of holders: [CashbackHolder], _ edited: [CashbackRule], account: PaymentMethod? = nil
  ) -> CardActionOutcome {
    let all = rules
    let old = all.filter { holders.contains($0.holder) }
    let issues = CashbackRules.issues(
      edited, tree: CategoryTree(categories), reconcileCategoryIds: reconcileCategoryIds)
    if let issue = issues.first { return refuse(.rules(issue)) }
    let accounts = self.accounts
    var changedAccount: PaymentMethod?
    if let account, let stored = accounts.first(where: { $0.id == account.id }),
      CashbackAccountSettings(account).differs(from: stored)
    {
      if let issue = CashbackPoints.issues(
        for: account.id, pointsAccountId: account.cashbackPointsAccountId, accounts: accounts
      ).first, account.cashbackPointsAccountId != stored.cashbackPointsAccountId {
        return refuse(.points(issue))
      }
      changedAccount = CashbackAccountSettings(account).applied(to: stored)
    }
    let diff = CashbackRules.diff(old: old, new: edited)
    guard !diff.upserts.isEmpty || !diff.deletions.isEmpty || changedAccount != nil else {
      return .done
    }
    let outcome = apply(
      PlanningChange(
        upsert: PlanningRows(
          paymentMethods: changedAccount.map { [$0] } ?? [], cashbackRules: diff.upserts),
        delete: PlanningRowIDs(cashbackRules: diff.deletions), at: environment.now()))
    if outcome == .done {
      AppLog.info(
        "cashback.rulesSaved", .db, "the cashback rules of a sheet were saved",
        [
          LogPair("upserted", .count(diff.upserts.count)),
          LogPair("deleted", .count(diff.deletions.count)),
          LogPair("settings", .flag(changedAccount != nil)),
        ])
    }
    return outcome
  }

  /// «Запомнить» of the ↓ panel: the typed percent becomes a rule at once, its own step of ⌘Z —
  /// the account's, or the card's own where the card already differs from its account for that
  /// month and category. A rule kept for the same holder, month and category takes the new
  /// percent.
  func remember(_ rule: CashbackRule) -> CardActionOutcome {
    let written = CashbackRules.upserting(rule, into: rules)
    let issues = CashbackRules.issues(
      [written], tree: CategoryTree(categories), reconcileCategoryIds: reconcileCategoryIds)
    if let issue = issues.first { return refuse(.rules(issue)) }
    let outcome = apply(
      PlanningChange(upsert: PlanningRows(cashbackRules: [written]), at: environment.now()))
    if outcome == .done {
      AppLog.info(
        "cashback.ruleRemembered", .db, "a typed percent became a cashback rule",
        [LogPair("rules", .count(1)), LogPair("month", .flag(written.month != nil))])
    }
    return outcome
  }

  // MARK: Helpers

  /// Other names trimmed, empty ones and repeats left out, one per line as they are kept.
  static func tidied(_ aliases: [String]) -> [String] {
    var seen: Set<String> = []
    return aliases.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && seen.insert(NameKey.fold($0)).inserted }
  }

  private func refuse(_ refusal: CardRefusal) -> CardActionOutcome {
    AppLog.info(
      "cards.refused", .db, "an action on a card or its rules was refused",
      [LogPair("reason", .token(Self.token(refusal)))])
    return .refused(refusal)
  }

  private static func token(_ refusal: CardRefusal) -> String {
    switch refusal {
    case .card(.emptyName): "emptyName"
    case .card(.nameTaken): "nameTaken"
    case .card(.otherNameTaken): "otherNameTaken"
    case .card(.accountArchived): "accountArchived"
    case .inUse: "inUse"
    case .rules(.duplicate): "duplicate"
    case .rules(.categoryNotExpense): "notExpense"
    case .rules(.categoryIsGoal): "goal"
    case .rules(.categoryIsReconciliation): "reconciliation"
    case .rules(.categoryIsLoan): "loan"
    case .points(.isItself): "pointsItself"
    case .points(.notFound): "pointsMissing"
    case .points(.archived): "pointsArchived"
    case .notFound: "notFound"
    }
  }

  private func apply(_ change: PlanningChange) -> CardActionOutcome {
    guard store.apply(change) else { return .failed }
    environment.refreshVocabulary()
    return .done
  }
}

// MARK: - Pickers

/// The choices of a picker of accounts that also offers their cards, as the books are filed
/// «bank → account → card» (`AccountLabels`): a bank with one account and one card is named by the
/// bank alone, an account with two cards or more offers itself and each card under it —
/// «Т-Банк › Black» —, a card called like its account or its bank is not offered a second time.
/// One `UUID` stands for either, an account or a card; `CardRules.resolve` turns it back into the
/// account and the card.
enum AccountCardChoices {
  struct Item: Equatable, Identifiable {
    var id: UUID
    var name: String
    /// The id of a card, not of an account.
    var isCard: Bool
  }

  /// `accounts` in the order to show them — archived ones are the caller's choice; an archived
  /// card, and the cards of an account not listed, are not offered. `every` is every account
  /// there is, when `accounts` leaves some out: a bank is told to have as many accounts as the
  /// live ones, not as are offered.
  static func items(
    accounts: [PaymentMethod], cards: [PaymentCard], banks: [Bank] = [],
    among every: [PaymentMethod]? = nil, locale: Locale
  ) -> [Item] {
    AccountLabels(accounts: every ?? accounts, cards: cards, banks: banks)
      .entries(offering: accounts, withCards: true, locale: locale)
      .map { Item(id: $0.id, name: $0.name, isCard: $0.isCard) }
  }

  /// What a picker shows for an account and a card: the card when it is among the choices,
  /// else the account.
  static func selection(accountId: UUID?, cardId: UUID?, items: [Item]) -> UUID? {
    if let cardId, items.contains(where: { $0.id == cardId && $0.isCard }) { return cardId }
    return accountId
  }
}

// MARK: - Words

/// The words of the cards and of cashback, shared by the account's screen, the sheets and the
/// settings.
@MainActor
enum CardText {
  static let table = "Accounts"

  /// «Black», «Т-Банк · Black» — see `CardRules.displayName`.
  static func holderName(
    _ holder: CashbackHolder, cards: [PaymentCard], accounts: [PaymentMethod]
  ) -> String {
    switch holder {
    case .account(let id):
      return accounts.first { $0.id == id }?.name ?? ""
    case .card(let id):
      guard let card = cards.first(where: { $0.id == id }) else { return "" }
      let account = accounts.first { $0.id == card.accountId }?.name ?? ""
      return CardRules.displayName(account: account, card: card.name)
    }
  }

  /// «10 % — Кафе и рестораны, только в сентябре»; «1 % — всё остальное, всегда».
  static func ruleLine(
    _ rule: CashbackRule, categories: [UUID: String], _ environment: AppEnvironment
  ) -> String {
    let category =
      rule.categoryId.flatMap { categories[$0] }
      ?? environment.language("cashback.everythingElse", table: table)
    let scope =
      rule.month.map {
        environment.format("cashback.rule.onlyIn", table: table, environment.monthIn($0))
      } ?? environment.language("cashback.rule.always", table: table)
    return environment.format(
      "cashback.rule.line", table: table, environment.money.percent(rule.percent), category,
      scope)
  }

  /// Why an action on a card or on the rules was not taken.
  static func message(
    _ refusal: CardRefusal, cards: [PaymentCard], accounts: [PaymentMethod],
    categories: [UUID: String], _ environment: AppEnvironment
  ) -> String {
    func t(_ key: String) -> String { environment.language(key, table: table) }
    func owner(_ owner: CardNameOwner) -> String {
      switch owner {
      case .account(let id): return accounts.first { $0.id == id }?.name ?? ""
      case .card(let id): return holderName(.card(id), cards: cards, accounts: accounts)
      }
    }
    switch refusal {
    case .card(.emptyName): return t("card.refusal.emptyName")
    case .card(.nameTaken(let who)):
      return environment.format("card.refusal.nameTaken", table: table, owner(who))
    case .card(.otherNameTaken(let name, let who)):
      return environment.format("card.refusal.otherNameTaken", table: table, name, owner(who))
    case .card(.accountArchived): return t("card.refusal.accountArchived")
    case .inUse: return t("card.refusal.inUse")
    case .rules(.duplicate(let key)):
      let name =
        key.categoryId.flatMap { categories[$0] } ?? t("cashback.everythingElse")
      return environment.format("cashback.refusal.duplicate", table: table, name)
    case .rules(.categoryNotExpense), .rules(.categoryIsGoal), .rules(.categoryIsReconciliation):
      return t("cashback.refusal.category")
    case .rules(.categoryIsLoan): return t("cashback.refusal.loan")
    case .points(.isItself): return t("cashback.refusal.pointsItself")
    case .points(.notFound): return t("cashback.refusal.pointsMissing")
    case .points(.archived): return t("cashback.refusal.pointsArchived")
    case .notFound: return t("card.refusal.notFound")
    }
  }
}

extension AppEnvironment {
  /// «в сентябре», «in September»; with the year when it is not this year: «в сентябре 2027».
  func monthIn(_ month: MonthKey) -> String {
    dates.monthIn(
      month, thisYear: today.year, words: language(DateFormatting.monthInKey(month)))
  }
}
