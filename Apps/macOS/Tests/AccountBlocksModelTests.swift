import AppCore
import XCTest

@testable import Itogo

/// The three blocks cards brought to an account's screen, at the level of their models: «Карты»,
/// «Кэшбэк · месяц» and «Платежи и подписки».
@MainActor
final class AccountBlocksModelTests: XCTestCase {
  private let tBank = UUID()
  private let sber = UUID()
  private let black = UUID()
  private let virtual = UUID()
  private let old = UUID()
  private let cafes = UUID()
  private let cashback = UUID()
  private let september = MonthKey(year: 2026, month: 9)
  private let calendar = CalendarContext.utc

  private var cards: [PaymentCard] {
    [
      PaymentCard(id: virtual, accountId: tBank, name: "Virtual", aliases: ["virt"]),
      PaymentCard(id: black, accountId: tBank, name: "Black"),
      PaymentCard(id: old, accountId: tBank, name: "Old", archived: true),
      PaymentCard(accountId: sber, name: "Sber"),
    ]
  }

  private var rules: [CashbackRule] {
    [
      CashbackRule(
        accountId: tBank, cardId: black, categoryId: cafes, month: september,
        percent: CashbackPercent(e4: 100_000)!),
      CashbackRule(accountId: tBank, cardId: black, percent: CashbackPercent(e4: 10_000)!),
      CashbackRule(
        accountId: tBank, cardId: black, categoryId: cafes,
        month: MonthKey(year: 2026, month: 8), percent: CashbackPercent(e4: 30_000)!),
    ]
  }

  func testTheCardsBlockListsLiveCardsInOrderAndTheArchivedApart() {
    let model = AccountCardsModel(
      accountId: tBank, cards: cards, rules: rules, locale: Locale(identifier: "en_US_POSIX"))
    XCTAssertEqual(model.live.map(\.card.name), ["Black", "Virtual"])
    XCTAssertEqual(model.archived.map(\.card.name), ["Old"])
    XCTAssertEqual(model.live.map(\.rules), [3, 0])
    XCTAssertEqual(model.live.last?.otherNames, "virt")
  }

  /// A coffee of 350 on Black in September: 10 % of the month's rule → 35.00 expected; 20
  /// received for September on Black. The line shows the rules of September and «always», not
  /// August's.
  func testTheCashbackBlockShowsExpectedAndReceived() throws {
    let at = calendar.noon(of: DateOnly(year: 2026, month: 9, day: 12))
    func operation(
      _ kind: TransactionKind, _ category: UUID, _ amount: Int64, card: UUID
    ) -> TransactionEntry {
      let transaction = Transaction(
        kind: kind, occurredAt: at, amountE4: AmountE4(whole: amount), paymentMethodId: tBank,
        createdAt: at, updatedAt: at, cardId: card)
      return TransactionEntry(
        transaction: transaction,
        parts: [
          TransactionPart(
            transactionId: transaction.id, categoryId: category,
            amountE4: AmountE4(whole: amount))
        ])
    }
    let dataset = Dataset(
      entries: [
        operation(.expense, cafes, 350, card: black),
        operation(.income, cashback, 20, card: black),
      ],
      categories: [
        CoreKit.Category(id: cafes, kind: .expense, name: "Cafes"),
        CoreKit.Category(id: cashback, kind: .income, name: "Cashback"),
      ],
      paymentMethods: [PaymentMethod(id: tBank, name: "T-Bank", kind: .card)],
      settings: AnalyticsSettings(cashbackCategoryId: cashback), cards: cards,
      cashbackRules: rules)
    let model = AccountCashbackModel.build(
      month: september, accountId: tBank, ledger: Ledger(dataset: dataset, calendar: calendar))
    XCTAssertEqual(model.lines.map(\.cardId), [black, virtual])
    let line = try XCTUnwrap(model.lines.first)
    XCTAssertEqual(line.expected, [Money(amount: AmountE4(whole: 35), currency: .rub)])
    XCTAssertEqual(line.received, [Money(amount: AmountE4(whole: 20), currency: .rub)])
    XCTAssertEqual(line.rules.map(\.month), [september, nil], "the month's rule first")
    XCTAssertFalse(model.isEmpty)
    XCTAssertTrue(model.lines[1].expected.isEmpty && model.lines[1].rules.isEmpty)
  }

