import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import Itogo

/// «перевод 1000 наличные карта для поездок» in the entry line, end to end: the words over the
/// line before Return, the transfer written at once — no expense — and taken back by one ⌘Z;
/// the other way round with «на … с …»; the sheet, with nothing written, when an account is not
/// known or the money changes currency; «перевод маше 500» stays an operation.
@MainActor
final class TransferFromTheLineTests: XCTestCase {
  private var host: EntryHost?
  private var appGuide: GuideStore!
  private var suite = ""
  private var cash = PaymentMethod(name: "Наличные", currency: .rub, isDefault: true)
  private var travel = PaymentMethod(name: "Карта для поездок", currency: .rub)
  private var abroad = PaymentMethod(name: "Заграница", currency: .usd)
  private let masha = Person(name: "Маша")

  override func setUp() async throws {
    suite = "itogo.tests.transferLine.\(UUID().uuidString)"
    appGuide = GuideStore.shared
    GuideStore.shared = GuideStore(defaults: UserDefaults(suiteName: suite)!, tutorial: true)
  }

  override func tearDown() async throws {
    if let sheet = host?.window.attachedSheet { host?.window.endSheet(sheet) }
    host?.close()
    host = nil
    GuideStore.shared = appGuide
    UserDefaults().removePersistentDomain(forName: suite)
  }

  private func makeHost() async throws -> EntryHost {
    let accounts = [cash, travel, abroad]
    let person = masha
    let host = try await EntryHost(opensDetails: false) { environment in
      let references = try XCTUnwrap(environment.references)
      for account in accounts { try references.save(account) }
      try references.save(person)
      environment.refreshVocabulary()
    }
    self.host = host
    return host
  }

  private func transfers(_ host: EntryHost) async throws -> [Transfer] {
    let books = await TransferActions(environment: host.environment, store: host.store).books()
    return try XCTUnwrap(books).dataset.transfers
  }

  private func waitForSheet(_ host: EntryHost) -> NSWindow? {
    let deadline = Date().addingTimeInterval(3)
    while host.window.attachedSheet == nil, Date() < deadline { host.settle(0.05) }
    return host.window.attachedSheet
  }

  private func type(_ line: String, in host: EntryHost) throws {
    let editor = try host.type(line, into: try host.line())
    editor.insertNewline(nil)
    host.settle(1)
  }

  private func read(_ line: String, in host: EntryHost) -> ParsedInput {
    CoreLineInterpreter(
      vocabulary: host.environment.vocabulary, calendar: host.environment.calendar
    )
    .interpret(line, today: host.environment.today)
  }

  /// Before Return: «Перевод: Наличные → Карта для поездок, 1,000.00 ₽».
  func testTheLineSaysWhatItWillTransfer() async throws {
    let host = try await makeHost()
    let parsed = read("перевод 1000 наличные карта для поездок", in: host)
    let reading = try XCTUnwrap(parsed.transfer, "the line is no transfer")
    XCTAssertEqual(reading.fromAccountId, cash.id)
    XCTAssertEqual(reading.toAccountId, travel.id)
    let text = EntryBar<EmptyView>.transferPreview(
      reading, amount: AmountE4(whole: 1000), currency: .rub, accounts: [cash, travel, abroad],
      environment: host.environment)
    XCTAssertEqual(
      text,
      host.environment.language("entry.transfer.preview", table: "Entry")
        + " Наличные → Карта для поездок, "
        + host.environment.money.exact(AmountE4(whole: 1000), currency: .rub))
    XCTAssertEqual(GuideFlowTests.russian("entry.transfer.preview", table: "Entry"), "Перевод:")
  }

  /// Return writes the transfer at once, without a sheet and without an expense; the line is
  /// cleared; the tutorial hears of it; one ⌘Z takes it back.
  func testReturnWritesTheTransferAtOnceAndUndoTakesItBack() async throws {
    let host = try await makeHost()
    try type("перевод 1000 наличные карта для поездок", in: host)
    let deadline = Date().addingTimeInterval(3)
    var written: [Transfer] = []
    while written.isEmpty, Date() < deadline {
      host.settle(0.1)
      written = try await transfers(host)
    }
    XCTAssertEqual(written.count, 1)
    let transfer = try XCTUnwrap(written.first)
    XCTAssertEqual(transfer.fromAccountId, cash.id)
    XCTAssertEqual(transfer.toAccountId, travel.id)
    XCTAssertEqual(transfer.fromAmountE4, AmountE4(whole: 1000))
    XCTAssertEqual(transfer.toAmountE4, AmountE4(whole: 1000))
    XCTAssertEqual(try host.transactions.count(), 0, "a transfer is no expense")
    XCTAssertNil(host.window.attachedSheet, "nothing was left to ask")
    XCTAssertEqual(try host.line().stringValue, "", "the line was not cleared")
    XCTAssertTrue(GuideStore.shared.progress.events.contains(GuideEvent.transferFromLine))

    host.store.undo()
    host.settle()
    let after = try await transfers(host)
    XCTAssertTrue(after.isEmpty, "⌘Z left the transfer")
  }

