import AppCore
import AppDatabase
import XCTest

@testable import Itogo

/// The actions on the cards of an account and on their cashback rules, against a real
/// database: each is one step of ⌘Z, a name another account or live card holds is refused in
/// words, a used card only goes to the archive, the first card takes the account's own rules,
/// and «Запомнить» is a step of its own.
@MainActor
final class CardActionsTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["ITOGO_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-cards-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("ITOGO_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("ITOGO_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("ITOGO_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private var actions: CardActions { CardActions(environment: environment, store: store) }

  private func account(_ name: String, kind: PaymentMethodKind = .card) throws -> PaymentMethod {
    let account = PaymentMethod(name: name, kind: kind, currency: .rub)
    try XCTUnwrap(environment.references).save(account)
    return account
  }

  private func category(_ name: String) throws -> CoreKit.Category {
    let category = CoreKit.Category(kind: .expense, name: name)
    try XCTUnwrap(environment.references).save(category)
    return category
  }

  private func percent(_ e4: Int64) -> CashbackPercent { CashbackPercent(e4: e4)! }

  // MARK: Cards

  func testAddingRenamingAndUndoingACardAreOneStepEach() throws {
    let tBank = try account("Т-Банк")
    let black = PaymentCard(accountId: tBank.id, name: " Black ", aliases: ["чёрная", " "])
    XCTAssertEqual(actions.save(black, previous: nil), .done)
    let saved = try XCTUnwrap(actions.cards.first)
    XCTAssertEqual(saved.name, "Black")
    XCTAssertEqual(saved.aliases, ["чёрная"], "other names are tidied")

    var renamed = saved
    renamed.name = "Black Metal"
    XCTAssertEqual(actions.save(renamed, previous: saved), .done)
    XCTAssertEqual(actions.cards.map(\.name), ["Black Metal"])
    store.undo()
    XCTAssertEqual(actions.cards.map(\.name), ["Black"], "a rename is one step")
    store.undo()
    XCTAssertTrue(actions.cards.isEmpty, "adding is one step")
  }

  func testANameAnotherAccountOrLiveCardHoldsIsRefused() throws {
    let tBank = try account("Т-Банк")
    let sber = try account("Сбер")
    XCTAssertEqual(
      actions.save(PaymentCard(accountId: tBank.id, name: "сбер"), previous: nil),
      .refused(.card(.nameTaken(owner: .account(sber.id)))))
    XCTAssertEqual(
      actions.save(PaymentCard(accountId: tBank.id, name: "Т-Банк"), previous: nil), .done,
      "a card may carry its own account's name")
    let virtual = PaymentCard(accountId: tBank.id, name: "Virtual")
    XCTAssertEqual(actions.save(virtual, previous: nil), .done)
    XCTAssertEqual(
      actions.save(PaymentCard(accountId: tBank.id, name: "VIRTUAL"), previous: nil),
      .refused(.card(.nameTaken(owner: .card(virtual.id)))))
    XCTAssertEqual(actions.cards.count, 2, "nothing was written by a refusal")
  }

  func testArchiveAndRestoreRefusedWhileTheNameIsTaken() throws {
    let tBank = try account("Т-Банк")
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    XCTAssertEqual(actions.save(black, previous: nil), .done)
    XCTAssertEqual(actions.archive(black.id), .done)
    XCTAssertEqual(actions.cards.first?.archived, true)
    let second = PaymentCard(accountId: tBank.id, name: "Black")
    XCTAssertEqual(actions.save(second, previous: nil), .done, "an archived card holds no name")
    XCTAssertEqual(
      actions.restore(black.id), .refused(.card(.nameTaken(owner: .card(second.id)))))
    store.undo()
    XCTAssertEqual(actions.restore(black.id), .done)
    XCTAssertEqual(actions.cards.first { $0.id == black.id }?.archived, false)
  }

  func testOnlyAnUnusedCardIsDeletedAndUndoBringsItsRules() throws {
    let tBank = try account("Т-Банк")
    let groceries = try category("Продукты")
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    let used = PaymentCard(accountId: tBank.id, name: "Used")
    XCTAssertEqual(actions.save(black, previous: nil), .done)
    XCTAssertEqual(actions.save(used, previous: nil), .done)
    let rule = CashbackRule(
      accountId: tBank.id, cardId: black.id, categoryId: groceries.id, percent: percent(30_000))
    XCTAssertEqual(actions.saveRules(of: [.card(black.id)], [rule]), .done)
    let purchase = TransactionDraft(
      amount: AmountE4(whole: 100), paymentMethodId: tBank.id,
      parts: [PartDraft(amount: AmountE4(whole: 100))], cardId: used.id)
    XCTAssertTrue(store.save(try purchase.materialize()))

    guard case .refused(.inUse(let usage)) = actions.delete(used.id) else {
      return XCTFail("a used card is not deleted")
    }
    XCTAssertEqual(usage.operations, 1)
    XCTAssertEqual(actions.delete(black.id), .done)
    XCTAssertTrue(actions.rules.isEmpty, "its rules went with it")
    store.undo()
    XCTAssertEqual(actions.rules, [rule], "⌘Z brings the card and its rules back")
    XCTAssertTrue(actions.cards.contains { $0.id == black.id })
  }

  /// Cash had rules of its own; its first card takes them over in the same step.
  func testTheFirstCardTakesTheAccountsRules() throws {
    let cash = try account("Кошелёк", kind: .other)
    let own = CashbackRule(accountId: cash.id, percent: percent(10_000))
    XCTAssertEqual(actions.saveRules(of: [.account(cash.id)], [own]), .done)
    let card = PaymentCard(accountId: cash.id, name: "Карта кошелька")
    XCTAssertEqual(actions.save(card, previous: nil), .done)
    XCTAssertEqual(actions.rules.map(\.cardId), [card.id])
    XCTAssertEqual(actions.rules.map(\.id), [own.id])
    store.undo()
    XCTAssertEqual(actions.rules.map(\.cardId), [nil], "one step: card and rules go back")
    XCTAssertTrue(actions.cards.isEmpty)
  }

  /// An account whose only card is in the archive keeps rules of its own. «Вернуть» the card:
  /// the account's rules move onto it in the same step — where the card has a rule of the same
  /// key, the card's rule stays and the account's goes —, and one ⌘Z brings back the archive and
  /// the account's rules.
  func testRestoringTheOnlyCardTakesTheAccountsRules() throws {
    let tBank = try account("Т-Банк")
    let cafes = try category("Кафе")
    let groceries = try category("Продукты")
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    XCTAssertEqual(actions.save(black, previous: nil), .done)
    let cardCafes = CashbackRule(
      accountId: tBank.id, cardId: black.id, categoryId: cafes.id, percent: percent(50_000))
    XCTAssertEqual(actions.saveRules(of: [.card(black.id)], [cardCafes]), .done)
    XCTAssertEqual(actions.archive(black.id), .done)
    XCTAssertEqual(
      CashbackHolders.editableHolders(of: tBank.id, cards: actions.cards), [.account(tBank.id)])
    let ownCafes = CashbackRule(
      accountId: tBank.id, categoryId: cafes.id, percent: percent(70_000))
    let ownGroceries = CashbackRule(
      accountId: tBank.id, categoryId: groceries.id, percent: percent(30_000))
    XCTAssertEqual(actions.saveRules(of: [.account(tBank.id)], [ownCafes, ownGroceries]), .done)
    let before = Set(actions.rules)

    XCTAssertEqual(actions.restore(black.id), .done)
    let after = actions.rules
    XCTAssertTrue(after.allSatisfy { $0.cardId == black.id }, "no rule is left on the account")
    XCTAssertEqual(
      Set(after.map { "\($0.categoryId!) \($0.percent.e4)" }),
      ["\(cafes.id) 50000", "\(groceries.id) 30000"], "the card's own rule of a key wins")
    XCTAssertEqual(after.first { $0.categoryId == groceries.id }?.id, ownGroceries.id)
    store.undo()
    XCTAssertEqual(Set(actions.rules), before)
    XCTAssertEqual(actions.cards.first?.archived, true, "one step: card and rules go back")
  }

  // MARK: Rules

  /// Two rows of the sheet swap their categories and a percent changes: saved by key, in one
  /// step, and ⌘Z gives the old rules back.
  func testTheRulesSheetSavesASwapInOneStep() throws {
    let tBank = try account("Т-Банк")
    let cafes = try category("Кафе")
    let groceries = try category("Продукты")
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    XCTAssertEqual(actions.save(black, previous: nil), .done)
    let first = CashbackRule(
      accountId: tBank.id, cardId: black.id, categoryId: cafes.id, percent: percent(50_000))
    let second = CashbackRule(
      accountId: tBank.id, cardId: black.id, categoryId: groceries.id, percent: percent(30_000))
    XCTAssertEqual(actions.saveRules(of: [.card(black.id)], [first, second]), .done)
    var swappedFirst = first
    swappedFirst.categoryId = groceries.id
    swappedFirst.percent = percent(70_000)
    var swappedSecond = second
    swappedSecond.categoryId = cafes.id
    swappedSecond.percent = percent(50_000)
    XCTAssertEqual(actions.saveRules(of: [.card(black.id)], [swappedFirst, swappedSecond]), .done)
    XCTAssertEqual(
      Set(actions.rules.map { "\($0.categoryId!) \($0.percent.e4)" }),
      ["\(cafes.id) 50000", "\(groceries.id) 70000"])
    store.undo()
    XCTAssertEqual(Set(actions.rules), [first, second])
    // A duplicate never reaches the database.
    XCTAssertEqual(
      actions.saveRules(of: [.card(black.id)], [first, first.with(id: UUID())]),
      .refused(.rules(.duplicate(first.key))))
  }

  /// «Запомнить»: a typed 7 % becomes a rule of the card at once, one step of its own; a second
  /// «Запомнить» of the same key takes the same row.
  func testRememberIsItsOwnStepAndReusesTheKey() throws {
    let tBank = try account("Т-Банк")
    let pharmacy = try category("Аптеки")
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    XCTAssertEqual(actions.save(black, previous: nil), .done)
    let september = MonthKey(year: 2026, month: 9)
    let typed = CashbackRule(
      accountId: tBank.id, cardId: black.id, categoryId: pharmacy.id, month: september,
      percent: percent(70_000))
    XCTAssertEqual(actions.remember(typed), .done)
    XCTAssertEqual(actions.rules, [typed])
    var again = typed
    again.id = UUID()
    again.percent = percent(80_000)
    XCTAssertEqual(actions.remember(again), .done)
    XCTAssertEqual(actions.rules.map(\.id), [typed.id])
    XCTAssertEqual(actions.rules.first?.percent, percent(80_000))
    store.undo()
    XCTAssertEqual(actions.rules, [typed])
    store.undo()
    XCTAssertTrue(actions.rules.isEmpty)
    XCTAssertEqual(actions.cards.count, 1, "the card was a step before")
  }

  func testTheWordsOfARefusalNameWhoHoldsTheName() throws {
    let sber = try account("Сбер")
    let text = CardText.message(
      .card(.nameTaken(owner: .account(sber.id))), cards: [], accounts: [sber], categories: [:],
      environment)
    XCTAssertTrue(text.contains("Сбер"), text)
    XCTAssertFalse(text.contains("card.refusal"), text)
  }

  func testTheMonthInItsPrepositionalCase() throws {
    let september = MonthKey(year: 2026, month: 9)
    let words = environment.language(DateFormatting.monthInKey(september))
    XCTAssertFalse(words.hasPrefix("month.in"), "the key is in Common")
    XCTAssertEqual(
      environment.dates.monthIn(september, thisYear: 2026, words: words), words)
    XCTAssertEqual(
      environment.dates.monthIn(september, thisYear: 2025, words: words), words + " 2026")
  }
}

extension CashbackRule {
  fileprivate func with(id: UUID) -> CashbackRule {
    var copy = self
    copy.id = id
    return copy
  }
}
