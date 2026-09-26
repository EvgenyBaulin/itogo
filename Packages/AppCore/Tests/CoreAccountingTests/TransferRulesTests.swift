import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Transfers between accounts")
struct TransferRulesTests {
  let categories = StartingCategories()
  let kzt = CurrencyCode("KZT")

  var card: PaymentMethod { PaymentMethod(id: id(1), name: "Card", currency: .rub) }
  var multi: PaymentMethod {
    PaymentMethod(id: id(2), name: "Multi", currency: .eur, otherCurrencies: [.usd, .rub, kzt])
  }

  func transfer(
    from: (UUID, CurrencyCode, Int), to: (UUID, CurrencyCode, Int)
  ) -> Transfer {
    Transfer(
      id: id(70), occurredAt: moment("2026-03-02"), fromAccountId: from.0, fromCurrency: from.1,
      fromAmountE4: money(from.2), toAccountId: to.0, toCurrency: to.1, toAmountE4: money(to.2))
  }

  @Test func aTransferBetweenHeldCurrenciesIsFine() {
    let accounts = [card, multi]
    #expect(
      TransferRules.validate(
        transfer(from: (id(1), .rub, 1000), to: (id(2), .rub, 1000)),
        accounts: accounts) == nil)
    // An exchange inside one account is a transfer between two of its currencies.
    #expect(
      TransferRules.validate(
        transfer(from: (id(2), .rub, 10_000), to: (id(2), kzt, 55_000)),
        accounts: accounts) == nil)
  }

  @Test func whatIsWrongIsSaid() {
    let accounts = [card, multi]
    #expect(
      TransferRules.validate(
        transfer(from: (id(1), .rub, 0), to: (id(2), .rub, 0)),
        accounts: accounts) == .notPositive)
    #expect(
      TransferRules.validate(
        transfer(from: (id(2), .rub, 10), to: (id(2), .rub, 10)),
        accounts: accounts) == .sameKey)
    #expect(
      TransferRules.validate(
        transfer(from: (id(1), .usd, 10), to: (id(2), .usd, 10)),
        accounts: accounts) == .currencyNotHeld(.from))
    #expect(
      TransferRules.validate(
        transfer(from: (id(2), .usd, 10), to: (id(1), .usd, 10)),
        accounts: accounts) == .currencyNotHeld(.to))
    #expect(
      TransferRules.validate(
        transfer(from: (id(1), .rub, 1000), to: (id(2), .rub, 990)),
        accounts: accounts) == .amountsDiffer)
    var archived = multi
    archived.archived = true
    #expect(
      TransferRules.validate(
        transfer(from: (id(1), .rub, 10), to: (id(2), .rub, 10)),
        accounts: [card, archived]) == .archivedAccount)
    #expect(
      TransferRules.validate(
        transfer(from: (id(1), .rub, 10), to: (id(9), .rub, 10)),
        accounts: [card]) == .archivedAccount)
  }

  @Test func theFeeIsAnExpenseFromTheAccountTheMoneyLeft() {
    let move = transfer(from: (id(2), .usd, 100), to: (id(1), .rub, 9000))
    let draft = TransferRules.feeDraft(
      transfer: move, fee: money(2), categoryId: categories.fees, tree: categories.tree)
    #expect(draft.kind == .expense)
    #expect(draft.paymentMethodId == id(2))
    #expect(draft.currency == .usd)
    #expect(draft.amount == money(2))
    #expect(draft.occurredAt == move.occurredAt)
    #expect(draft.parts.map(\.categoryId) == [categories.fees])
    #expect(draft.parts.first?.quality == .bad)
    #expect(OperationLink(externalId: TransferRules.feeKey(of: id(70))) == .transferFee(id(70)))
    #expect(OperationLink.transferFee(id(70)).isBookkeeping == false)
  }

  // MARK: The category of the fees

  @Test func theRememberedCategoryComesFirstWhileItIsLive() {
    let all = startingList()
    #expect(
      TransferRules.feeCategory(categories: all, remembered: categories.car)
        == .existing(categories.car))
    var archived = all
    if let index = archived.firstIndex(where: { $0.id == categories.car }) {
      archived[index].archived = true
    }
    #expect(
      TransferRules.feeCategory(categories: archived, remembered: categories.car)
        == .existing(categories.fees))
    // A system category is never where fees go.
    #expect(
      TransferRules.feeCategory(categories: all, remembered: categories.loans)
        == .existing(categories.fees))
  }

  @Test func aCategoryCalledFeesUnderOtherIsFound() {
    var all = startingList()
    all.append(CoreKit.Category(id: id(130), kind: .expense, name: "Комиссии", sort: -1))
    #expect(
      TransferRules.feeCategory(categories: all, remembered: nil) == .existing(categories.fees))
  }

  @Test func withoutOneItIsMadeUnderOther() {
    let all = startingList().filter { $0.id != categories.fees }
    #expect(
      TransferRules.feeCategory(categories: all, remembered: nil)
        == .create(nameKey: "category.fees", parent: categories.other, quality: .bad))
    let bare = all.filter { $0.id != categories.other }
    #expect(
      TransferRules.feeCategory(categories: bare, remembered: nil)
        == .create(nameKey: "category.fees", parent: nil, quality: .bad))
  }

  /// The starting categories of the fixture as a list.
  func startingList() -> [CoreKit.Category] {
    [
      categories.goals, categories.goalsTrip, categories.loans, categories.loansCar,
      categories.surcharges, categories.unknown, categories.groceries, categories.education,
      categories.health, categories.pharmacy, categories.car, categories.fines, categories.fuel,
      categories.other, categories.fees, categories.salary, categories.bonus,
    ].compactMap { categories.tree[$0] }
  }
}