  /// «на наличные с карты для поездок»: the money leaves the card for the cash.
  func testTheOtherWayRound() async throws {
    let host = try await makeHost()
    let line = "перевод 500 на наличные с карты для поездок"
    let reading = try XCTUnwrap(read(line, in: host).transfer)
    XCTAssertEqual(reading.fromAccountId, travel.id)
    XCTAssertEqual(reading.toAccountId, cash.id)

    try type("перевод 500 на наличные с карты для поездок", in: host)
    let deadline = Date().addingTimeInterval(3)
    var written: [Transfer] = []
    while written.isEmpty, Date() < deadline {
      host.settle(0.1)
      written = try await transfers(host)
    }
    XCTAssertEqual(written.map(\.fromAccountId), [travel.id])
    XCTAssertEqual(written.map(\.toAccountId), [cash.id])
  }

  /// «перевод 300 наличные копилка»: no account is «копилка» — the sheet opens from «Наличные»
  /// with 300 and nothing on the other side, and nothing is written until the owner chooses.
  func testAnAccountNotKnownOpensTheSheetAndWritesNothing() async throws {
    let host = try await makeHost()
    let parsed = read("перевод 300 наличные копилка", in: host)
    let reading = try XCTUnwrap(parsed.transfer)
    var draft = TransactionDraft(amount: AmountE4(whole: 300))
    draft.normalizeSinglePart()
    let form = TransferForm(
      fromTheLine: reading, draft: draft, accounts: [cash, travel, abroad],
      calendar: host.environment.calendar)
    XCTAssertEqual(form.fromAccountId, cash.id)
    XCTAssertNil(form.toAccountId, "the main account is never put there by itself")
    XCTAssertEqual(form.sent, AmountE4(whole: 300))
    XCTAssertFalse(form.savesAtOnce(reading))

    try type("перевод 300 наличные копилка", in: host)
    let sheet = try XCTUnwrap(waitForSheet(host), "the sheet of the transfer did not open")
    host.settle(0.5)
    let written = try await transfers(host)
    XCTAssertTrue(written.isEmpty, "a transfer was written without a word")
    XCTAssertEqual(try host.transactions.count(), 0)

    // «Отменить» (Esc): the sheet goes, nothing is written, the line keeps what was typed.
    XCTAssertTrue(sheet.performKeyEquivalent(with: EntryHost.key("\u{1b}", code: 53)))
    let deadline = Date().addingTimeInterval(3)
    while host.window.attachedSheet != nil, Date() < deadline { host.settle(0.05) }
    XCTAssertNil(host.window.attachedSheet, "«Отменить» left the sheet")
    let after = try await transfers(host)
    XCTAssertTrue(after.isEmpty)
    XCTAssertEqual(try host.line().stringValue, "перевод 300 наличные копилка")
  }

  /// «перевод 9500 наличные заграница»: rubles to a dollar account — the sheet asks what came,
  /// nothing is written in silence.
  func testAnotherCurrencyOpensTheSheetAndWritesNothing() async throws {
    let host = try await makeHost()
    let reading = try XCTUnwrap(read("перевод 9500 наличные заграница", in: host).transfer)
    XCTAssertTrue(reading.isComplete)
    var draft = TransactionDraft(amount: AmountE4(whole: 9500))
    draft.normalizeSinglePart()
    let form = TransferForm(
      fromTheLine: reading, draft: draft, accounts: [cash, travel, abroad],
      calendar: host.environment.calendar)
    XCTAssertEqual(form.toAccountId, abroad.id)
    XCTAssertEqual(form.toCurrency, .usd)
    XCTAssertTrue(form.isExchange)
    XCTAssertFalse(form.savesAtOnce(reading), "an exchange asks what came")

    try type("перевод 9500 наличные заграница", in: host)
    XCTAssertNotNil(waitForSheet(host), "the sheet of the transfer did not open")
    host.settle(0.5)
    let written = try await transfers(host)
    XCTAssertTrue(written.isEmpty)
  }

  /// «перевод маше 500» is an expense, as it always was: no transfer, no sheet.
  func testAPersonIsNoTransfer() async throws {
    let host = try await makeHost()
    XCTAssertNil(read("перевод маше 500", in: host).transfer)
    try type("перевод маше 500", in: host)
    host.settle(0.5)
    XCTAssertNil(host.window.attachedSheet, "a transfer sheet opened for a person")
    let written = try await transfers(host)
    XCTAssertTrue(written.isEmpty)
  }
}
