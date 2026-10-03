import AppCore
import AppDatabase
import XCTest

@testable import Itogo

/// «Кэшбэк» of the ↓ panel with the owner's example (`CardEntryBook`): what the rules of the card
/// expect, a figure or a percent typed for one operation and saved with it, «Запомнить» as a step
/// of ⌘Z of its own, and a field that does not read never stopping the save.
@MainActor
final class EntryCashbackFieldTests: XCTestCase {
  private var book: CardEntryBook!
  private var host: EntryHost?

  override func setUp() async throws {
    book = try await CardEntryBook()
  }

  override func tearDown() async throws {
    host?.close()
    host = nil
    await book?.close()
    book = nil
  }

  private func rub(_ whole: Int64, _ cents: Int64 = 0) -> Money {
    Money(amount: AmountE4(raw: whole * 10_000 + cents * 100), currency: .rub)
  }

  /// «кофе 350 black» in «Кофейни»: the month's 10 % of «Кафе и рестораны» beats the 3 % of
  /// «Кофейни» always — 35.00 ₽, said by the one rule that priced it.
  func testShowsExpectedFromRules() throws {
    let model = book.model()
    try book.enter("кофе 350 black", into: model)
    model.setCategory(book.cafe.id, forPartAt: 0)
    model.setSubcategory(book.coffeeShops.id, forPartAt: 0)
    XCTAssertTrue(model.showsCashback)
    XCTAssertEqual(model.cashbackHolder, .card(book.black.id))
    let expected = try XCTUnwrap(model.cashbackExpectation)
    XCTAssertEqual(expected.money, rub(35))
    guard case .rules(let ids) = expected.source else { return XCTFail("priced by the rules") }
    let month = book.environment.today.monthKey
    XCTAssertEqual(
      model.cashbackContext.rules.filter { ids.contains($0.id) }.map(\.month), [month],
      "the month's rule of «Кафе и рестораны»")
    XCTAssertEqual(model.cashbackContext.holderName, "Т-Банк › Black")
    XCTAssertNil(model.draft.cashback, "an expectation is no figure of the operation")
    let saved = try book.save(model)
    XCTAssertNil(try book.stored(saved.id)?.transaction.cashback)

    // «Т-Банк» alone has two cards: nothing is guessed.
    let account = book.model()
    try book.enter("кофе 350 т-банк", into: account)
    XCTAssertEqual(account.cashbackHolder, .account(book.tBank.id))
    XCTAssertTrue(account.cashbackContext.severalCards)
    XCTAssertNil(account.cashbackExpectation)
  }

  /// «40» typed: the operation keeps 40.00 ₽ as its own figure.
  func testATypedAmountIsSaved() throws {
    let model = book.model()
    try book.enter("кофе 350 black", into: model)
    model.cashbackField.text = "40"
    XCTAssertEqual(model.draft.cashback, rub(40))
    XCTAssertEqual(model.cashbackExpectation?.money, rub(40))
    XCTAssertEqual(model.cashbackExpectation?.source, .override)
    let saved = try book.save(model)
    XCTAssertEqual(try book.stored(saved.id)?.transaction.cashback, rub(40))

    // The editor opens it with the figure in the field, and a save of another change keeps it.
    let stored = try XCTUnwrap(try book.stored(saved.id))
    let editor = TransactionEditorModel(entry: stored, environment: book.environment)
    XCTAssertEqual(editor.draft.cashbackField.text, "40")
    XCTAssertFalse(editor.hasChanges, "opening it changes nothing")
    editor.draft.draft.note = "кофе с собой"
    XCTAssertEqual(editor.draft.draft.cashback, rub(40))
    // «По правилам»: the field emptied, the rules speak again.
    editor.draft.cashbackField.text = ""
    XCTAssertNil(editor.draft.draft.cashback)
    XCTAssertNotEqual(editor.draft.cashbackExpectation?.source, .override)

    // The next line starts with an empty field.
    model.reset()
    XCTAssertEqual(model.cashbackField, CashbackFieldState())
    XCTAssertNil(model.draft.cashback)
  }

