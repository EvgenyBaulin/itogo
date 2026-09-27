import AppCore
import AppDatabase
import XCTest

@testable import Itogo

/// When the line alone does not tell the category — or the model filed it under a category with
/// subcategories without saying which — Enter does not save the words into the note alone: it
/// opens the ↓ panel on the missing field, marked, once per line; the next Return saves.
@MainActor
final class EntryGapTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private let cafe = CoreKit.Category(kind: .expense, name: "Cafe", quality: .neutral)
  private let transport = CoreKit.Category(kind: .expense, name: "Transport", quality: .neutral)
  private lazy var taxi = CoreKit.Category(parentId: transport.id, kind: .expense, name: "Taxi")
  private lazy var bus = CoreKit.Category(parentId: transport.id, kind: .expense, name: "Bus")
  private var today: DateOnly { DateOnly(year: 2026, month: 9, day: 18) }
  private var host: EntryHost?

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    for category in [cafe, transport, taxi, bus] { try references.save(category) }
    try references.save(PaymentMethod(name: "Card", isDefault: true))
  }

  override func tearDown() async throws {
    host?.close()
    host = nil
  }

  private func makeModel(editing: Bool = false) -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc,
      editsSavedOperation: editing)
    model.reload()
    return model
  }

  private func parse(_ text: String) -> ParsedInput {
    InputLineParser(vocabulary: .empty, calendar: .utc).parse(text, today: today)
  }

  private func enter(_ text: String, into model: EntryDraftModel) throws {
    let parsed = parse(text)
    model.apply(parsed, amount: try AmountE4(decimal: try XCTUnwrap(parsed.amount)), today: today)
  }

  func testALineWithoutACategoryIsAskedOnce() throws {
    let model = makeModel()
    try enter("coffee 250", into: model)
    XCTAssertEqual(model.gapToAsk(), .category)
    XCTAssertEqual(model.markedGap, .category)
    // Enter on the same line goes on: the operation may stay uncategorised.
    try enter("coffee 250", into: model)
    XCTAssertNil(model.gapToAsk())
  }

  func testAnotherLineIsAskedAgain() throws {
    let model = makeModel()
    try enter("coffee 250", into: model)
    XCTAssertEqual(model.gapToAsk(), .category)
    try enter("tea 150", into: model)
    XCTAssertEqual(model.gapToAsk(), .category)
  }

  /// The stop is remembered by the text of the line: once a name in it is made known, the same
  /// text parses anew, and it is still the line the stop was for.
  func testTheStopIsRememberedByTheTextOfTheLine() throws {
    let text = "coffee 300 at Nowhere"
    let model = makeModel()
    let before = parse(text)
    model.apply(before, amount: AmountE4(whole: 300), today: today, text: text)
    XCTAssertEqual(model.gapToAsk(), .category)

    let nowhere = Place(name: "Nowhere")
    try references.save(nowhere)
    let after = InputLineParser(
      vocabulary: ParserVocabulary(places: [.init(id: nowhere.id, name: "Nowhere", aliases: [])]),
      calendar: .utc
    ).parse(text, today: today)
    XCTAssertNotEqual(after, before, "the place is known now")
    model.apply(after, amount: AmountE4(whole: 300), today: today, text: text)
    XCTAssertNil(model.gapToAsk())
    XCTAssertEqual(model.draft.placeId, nowhere.id)
  }

  /// ↓ and ↑ while the stop stands walk the menu it asked for, «—» first, as choices made in the
  /// menu; with no stop for the line they are not the menu's.
  func testTheArrowsWalkTheAskedMenuWhileTheStopStands() throws {
    let model = makeModel()
    try enter("coffee 250", into: model)
    XCTAssertFalse(model.stepTheAskedMenu(by: 1, today: today), "no stop yet")
    XCTAssertEqual(model.gapToAsk(), .category)
    let options = model.categoryOptions(forPartAt: 0).map(\.id)
    XCTAssertGreaterThanOrEqual(options.count, 2)

    XCTAssertTrue(model.stepTheAskedMenu(by: 1, today: today))
    XCTAssertEqual(model.draft.parts[0].categoryId, options[0])
    XCTAssertEqual(model.draft.parts[0].categorySource, .manual)
    XCTAssertTrue(model.stepTheAskedMenu(by: 1, today: today))
    XCTAssertEqual(model.draft.parts[0].categoryId, options[1])
    XCTAssertTrue(model.stepTheAskedMenu(by: -2, today: today))
    XCTAssertNil(model.draft.parts[0].categoryId, "«—» is the first choice")
    XCTAssertTrue(model.stepTheAskedMenu(by: -1, today: today), "nothing above «—»")
    XCTAssertNil(model.draft.parts[0].categoryId)

    try enter("tea 150", into: model)
    XCTAssertFalse(model.stepTheAskedMenu(by: 1, today: today), "no stop for this line")
  }

  func testAChosenCategoryIsNotAsked() throws {
    let model = makeModel()
    try enter("coffee 250", into: model)
    model.setCategory(cafe.id, forPartAt: 0)
    XCTAssertNil(model.gapToAsk())
  }

  func testHistoryDeterminesTheCategory() throws {
    var earlier = TransactionDraft(amount: AmountE4(whole: 200), note: "coffee")
    earlier.normalizeSinglePart()
    earlier.parts[0].categoryId = cafe.id
    try transactions.save(try earlier.materialize())
    let model = makeModel()
    try enter("coffee 250", into: model)
    XCTAssertEqual(model.draft.parts[0].categoryId, cafe.id)
    XCTAssertNil(model.gapToAsk())
  }

  /// The model is sure of «Transport», which has «Taxi» and «Bus»: the subcategory is asked, and
  /// Return without choosing saves the operation in «Transport».
  func testASubcategoryTheModelLeftOpenIsAsked() throws {
    var examples: [CategoryExample] = []
    for (index, word) in ["ride", "pizza", "bread", "cinema", "books", "gym"].enumerated() {
      let category: CoreKit.Category
      if index == 0 {
        category = transport
      } else {
        category = CoreKit.Category(kind: .expense, name: "Model \(word)")
        try references.save(category)
      }
      for _ in 0..<10 {
        examples.append(
          CategoryExample(
            query: CategoryQuery(
              day: today, weekday: CalendarContext.utc.weekdayIndex(today), kind: .expense,
              text: word, amountWhole: 250),
            partId: UUID(), categoryId: category.id))
      }
    }
    let box = CategoryModelBox()
    box.hold(CategoryModel.train(on: examples, anchor: today), trainedOn: examples)
    let model = makeModel()
    model.predictor = box
    try enter("ride 400", into: model)
    XCTAssertEqual(model.draft.parts[0].categoryId, transport.id)
    XCTAssertEqual(model.draft.parts[0].categorySource, .model)
    XCTAssertEqual(model.gapToAsk(), .subcategory)
    XCTAssertEqual(model.markedGap, .subcategory)
    XCTAssertNil(model.gapToAsk(), "Return again saves it in «Transport»")
  }

  func testTheMarkGoesOnceTheGapIsFilled() throws {
    let model = makeModel()
    try enter("coffee 250", into: model)
    XCTAssertEqual(model.gapToAsk(), .category)
    model.setCategory(cafe.id, forPartAt: 0)
    XCTAssertNil(model.markedGap)
  }

  func testASavedOperationIsNeverAsked() throws {
    var saved = TransactionDraft(amount: AmountE4(whole: 250), note: "coffee")
    saved.normalizeSinglePart()
    let entry = try saved.materialize()
    try transactions.save(entry)
    let model = makeModel(editing: true)
    model.draft = TransactionDraft(entry: entry)
    XCTAssertNil(model.gapToAsk())
  }

  /// Money back the confirmation recorded as income is not stopped for a category: the owner
  /// has just confirmed a form. The money-back line itself has no category to ask for.
  func testMoneyBackRecordedAsIncomeIsNotStoppedForACategory() throws {
    let model = makeModel()
    try enter("возврат денег 500", into: model)
    XCTAssertEqual(model.draft.kind, .reimbursement)
    XCTAssertNil(model.gapToAsk(), "money back has no category to ask for")
    var sheet = model.draftForSaving
    sheet.amount = AmountE4(whole: 500)
    model.recordMoneyBackInstead(.income, from: sheet, fromNote: { $0 }, today: today)
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertNil(model.draft.parts.first?.categoryId)
    XCTAssertNil(model.gapToAsk(), "the income the confirmation made is saved as it is")
  }

  /// In the window: Enter on a line of new words saves nothing, opens the panel and says why;
  /// the next Return saves the operation uncategorised, its words in the note.
  func testEnterOpensThePanelOnTheCategoryAndTheNextReturnSaves() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    let editor = try host.type("coffee 250", into: try host.line())
    editor.insertNewline(nil)
    host.settle()
    XCTAssertEqual(try host.transactions.count(), 0, "nothing saved at the first Enter")
    XCTAssertNotNil(
      host.textFields().first { $0.placeholderString == "0" }, "the panel is open")

    host.settle(0.3)
    let line = try host.line()
    XCTAssertTrue(host.window.makeFirstResponder(line))
    let again = try XCTUnwrap(host.window.firstResponder as? NSTextView)
    again.insertNewline(nil)
    host.settle()
    let saved = try XCTUnwrap(try host.transactions.recentEntries(limit: 5).first)
    XCTAssertNil(saved.parts.first?.categoryId)
    XCTAssertEqual(saved.transaction.note, "coffee")
  }

  /// The stop opened the panel on the category; the owner corrects the amount there too, and
  /// Return in the field saves the amount the panel shows, not the one the line still says.
  func testAnAmountCorrectedInThePanelAfterTheStopIsSaved() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    let editor = try host.type("coffee 250", into: try host.line())
    editor.insertNewline(nil)
    host.settle()
    XCTAssertEqual(try host.transactions.count(), 0, "the first Enter stops for the category")

    host.settle(0.3)
    // The field selects what it holds as it takes the focus: typing replaces «250».
    let amount = try host.type("260", into: try host.field(prompt: "0"))
    amount.insertNewline(nil)
    host.settle()
    let saved = try host.transactions.recentEntries(limit: 5)
    XCTAssertEqual(saved.count, 1, "Return in the panel saves")
    XCTAssertEqual(saved.first?.transaction.amountE4, AmountE4(whole: 260))
    XCTAssertEqual(saved.first?.transaction.note, "coffee")
  }

  /// Where macOS keeps Tab away from menus, the focus stays in the line after the stop: ↓ there
  /// chooses the first category of the menu, and Return saves the operation in it.
  func testTheCategoryCanBeChosenFromTheKeyboardAfterTheStop() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    let first = try XCTUnwrap(
      try host.references.categories().first { $0.parentId == nil && $0.kind == .expense },
      "the first category of the menu")
    let editor = try host.type("coffee 250", into: try host.line())
    editor.insertNewline(nil)
    host.settle()
    XCTAssertEqual(try host.transactions.count(), 0, "the first Enter stops for the category")

    host.settle(0.3)
    XCTAssertTrue(host.window.makeFirstResponder(try host.line()))
    // ↓ as the window hands a key press to the line: the line's own handler of keys is reached
    // this way, not through its editor.
    let arrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
    host.window.sendEvent(
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad], timestamp: 0,
        windowNumber: host.window.windowNumber, context: nil, characters: arrow,
        charactersIgnoringModifiers: arrow, isARepeat: false, keyCode: 125)!)
    host.settle()
    XCTAssertTrue(
      ((host.window.firstResponder as? NSTextView)?.delegate as? NSTextField)
        === (try host.line()), "the focus stays in the line")
    try XCTUnwrap(host.window.firstResponder as? NSTextView).insertNewline(nil)
    host.settle()
    let saved = try XCTUnwrap(try host.transactions.recentEntries(limit: 5).first)
    XCTAssertEqual(saved.parts.first?.categoryId, first.id, "saved in «\(first.name)»")
  }

  /// A place the line names that nobody has made yet is made with «Добавить…» after the stop:
  /// the same line now reads with the place, and is still the line the stop was for — Return
  /// saves it instead of asking again.
  func testAddingThePlaceOfTheLineDoesNotAskAgain() async throws {
    let host = try await EntryHost(opensDetails: false)
    self.host = host
    let editor = try host.type("coffee 300 at Nowhere", into: try host.line())
    editor.insertNewline(nil)
    host.settle()
    XCTAssertEqual(try host.transactions.count(), 0, "the first Enter stops for the category")

    // What «Добавить…» of the menu of places does: the place is written, the line learns it.
    let nowhere = Place(name: "Nowhere")
    try host.references.save(nowhere)
    host.environment.refreshVocabulary()
    host.settle(0.3)
    XCTAssertTrue(host.window.makeFirstResponder(try host.line()))
    try XCTUnwrap(host.window.firstResponder as? NSTextView).insertNewline(nil)
    host.settle()
    let saved = try host.transactions.recentEntries(limit: 5)
    XCTAssertEqual(saved.count, 1, "the second Return saves")
    XCTAssertEqual(saved.first?.transaction.placeId, nowhere.id)
  }
}
