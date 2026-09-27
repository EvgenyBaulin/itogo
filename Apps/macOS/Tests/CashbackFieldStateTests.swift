import AppCore
import XCTest

@testable import Itogo

/// The field «Кэшбэк» of the ↓ panel at the level of its state: what a typed amount or percent
/// saves, that an unreadable figure saves nothing and stops nothing, and what «Запомнить» may
/// write.
@MainActor
final class CashbackFieldStateTests: XCTestCase {
  private let account = UUID()
  private let black = UUID()
  private let pharmacy = UUID()
  private let september = MonthKey(year: 2026, month: 9)

  private func draft(amount: Int64 = 1_000) -> TransactionDraft {
    TransactionDraft(
      amount: AmountE4(whole: amount), paymentMethodId: account,
      parts: [PartDraft(categoryId: pharmacy, amount: AmountE4(whole: amount))], cardId: black)
  }

  private func context(
    holder: CashbackHolder? = nil, category: UUID? = nil, mixed: Bool = false,
    severalCards: Bool = false
  ) -> CashbackFieldContext {
    CashbackFieldContext(
      holder: holder ?? .card(black), holderName: "Black", severalCards: severalCards,
      month: september, categoryId: category ?? pharmacy, accountId: account,
      movedCurrency: .rub, mixedCategories: mixed)
  }

  func testATypedAmountIsSavedInTheMovedCurrency() {
    let state = CashbackFieldState(text: "40")
    XCTAssertEqual(
      state.value(on: draft()), Money(amount: AmountE4(whole: 40), currency: .rub))
    var dollars = draft(amount: 20)
    dollars.currency = .usd
    dollars.accountCurrency = .rub
    dollars.accountAmount = AmountE4(whole: 1_850)
    XCTAssertEqual(
      state.value(on: dollars), Money(amount: AmountE4(whole: 40), currency: .rub),
      "the figure is in the money the account moved")
  }

  /// «7%» on 1,000.00 ₽ saves 70.00 ₽ for this operation.
  func testATypedPercentIsSavedAsAnAmount() throws {
    let state = CashbackFieldState(text: "7%")
    XCTAssertEqual(state.value(on: draft()), Money(amount: AmountE4(whole: 70), currency: .rub))
    XCTAssertEqual(state.typedPercent, CashbackPercent(e4: 70_000))
  }

  func testAnUnreadableFieldSavesNothingAndAnEmptyOneToo() {
    for text in ["abc", "150%", "1.23456%", "-3", "", "  "] {
      XCTAssertNil(CashbackFieldState(text: text).value(on: draft()), text)
    }
    XCTAssertEqual(CashbackFieldState(text: "abc").input, .unreadable(.malformed))
  }

  func testRememberWritesAlwaysOrTheMonthOnTheCard() throws {
    let seven = try XCTUnwrap(CashbackPercent(e4: 70_000))
    let always = try XCTUnwrap(context().rule(seven, onlyThisMonth: false))
    XCTAssertEqual(always.cardId, black)
    XCTAssertEqual(always.accountId, account)
    XCTAssertEqual(always.categoryId, pharmacy)
    XCTAssertNil(always.month)
    XCTAssertEqual(try XCTUnwrap(context().rule(seven, onlyThisMonth: true)).month, september)
    let own = try XCTUnwrap(
      context(holder: .account(account)).rule(seven, onlyThisMonth: false))
    XCTAssertNil(own.cardId, "an account without cards holds its own rules")
  }

  func testRememberIsOffForMixedCategoriesNoCategoryOrNoCard() {
    let seven = CashbackPercent(e4: 70_000)!
    XCTAssertNil(context().rememberRefusalKey)
    XCTAssertEqual(context(mixed: true).rememberRefusalKey, "entry.cashback.rememberSplit")
    XCTAssertNil(context(mixed: true).rule(seven, onlyThisMonth: false))
    var noCategory = context()
    noCategory.categoryId = nil
    XCTAssertEqual(noCategory.rememberRefusalKey, "entry.cashback.rememberNoCategory")
    XCTAssertEqual(
      context(severalCards: true).rememberRefusalKey, "entry.cashback.chooseCard")
  }

  /// A card whose account the context does not know: no rule can be written for it, so
  /// «Запомнить» is off and says why instead of doing nothing.
  func testRememberIsOffWhenTheCardHasNoAccount() {
    var noAccount = context()
    noAccount.accountId = nil
    XCTAssertNil(noAccount.rule(CashbackPercent(e4: 70_000)!, onlyThisMonth: false))
    XCTAssertEqual(noAccount.rememberRefusalKey, "entry.cashback.chooseCard")
    var ownRules = context(holder: .account(account))
    ownRules.accountId = nil
    XCTAssertNil(ownRules.rememberRefusalKey, "an account's own rule names its account")
  }

  /// An operation opened again with the 120 ₽ the owner typed: the field shows the figure, and a
  /// save of any other change keeps it.
  func testAKeptFigureIsSavedAgain() {
    let typed = Money(amount: AmountE4(whole: 120), currency: .rub)
    var opened = draft()
    opened.cashback = typed
    let state = CashbackFieldState(kept: opened.cashback, on: opened)
    XCTAssertEqual(state.input, .amount(AmountE4(whole: 120)))
    XCTAssertEqual(state.value(on: opened), typed)
    let exact = Money(amount: AmountE4(raw: 123_456), currency: .rub)
    XCTAssertEqual(CashbackFieldState(kept: exact).value(on: opened), exact, "every digit kept")
    XCTAssertEqual(
      CashbackFieldState(kept: Money(amount: AmountE4(whole: 1_500), currency: .rub))
        .value(on: opened), Money(amount: AmountE4(whole: 1_500), currency: .rub))
    XCTAssertEqual(CashbackFieldState(kept: nil).text, "")
    XCTAssertNil(CashbackFieldState(kept: nil).value(on: opened))
    // A figure in money the account no longer moves says nothing about the operation.
    let tenge = Money(amount: AmountE4(whole: 100), currency: CurrencyCode("KZT"))
    XCTAssertEqual(CashbackFieldState(kept: tenge, on: opened).text, "")
  }
}
