import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import Itogo

/// The kinds of the form at the side of the window, in a window: all five always in sight, two to
/// a row, the one used most across the first row; a tile switches the fields to its kind, and
/// «Перевод» opens the transfer sheet.
@MainActor
final class EntryKindTilesFormTests: XCTestCase {
  private var host: EntryHost?
  private let wages = CoreKit.Category(kind: .income, name: "Wages", quality: .neutral)

  override func tearDown() async throws {
    if let sheet = host?.window.attachedSheet { host?.window.endSheet(sheet) }
    host?.close()
    host = nil
  }

  private static let identifiers = [
    "entry.kind.expense", "entry.kind.income", "entry.kind.reimbursement", "entry.kind.refund",
    "entry.kind.transfer",
  ]

  private func tiles(of host: EntryHost) throws -> [String: CGRect] {
    var frames: [String: CGRect] = [:]
    for identifier in Self.identifiers {
      let tile = try XCTUnwrap(
        WindowAccessibility.element(identified: identifier, in: host.window),
        "«\(identifier)» is not in sight")
      frames[identifier] = WindowAccessibility.frame(of: tile)
    }
    return frames
  }

  /// `incomes` incomes and one expense in the book before the form appears.
  private func openForm(incomes: Int) async throws -> EntryHost {
    let wages = wages
    let host = try await EntryHost(opensDetails: false, style: .form) { environment in
      try environment.references!.save(wages)
      for index in 0...incomes {
        var draft = TransactionDraft(
          kind: index == 0 ? .expense : .income, amount: AmountE4(whole: 100))
        draft.normalizeSinglePart()
        try environment.transactions!.save(try draft.materialize())
      }
    }
    self.host = host
    return host
  }

  func testTheFiveTilesStandTwoToARowAndTheMostUsedStretches() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm(incomes: 0)
    let frames = try tiles(of: host)
    let expense = try XCTUnwrap(frames["entry.kind.expense"])
    let income = try XCTUnwrap(frames["entry.kind.income"])
    let refund = try XCTUnwrap(frames["entry.kind.refund"])
    let transfer = try XCTUnwrap(frames["entry.kind.transfer"])
    XCTAssertGreaterThan(expense.width, income.width * 1.6, "the expense stretches")
    XCTAssertGreaterThan(expense.midY, income.midY + 1, "alone in the first row")
    XCTAssertEqual(income.width, transfer.width, accuracy: 2, "the others go in pairs")
    XCTAssertEqual(refund.midY, transfer.midY, accuracy: 2, "the last pair shares a row")
  }

  func testTheKindUsedMostIsTheOneThatStretches() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm(incomes: 3)
    let frames = try tiles(of: host)
    let expense = try XCTUnwrap(frames["entry.kind.expense"])
    let income = try XCTUnwrap(frames["entry.kind.income"])
    XCTAssertGreaterThan(income.width, expense.width * 1.6, "the income stretches")
  }

  /// «Доход» makes the fields the fields of an income: its categories are offered, and what is
  /// saved is an income.
  func testATileSwitchesTheFieldsToItsKind() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm(incomes: 0)
    let income = try XCTUnwrap(
      WindowAccessibility.element(identified: "entry.kind.income", in: host.window))
    WindowAccessibility.press(income)
    host.settle()
    try host.type("500", into: try host.field(prompt: "0"))
    try WindowAccessibility.choose("Wages", inMenu: "entry.category", of: host.window)
    let save = try XCTUnwrap(
      WindowAccessibility.element(identified: "entry.form.save", in: host.window))
    WindowAccessibility.press(save)
    host.settle()
    let saved = try XCTUnwrap(
      try host.transactions.recentEntries(limit: 10).first {
        $0.transaction.amountE4 == AmountE4(whole: 500)
      }, "the income was not saved")
    XCTAssertEqual(saved.transaction.kind, .income)
    XCTAssertEqual(saved.parts.first?.categoryId, wages.id)
  }

  func testTheTransferTileOpensTheTransferSheet() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await openForm(incomes: 0)
    let transfer = try XCTUnwrap(
      WindowAccessibility.element(identified: "entry.kind.transfer", in: host.window))
    WindowAccessibility.press(transfer)
    let deadline = Date().addingTimeInterval(3)
    while host.window.attachedSheet == nil, Date() < deadline { host.settle(0.05) }
    XCTAssertNotNil(host.window.attachedSheet, "the transfer sheet was not shown")
    XCTAssertEqual(try host.transactions.count(), 1, "only the expense of the book")
  }
}
