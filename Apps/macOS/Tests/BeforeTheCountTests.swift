import AppCore
import AppDatabase
import XCTest

@testable import Itogo

/// «Это было до сверки в 14:05?»: an operation dated on the day of the latest count of its
/// account and saved after that count asks whether its money was already in what was counted.
/// «Да» dates it a second before the count, «Нет» after it.
@MainActor
final class BeforeTheCountTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!

  private let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
  private let cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)

  private let today = DateOnly(year: 2026, month: 9, day: 18)
  private var yesterday: DateOnly { DateOnly(year: 2026, month: 9, day: 17) }

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(card)
    try references.save(cash)
  }

  private func moment(_ day: DateOnly, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    CalendarContext.utc.startOfDay(day)
      .addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + second))
  }

  /// The card counted at `at`, as the reconciliation sheet writes it.
  private func counted(at: Date, account: PaymentMethod? = nil, now: Date) -> AccountBalances {
    let reconciliation = Reconciliation(
      date: CalendarContext.utc.day(of: at), reconciledAt: at, actualTotalRubE4: .zero,
      kind: .accounts)
    let balance = ReconciledBalance(
      reconciliationId: reconciliation.id, accountId: (account ?? card).id, currency: .rub,
      actualE4: AmountE4(whole: 10_000))
    return AccountBalances.build(
      entries: [], transfers: [], debtEntries: [], debts: [:], reconciliations: [reconciliation],
      balances: [balance], accounts: [card, cash], tree: CategoryTree(), now: now,
      calendar: .utc)
  }

  private func makeModel() -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    model.openAccountScreen = { nil }
    model.rateTable = { RateTable() }
    model.reload()
    return model
  }

  /// A line typed and about to be saved at `savedAt`.
  private func typed(
    _ model: EntryDraftModel, date: DateOnly? = nil, account: UUID? = nil, savedAt: Date
  ) {
    model.apply(
      ParsedInput(amount: 500, date: date, paymentMethodId: account, note: "taxi"),
      amount: AmountE4(whole: 500), today: today)
    model.takeTheMomentOfSaving(now: savedAt)
  }

  func testAnOperationOfTodaySavedAfterTodaysCountAsks() throws {
    let count = moment(today, 14, 5)
    let saved = moment(today, 15)
    let balances = counted(at: count, now: saved)
    let model = makeModel()
    typed(model, savedAt: saved)

    XCTAssertEqual(model.countToAskAbout(savedAt: saved, balances: balances), count)

    // «Да»: a second before the count, and the save that follows does not ask again.
    model.answerCount(count, wasBefore: true)
    XCTAssertEqual(model.draft.occurredAt, moment(today, 14, 4, 59))
    model.takeTheMomentOfSaving(now: saved)
    XCTAssertEqual(model.draft.occurredAt, moment(today, 14, 4, 59))
    XCTAssertNil(model.countToAskAbout(savedAt: saved, balances: balances))
  }

  func testYesterdayTypedTodayAfterYesterdaysCountAsks() throws {
    let count = moment(yesterday, 14, 5)
    let saved = moment(today, 10)
    let balances = counted(at: count, now: saved)
    let model = makeModel()
    typed(model, date: yesterday, savedAt: saved)
    // «вчера» carries noon, which says nothing about before or after the count.
    XCTAssertEqual(model.draft.occurredAt, moment(yesterday, 12))

    XCTAssertEqual(model.countToAskAbout(savedAt: saved, balances: balances), count)

    // «Нет»: after the count, whatever time the day carried.
    model.answerCount(count, wasBefore: false)
    XCTAssertEqual(model.draft.occurredAt, moment(yesterday, 14, 5, 1))
    XCTAssertNil(model.countToAskAbout(savedAt: saved, balances: balances))
  }

  /// The answer never moves the operation to another day, and so to another month of reports
  /// and limits: a count in the first second of its day answered «Да» keeps the operation on
  /// that day, and a count in the last second answered «Нет» keeps it there too.
  func testTheAnswerKeepsTheOperationOnTheDayOfTheCount() throws {
    let midnight = moment(today, 0)
    let morning = moment(today, 9)
    let early = makeModel()
    typed(early, savedAt: morning)
    XCTAssertEqual(
      early.countToAskAbout(savedAt: morning, balances: counted(at: midnight, now: morning)),
      midnight)
    early.answerCount(midnight, wasBefore: true)
    XCTAssertEqual(CalendarContext.utc.day(of: early.draft.occurredAt), today)
    XCTAssertEqual(early.draft.occurredAt, midnight)

    let lastSecond = moment(yesterday, 23, 59, 59)
    let afterMidnight = moment(today, 0, 10)
    let late = makeModel()
    typed(late, date: yesterday, savedAt: afterMidnight)
    XCTAssertEqual(
      late.countToAskAbout(
        savedAt: afterMidnight, balances: counted(at: lastSecond, now: afterMidnight)),
      lastSecond)
    late.answerCount(lastSecond, wasBefore: false)
    XCTAssertEqual(CalendarContext.utc.day(of: late.draft.occurredAt), yesterday)
    XCTAssertGreaterThan(late.draft.occurredAt, lastSecond)
  }

  func testAnAnswerKeepsALaterTimeOfTheDayAfterTheCount() throws {
    let count = moment(today, 9)
    let saved = moment(today, 15)
    let model = makeModel()
    typed(model, savedAt: saved)
    model.answerCount(count, wasBefore: false)
    XCTAssertEqual(model.draft.occurredAt, saved)
  }

  func testAnotherDayOrAnotherAccountDoesNotAsk() throws {
    let saved = moment(today, 15)
    // The count was the day before; the operation is today's.
    let earlier = counted(at: moment(yesterday, 14, 5), now: saved)
    let model = makeModel()
    typed(model, savedAt: saved)
    XCTAssertNil(model.countToAskAbout(savedAt: saved, balances: earlier))

    // Today's count was of the cash; the operation is on the card.
    let ofTheCash = counted(at: moment(today, 14, 5), account: cash, now: saved)
    XCTAssertNil(model.countToAskAbout(savedAt: saved, balances: ofTheCash))
    // On the cash it asks.
    let onCash = makeModel()
    typed(onCash, account: cash.id, savedAt: saved)
    XCTAssertEqual(
      onCash.countToAskAbout(savedAt: saved, balances: ofTheCash), moment(today, 14, 5))
  }

  /// The whole way of a save: asked, answered «Да», written — the database holds the operation
  /// a second before the count.
  func testTheAnswerReachesTheDatabase() throws {
    let count = moment(today, 14, 5)
    let saved = moment(today, 15)
    let balances = counted(at: count, now: saved)
    let model = makeModel()
    typed(model, savedAt: saved)
    let asked = try XCTUnwrap(model.countToAskAbout(savedAt: saved, balances: balances))
    model.answerCount(asked, wasBefore: true)
    // The save goes on: the moment of saving again, and no second question.
    model.takeTheMomentOfSaving(now: saved)
    XCTAssertNil(model.countToAskAbout(savedAt: saved, balances: balances))
    let entry = try model.draft.materialize(now: saved)
    try transactions.save(entry)
    XCTAssertEqual(
      try transactions.entry(id: entry.id)?.transaction.occurredAt, moment(today, 14, 4, 59))
  }

  /// A time the owner set in the panel that is already before the count answers «Да» by itself:
  /// the answer keeps it instead of moving it to the second before the count.
  func testYesKeepsATimeChosenBeforeTheCount() throws {
    let count = moment(today, 14, 5)
    let saved = moment(today, 15)
    let balances = counted(at: count, now: saved)
    let model = makeModel()
    typed(model, savedAt: saved)
    model.setDate(moment(today, 13), today: today)
    let asked = try XCTUnwrap(model.countToAskAbout(savedAt: saved, balances: balances))
    model.answerCount(asked, wasBefore: true)
    XCTAssertEqual(model.draft.occurredAt, moment(today, 13))
  }

  func testTheNextOperationAsksAgain() throws {
    let count = moment(today, 14, 5)
    let saved = moment(today, 15)
    let balances = counted(at: count, now: saved)
    let model = makeModel()
    typed(model, savedAt: saved)
    model.answerCount(count, wasBefore: true)
    model.reset()
    typed(model, savedAt: saved)
    XCTAssertEqual(model.countToAskAbout(savedAt: saved, balances: balances), count)
  }
}
