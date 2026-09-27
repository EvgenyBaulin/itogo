import AppCore
import XCTest

@testable import Itogo

/// The place filter of the Transactions window: a place in the archive is still where its
/// operations were made, so the filter offers it — after the live places — and a filter on a
/// place archived since it was chosen stays, still finding its operations.
final class TransactionFiltersArchiveTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 27)
  private let market = Place(name: "Рынок")
  private let bakery = Place(name: "Булочная")
  private let coffee = Place(name: "Кофемания", archived: true)
  private let bar = Place(name: "Бар", archived: true)

  /// «Булочная», «Рынок», then «Бар» and «Кофемания» of the archive, each part by its name.
  func testAnArchivedPlaceIsOfferedAfterTheLiveOnes() {
    let choices = FilterChoices(Dataset(places: [coffee, market, bar, bakery]))

    XCTAssertEqual(choices.places.map(\.id), [bakery.id, market.id, bar.id, coffee.id])
    XCTAssertEqual(choices.archivedPlaceIds, [bar.id, coffee.id])
  }

  /// «Кофемания» chosen, then archived: the filter keeps it, and it still finds the purchase
  /// made there. A place deleted since is dropped as before.
  func testAFilterOnAPlaceArchivedSinceIsKept() throws {
    var live = coffee
    live.archived = false
    var filters = TransactionFilters(today: today)
    filters.placeId = coffee.id
    filters.keep(within: FilterChoices(Dataset(places: [live, market])))
    XCTAssertEqual(filters.placeId, coffee.id)

    filters.keep(within: FilterChoices(Dataset(places: [coffee, market])))
    XCTAssertEqual(filters.placeId, coffee.id, "a filter on a place put in the archive was dropped")
    let filter = filters.entryFilter(today: today)
    XCTAssertEqual(filter.placeId, coffee.id)

    filters.keep(within: FilterChoices(Dataset(places: [market])))
    XCTAssertNil(filters.placeId, "a filter on a place that is gone stayed")
  }
}

/// The account filter with cards: each account is offered followed by its live cards,
/// «Т-Банк · Black»; a card brings its account, an account drops the card, and a card archived
/// since it was chosen leaves the account alone chosen.
final class TransactionFiltersCardTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 9, day: 27)
  private let sber = PaymentMethod(name: "Сбер", kind: .card, currency: .rub, isDefault: true)
  private let tBank = PaymentMethod(name: "Т-Банк", kind: .card, currency: .rub)

  func testTheAccountFilterOffersEachAccountWithItsCards() {
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    let virtual = PaymentCard(accountId: tBank.id, name: "Virtual", sort: 1)
    let old = PaymentCard(accountId: tBank.id, name: "Old", archived: true)
    let sberCard = PaymentCard(accountId: sber.id, name: "Сбер")
    let choices = FilterChoices(
      Dataset(paymentMethods: [tBank, sber], cards: [virtual, old, black, sberCard]),
      locale: Locale(identifier: "ru"))

    XCTAssertEqual(
      choices.accountItems.map(\.name),
      ["Сбер", "Сбер · Сбер", "Т-Банк", "Т-Банк · Black", "Т-Банк · Virtual"])
    XCTAssertEqual(
      choices.accountItems.filter(\.isCard).map(\.id), [sberCard.id, black.id, virtual.id])
  }

  func testACardBringsItsAccountAndAnAccountDropsTheCard() {
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    var filters = TransactionFilters(today: today)
    filters.setAccountOrCard(black.id, cards: [black])
    XCTAssertEqual(filters.paymentMethodId, tBank.id)
    XCTAssertEqual(filters.cardId, black.id)
    XCTAssertEqual(filters.accountOrCard, black.id)
    let filter = filters.entryFilter(today: today)
    XCTAssertEqual(filter.paymentMethodId, tBank.id)
    XCTAssertEqual(filter.cardId, black.id)
    XCTAssertTrue(filters.canReset)

    filters.setAccountOrCard(sber.id, cards: [black])
    XCTAssertEqual(filters.paymentMethodId, sber.id)
    XCTAssertNil(filters.cardId)
    filters.setAccountOrCard(nil, cards: [black])
    XCTAssertNil(filters.paymentMethodId)
    XCTAssertFalse(filters.canReset)
  }

  func testACardArchivedSinceLeavesItsAccountChosen() {
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    var filters = TransactionFilters(today: today)
    filters.setAccountOrCard(black.id, cards: [black])
    filters.keep(within: FilterChoices(Dataset(paymentMethods: [sber, tBank], cards: [black])))
    XCTAssertEqual(filters.cardId, black.id)

    var archived = black
    archived.archived = true
    filters.keep(within: FilterChoices(Dataset(paymentMethods: [sber, tBank], cards: [archived])))
    XCTAssertNil(filters.cardId, "a card no longer offered went on filtering")
    XCTAssertEqual(filters.paymentMethodId, tBank.id)
  }
}