  /// A quiet month of a tenge account: the empty sides are printed in tenge, not rubles.
  func testTheCashbackBlockSpeaksInTheAccountsCurrency() {
    let kaspi = UUID()
    let tenge = CurrencyCode("KZT")
    let dataset = Dataset(
      entries: [],
      paymentMethods: [PaymentMethod(id: kaspi, name: "Kaspi", kind: .card, currency: tenge)],
      cards: [PaymentCard(accountId: kaspi, name: "Gold")])
    let model = AccountCashbackModel.build(
      month: september, accountId: kaspi, ledger: Ledger(dataset: dataset, calendar: calendar))
    XCTAssertEqual(model.currency, tenge)
    let rubles = Dataset(
      entries: [], paymentMethods: [PaymentMethod(id: kaspi, name: "Cash", kind: .cash)])
    XCTAssertEqual(
      AccountCashbackModel.build(
        month: september, accountId: kaspi, ledger: Ledger(dataset: rubles, calendar: calendar)
      ).currency, .rub, "an account saved without a currency counts in rubles")
  }

  func testThePaymentsBlockNamesTheCardOrSaysItIsArchived() {
    func status(_ name: String, card: UUID?, account: UUID?) -> ScheduledStatus {
      let day = DateOnly(year: 2026, month: 9, day: 20)
      return ScheduledStatus(
        payment: ScheduledPayment(
          name: name, amountE4: AmountE4(whole: 299), paymentMethodId: account, nextDate: day,
          cardId: card),
        dueDates: [day], nextDue: day, isOverdue: false, amountNext: AmountE4(whole: 299),
        monthly: AmountE4(whole: 299), yearly: AmountE4(whole: 3_588),
        myShareRubNext: AmountE4(whole: 299), expectedReturnRubNext: nil, lastCharge: nil,
        chargedDifferently: false)
    }
    let model = AccountPaymentsModel(
      accountId: tBank,
      statuses: [
        status("Music", card: black, account: tBank), status("Cloud", card: old, account: tBank),
        status("Gym", card: nil, account: sber),
      ],
      cards: cards, mainAccountId: sber)
    XCTAssertEqual(model.rows.map(\.status.payment.name), ["Cloud", "Music"])
    XCTAssertEqual(model.rows.map(\.cardName), ["Old", "Black"])
    XCTAssertEqual(model.rows.map(\.cardArchived), [true, false])
    XCTAssertTrue(model.opensByItself)
  }

  /// «Добавить платёж…» on the Kaspi (₸) screen starts a payment in tenge, due today, paid from
  /// Kaspi — not 5,000 ₽ typed as 5,000 ₸. The tenge only follows the account: another account
  /// picked in the form moves the currency, as with a new payment of Planning. A candidate's
  /// currency stays the owner's.
  func testANewPaymentOfATengeAccountIsInTenge() throws {
    let kzt = CurrencyCode("KZT")
    let kaspi = PaymentMethod(name: "Kaspi", kind: .card, currency: kzt)
    let main = PaymentMethod(id: sber, name: "Сбер", kind: .card, currency: .rub, isDefault: true)
    let today = DateOnly(year: 2026, month: 9, day: 27)
    let sheet = AccountPaymentsBlock.newPaymentSheet(
      on: kaspi.id, accounts: [main, kaspi], defaultCurrency: .usd, today: today)
    XCTAssertNil(sheet.editedPayment, "a new payment")
    let start = try XCTUnwrap(sheet.startingPayment)
    XCTAssertEqual(start.paymentMethodId, kaspi.id)
    XCTAssertEqual(start.currency, kzt, "the account's main currency")
    XCTAssertEqual(start.nextDate, today)
    XCTAssertFalse(sheet.startCurrencyChosen)

    let moved = ScheduledPaymentForm.choosing(
      sber, for: start, methods: [main, kaspi], cards: [],
      currencyChosen: sheet.startCurrencyChosen, defaultCurrency: .usd)
    XCTAssertEqual(moved.paymentMethodId, sber)
    XCTAssertEqual(moved.currency, .rub, "the currency follows the account picked")

    let unseen = UUID()
    let early = AccountPaymentsBlock.newPaymentSheet(
      on: unseen, accounts: [main], defaultCurrency: .usd, today: today)
    XCTAssertEqual(early.startingPayment?.paymentMethodId, unseen)
    XCTAssertEqual(
      early.startingPayment?.currency, .usd, "an account the data has not brought yet: the default")

    XCTAssertTrue(
      PlanningSheet.newPayment(ScheduledPayment(name: "Music", amountE4: .zero))
        .startCurrencyChosen, "a candidate's currency is the owner's")
  }
}
