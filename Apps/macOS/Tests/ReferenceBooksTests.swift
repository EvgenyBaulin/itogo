import AppCore
import AppDatabase
import XCTest

@testable import Itogo

/// Settings → Справочники: people, places, payment methods and events — the dictionaries the
/// entry line matches names against — against a real database.
@MainActor
final class ReferenceBooksTests: XCTestCase {
  private var environment: AppEnvironment!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["ITOGO_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("itogo-references-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("ITOGO_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
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

  private var references: ReferenceRepository { environment.references! }

  private func storedDefaults() throws -> [UUID] {
    try references.paymentMethods().filter(\.isDefault).map(\.id)
  }

  /// The default switch belongs to the form it is in, saved with «Сохранить» like the rest of
  /// it. Until 24.09 switching it on wrote the other methods off at once and the chosen one
  /// only on «Сохранить»: an owner who left the tab in between had no default method at all.
  func testChoosingTheDefaultWritesNothingUntilItIsSaved() throws {
    for method in try references.paymentMethods() where method.isDefault {
      var method = method
      method.isDefault = false
      try references.save(method)
    }
    let card = PaymentMethod(name: "Card", isDefault: true)
    let cash = PaymentMethod(name: "Cash", kind: .cash)
    try references.save(card)
    try references.save(cash)

    var shown = try references.paymentMethods()
    let index = try XCTUnwrap(shown.firstIndex { $0.id == cash.id })
    ReferenceBooksView.chooseDefault(at: index, isOn: true, in: &shown)

    XCTAssertEqual(shown.filter(\.isDefault).map(\.id), [cash.id], "the screen shows one default")
    XCTAssertEqual(try storedDefaults(), [card.id], "something was written before «Сохранить»")

    try ReferenceBooksView.save(shown[index], references: references)
    XCTAssertEqual(try storedDefaults(), [cash.id], "the saved default is not the only one")
  }

  /// A method saved without the switch leaves the default where it is.
  func testSavingAnotherMethodLeavesTheDefaultAlone() throws {
    let card = PaymentMethod(name: "Card", isDefault: true)
    var cash = PaymentMethod(name: "Cash", kind: .cash)
    try references.save(card)
    try references.save(cash)
    let before = try storedDefaults()

    cash.name = "Cash in the wallet"
    try ReferenceBooksView.save(cash, references: references)
    XCTAssertEqual(try storedDefaults(), before)
  }

  /// «Объединить с…» moves operations and cannot be taken back: the row's menu asks first,
  /// naming both rows, what happens to them, and that it cannot be undone — in either language.
  func testAMergeIsAskedFirstWithBothNames() {
    let question = ReferenceBooksView.MergeQuestion(
      book: .places, source: UUID(), sourceName: "Пятёрочка у дома", target: UUID(),
      targetName: "Пятёрочка")
    let event = ReferenceBooksView.MergeQuestion(
      book: .events, source: UUID(), sourceName: "Отпуск 2025", target: UUID(),
      targetName: "Отпуск")
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for asked in [question, event] {
        let title = asked.title(environment)
        let message = asked.message(environment)
        XCTAssertTrue(
          title.contains(asked.sourceName) && title.contains(asked.targetName), "\(title)")
        XCTAssertTrue(message.contains(asked.sourceName), "\(message)")
        for text in [title, message, asked.confirm(environment)] {
          XCTAssertFalse(text.contains("references."), "a key instead of words: \(text)")
        }
      }
      XCTAssertNotEqual(
        question.message(environment), event.message(environment),
        "an event has no aliases to take the old name")
    }
    environment.language.choice = .russian
  }

  /// And answered, it merges: the operations and the name go to the row that stays.
  func testAnAnsweredMergeMovesTheRowIntoTheOther() throws {
    let shop = Place(name: "Пятёрочка")
    let duplicate = Place(name: "Пятёрочка у дома")
    try references.save(shop)
    try references.save(duplicate)

    try ReferenceBooksView.MergeQuestion(
      book: .places, source: duplicate.id, sourceName: duplicate.name, target: shop.id,
      targetName: shop.name
    ).merge(references)

    let places = try references.places()
    XCTAssertFalse(places.contains { $0.id == duplicate.id }, "the merged row is still live")
    XCTAssertEqual(places.first { $0.id == shop.id }?.aliases, ["Пятёрочка у дома"])
  }

  /// «Имя, уже занятое, не добавляется: два человека с одним именем — две строки,
  /// которые строка ввода не различит». The General tab refused such a name; the reference
  /// books, the main door to the same list, added it.
  func testANameTheEntryLineAlreadyAnswersToIsNotAddedAgain() {
    let anya = Person(name: "Аня", aliases: ["Анечка"])
    let alena = Person(name: "Алена")
    let shop = Place(name: "Пятёрочка", aliases: ["пятерка"])
    let card = PaymentMethod(name: "Тинькофф", aliases: ["тинек"])
    func canAdd(_ name: String, to book: ReferenceBooksView.Book) -> Bool {
      ReferenceBooksView.canAdd(
        name, to: book, people: [anya, alena], places: [shop], methods: [card])
    }

    XCTAssertFalse(canAdd("аня", to: .people), "a second «Аня» was added")
    XCTAssertFalse(canAdd("  Анечка ", to: .people), "a name already an alias was added")
    XCTAssertFalse(canAdd("Алёна", to: .people), "«ё» and «е» are one letter to the entry line")
    XCTAssertFalse(canAdd("пятерочка", to: .places))
    XCTAssertFalse(canAdd("Пятерка", to: .places), "an alias of a place")
    XCTAssertFalse(canAdd("ТИНЕК", to: .paymentMethods), "an alias of a payment method")

    XCTAssertTrue(canAdd("Оля", to: .people))
    XCTAssertTrue(canAdd("Аня", to: .places), "the books are apart: a place may share a name")
    XCTAssertFalse(canAdd("   ", to: .people), "an empty name")
    // A yearly event is made again under the same name each year (`rolloverYearlyEvents`),
    // so a name shared by events is the rule there, not a mistake.
    XCTAssertTrue(canAdd("Отпуск", to: .events))
  }

  /// The General tab adds people too, and says «taken» by the same rule, aliases included.
  func testTheGeneralTabAndTheBooksShareOneRule() {
    let anya = Person(name: "Аня", aliases: ["Анечка"])
    XCTAssertTrue(ReferenceNames.isTaken("анечка", among: [anya].map(ReferenceNames.spellings)))
    XCTAssertFalse(ReferenceNames.isTaken("Оля", among: [anya].map(ReferenceNames.spellings)))
    // What «Добавить» of the General tab writes goes by that rule too (merged with the return
    // of an archived person).
    XCTAssertNil(GeneralSettingsView.person(toAdd: "анечка", among: [anya]))
    XCTAssertNil(GeneralSettingsView.person(toAdd: "АНЯ", among: [anya]))
    XCTAssertNotNil(GeneralSettingsView.person(toAdd: "Оля", among: [anya]))
  }
}
