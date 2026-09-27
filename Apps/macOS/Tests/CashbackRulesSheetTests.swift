import AppCore
import XCTest

@testable import Itogo

/// The rules sheet at the level of its draft: the rows of each card, «always» and one month,
/// «Как в прошлом месяце», what keeps «Сохранить» off, and the rules it saves.
@MainActor
final class CashbackRulesSheetTests: XCTestCase {
  private let account = UUID()
  private let black = UUID()
  private let virtual = UUID()
  private let cafes = UUID()
  private let groceries = UUID()
  private let september = MonthKey(year: 2026, month: 9)
  private var august: MonthKey { september.previous }

  private func rule(
    _ card: UUID, _ category: UUID?, _ month: MonthKey?, _ e4: Int64
  ) -> CashbackRule {
    CashbackRule(
      accountId: account, cardId: card, categoryId: category, month: month,
      percent: CashbackPercent(e4: e4)!)
  }

  private var rules: [CashbackRule] {
    [
      rule(black, cafes, nil, 50_000), rule(black, nil, nil, 10_000),
      rule(black, cafes, september, 100_000), rule(black, groceries, august, 30_000),
      rule(virtual, nil, nil, 15_000),
    ]
  }

  private func draft(holder: CashbackHolder? = nil) -> CashbackRulesDraft {
    CashbackRulesDraft(
      holders: [.card(black), .card(virtual)], accountId: account, holder: holder,
      rules: rules, month: september)
  }

  func testTheRowsOfEachCard() {
    let sheet = draft()
    XCTAssertEqual(sheet.holder, .card(black))
    XCTAssertEqual(sheet.always.map(\.percentText), ["5", "1"])
    XCTAssertEqual(sheet.ofMonth.map(\.percentText), ["10"])
    XCTAssertEqual(sheet.otherMonths.map(\.month), [august])
    XCTAssertEqual(draft(holder: .card(virtual)).always.map(\.percentText), ["1.5"])
  }

  func testCopyLastMonthAddsTheCategoriesThisMonthHasNot() {
    var sheet = draft()
    XCTAssertTrue(sheet.hasLastMonth)
    sheet.copyLastMonth()
    XCTAssertEqual(Set(sheet.ofMonth.map(\.categoryId)), [cafes, groceries])
    XCTAssertEqual(sheet.ofMonth.first { $0.categoryId == groceries }?.percentText, "3")
  }

  func testAnUnreadablePercentOrARepeatedCategoryKeepsSaveOff() throws {
    var sheet = draft()
    XCTAssertNotNil(sheet.rules)
    sheet.add(month: nil)
    XCTAssertNil(sheet.rules, "an empty percent does not read")
    var added = try XCTUnwrap(sheet.always.last)
    added.percentText = "150"
    sheet.update(added)
    XCTAssertNil(sheet.rules)
    added.percentText = "7,5"
    sheet.update(added)
    XCTAssertNil(sheet.rules, "«everything else, always» is there already")
    XCTAssertTrue(sheet.isDuplicate(try XCTUnwrap(sheet.always.last)))
    added.categoryId = groceries
    sheet.update(added)
    let saved = try XCTUnwrap(sheet.rules)
    XCTAssertEqual(
      saved.first { $0.id == added.id }?.percent, CashbackPercent(e4: 75_000),
      "a comma is the decimal one")
    XCTAssertEqual(saved.count, rules.count + 1)
  }

  func testRemovedRowsAreLeftOutAndEveryHolderIsSaved() throws {
    var sheet = draft()
    let removed = try XCTUnwrap(sheet.always.first)
    sheet.remove(removed.id)
    let saved = try XCTUnwrap(sheet.rules)
    XCTAssertFalse(saved.contains { $0.id == removed.id })
    XCTAssertTrue(saved.contains { $0.cardId == virtual }, "the other card's rules stay")
    XCTAssertTrue(saved.allSatisfy { $0.accountId == account })
  }

  /// A row of the card not shown keeps «Сохранить» off: the sheet names that card under the
  /// form, since the row's own words are drawn only with the card's rows. A row of another month
  /// of the card shown is said the same way.
  func testAProblemOutOfSightIsNamed() throws {
    var sheet = draft()
    XCTAssertTrue(sheet.holdersWithProblems.isEmpty)
    sheet.add(month: nil)
    XCTAssertEqual(sheet.holdersWithProblems, [.card(black)])
    XCTAssertTrue(sheet.problemsOutOfSight.isEmpty, "the row is on screen with its words")
    sheet.holder = .card(virtual)
    XCTAssertNil(sheet.rules)
    XCTAssertEqual(sheet.problemsOutOfSight, [.card(black)])

    var months = draft(holder: .card(virtual))
    months.add(month: september)
    XCTAssertTrue(months.problemsOutOfSight.isEmpty)
    months.month = august
    XCTAssertEqual(months.problemsOutOfSight, [.card(virtual)], "now under «Другие месяцы»")
  }

  func testTheMonthsOffered() {
    let months = draft().months(around: september)
    XCTAssertEqual(months.first, september.next.next)
    XCTAssertTrue(months.contains(august))
    XCTAssertEqual(months.count, 15)
  }
}