  /// «7%» on «аптека 1000 black» in «Аптеки» is saved as 70.00 ₽; the percent follows the amount
  /// until the save.
  func testATypedPercentIsSavedAsAnAmount() throws {
    let model = book.model()
    try book.enter("аптека 500 black", into: model)
    model.setCategory(book.health.id, forPartAt: 0)
    model.setSubcategory(book.pharmacies.id, forPartAt: 0)
    model.cashbackField.text = "7%"
    XCTAssertEqual(model.draft.cashback, rub(35))
    model.setTotal(AmountE4(whole: 1_000))
    XCTAssertEqual(model.draft.cashback, rub(70))
    let saved = try book.save(model)
    XCTAssertEqual(try book.stored(saved.id)?.transaction.cashback, rub(70))
  }

  /// In the editor of a saved split, «7%» typed and then the first part removed: the field still
  /// says «7%», and the percent keeps following the amount.
  func testRemovingTheFirstPartKeepsTheTypedPercent() throws {
    let model = book.model()
    try book.enter("покупки 1000 black", into: model)
    model.addPart()
    model.draft.parts[0].amount = AmountE4(whole: 600)
    model.draft.parts[0].categoryId = book.pharmacies.id
    model.draft.parts[1].amount = AmountE4(whole: 400)
    model.draft.parts[1].categoryId = book.clothes.id
    let saved = try book.save(model)

    let stored = try XCTUnwrap(try book.stored(saved.id))
    XCTAssertEqual(stored.parts.count, 2)
    let editor = TransactionEditorModel(entry: stored, environment: book.environment)
    editor.draft.cashbackField.text = "7%"
    XCTAssertEqual(editor.draft.draft.cashback, rub(70))
    let first = try XCTUnwrap(editor.draft.draft.parts.first?.id)
    XCTAssertTrue(editor.draft.canRemovePart(id: first))
    editor.draft.removePart(id: first)
    XCTAssertEqual(editor.draft.draft.parts.count, 1)
    XCTAssertEqual(editor.draft.cashbackField.text, "7%")
    editor.draft.setTotal(AmountE4(whole: 2_000))
    XCTAssertEqual(editor.draft.draft.cashback, rub(140), "the percent follows the amount")
  }

  /// «Запомнить» → «Только в этом месяце»: the rule of Black is written at once as a step of ⌘Z
  /// of its own, the field empties, and the rule prices the operation; ⌘Z takes the rule back.
  func testRememberWritesARuleAsItsOwnStep() throws {
    let model = book.model()
    try book.enter("аптека 1000 black", into: model)
    model.setCategory(book.health.id, forPartAt: 0)
    model.setSubcategory(book.pharmacies.id, forPartAt: 0)
    model.cashbackField.text = "7%"
    let context = model.cashbackContext
    XCTAssertNil(context.rememberRefusalKey)
    let seven = try XCTUnwrap(CashbackPercent(e4: 70_000))
    let rule = try XCTUnwrap(context.rule(seven, onlyThisMonth: true))
    XCTAssertEqual(rule.cardId, book.black.id)
    XCTAssertEqual(rule.accountId, book.tBank.id)
    XCTAssertEqual(rule.categoryId, book.pharmacies.id)

    let actions = CardActions(environment: book.environment, store: book.store)
    XCTAssertFalse(book.store.canUndo)
    XCTAssertEqual(model.rememberCashback(rule) { actions.remember($0) }, .done)
    XCTAssertEqual(model.cashbackField.text, "", "the rule says it now")
    XCTAssertNil(model.draft.cashback)
    XCTAssertEqual(model.cashbackExpectation?.money, rub(70))
    XCTAssertTrue(actions.rules.contains { $0.categoryId == book.pharmacies.id })
    XCTAssertTrue(try book.entries().isEmpty, "nothing but the rule was written")

    book.store.undo()
    XCTAssertFalse(actions.rules.contains { $0.categoryId == book.pharmacies.id })
    XCTAssertFalse(book.store.canUndo, "one step")
  }

  /// A split over two categories cannot mean a rule of one: «Запомнить» is off and says why;
  /// so is a part with no category.
  func testRememberIsOffForMixedCategories() throws {
    let model = book.model()
    try book.enter("покупки 1000 black", into: model)
    model.addPart()
    model.draft.parts[0].amount = AmountE4(whole: 600)
    model.draft.parts[0].categoryId = book.pharmacies.id
    model.draft.parts[1].amount = AmountE4(whole: 400)
    model.draft.parts[1].categoryId = book.clothes.id
    model.cashbackField.text = "5%"
    XCTAssertTrue(model.cashbackContext.mixedCategories)
    XCTAssertEqual(model.cashbackContext.rememberRefusalKey, "entry.cashback.rememberSplit")
    // The expectation of the split: 1 % of either part — everything else of Black.
    model.cashbackField.text = ""
    XCTAssertEqual(model.cashbackExpectation?.money, rub(10))

    let alone = book.model()
    try book.enter("покупки 1000 black", into: alone)
    alone.cashbackField.text = "5%"
    XCTAssertEqual(alone.cashbackContext.rememberRefusalKey, "entry.cashback.rememberNoCategory")
  }

  /// «abc» does not read: it is said, and the operation is saved all the same, without a figure.
  func testAnUnreadableFieldDoesNotBlockTheSave() throws {
    let model = book.model()
    try book.enter("кофе 350 black", into: model)
    model.cashbackField.text = "abc"
    XCTAssertEqual(model.cashbackField.input, .unreadable(.malformed))
    XCTAssertNil(model.draft.cashback)
    XCTAssertNil(model.saveRefusalKey)
    let saved = try book.save(model)
    XCTAssertNil(try book.stored(saved.id)?.transaction.cashback)
  }

  /// A purchase on credit and a money back have no «Кэшбэк»: the lender paid, and a person
  /// gave the money.
  func testNoCashbackOnCreditOrForMoneyBack() throws {
    let model = book.model()
    try book.enter("телефон 60000 black", into: model)
    model.cashbackField.text = "40"
    model.startCreditPlan()
    XCTAssertFalse(model.showsCashback)
    XCTAssertNil(model.draft.cashback)
    model.stopCreditPlan()
    XCTAssertEqual(model.draft.cashback, rub(40))

    let back = book.model()
    back.draft.kind = .reimbursement
    back.applyDefaults(today: book.today)
    XCTAssertFalse(back.showsCashback)
  }

  /// In the window: the panel shows «Кэшбэк» with what the rules of the main account's only card
  /// expect as its placeholder.
  func testThePanelShowsTheCashbackRow() async throws {
    let book = try XCTUnwrap(self.book)
    let host = try await EntryHost(prepare: { environment in
      let references = try XCTUnwrap(environment.references)
      for account in [book.sber, book.tBank, book.cash] { try references.save(account) }
      _ = try XCTUnwrap(environment.planning).apply(
        PlanningChange(
          upsert: PlanningRows(
            cards: [book.sberCard, book.black, book.virtual],
            cashbackRules: [
              CashbackRule(
                accountId: book.sber.id, cardId: book.sberCard.id,
                percent: CashbackPercent(e4: 5_000)!)
            ])))
    })
    self.host = host
    try host.type("350", into: try host.field(prompt: "0"))
    host.settle()
    // «Сбер» is the main account with one card: its 0.5 % of 350 ₽.
    XCTAssertNoThrow(try host.field(prompt: "≈ 1.75"), "the placeholder says the expectation")
  }
}
