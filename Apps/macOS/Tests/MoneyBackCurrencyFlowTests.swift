import AppCore
import AppDatabase
import XCTest

@testable import Itogo

/// Money back through the line and its confirmation when currencies meet: dollars back for
/// ruble parts, dollars onto a ruble card whose statement says what the card received, and
/// parts whose rate is still provisional — passed over, never closed with rubles that are not
/// known yet, and never letting money over them become income.
@MainActor
final class MoneyBackCurrencyFlowTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private let anya = Person(name: "Аня")
  private let card = PaymentMethod(name: "Карта", isDefault: true)
  private let freedom = PaymentMethod(name: "Freedom", currency: .usd)
  private let food = CoreKit.Category(kind: .expense, name: "Еда", quality: .neutral)
  private var surcharges: CoreKit.Category!
  private let calendar = CalendarContext.utc

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(anya)
    for account in [card, freedom] { try references.save(account) }
    try references.save(food)
    if let seeded = try references.category(systemRole: .surcharges, kind: .income) {
      surcharges = seeded
    } else {
      surcharges = CoreKit.Category(kind: .income, name: "Доплаты", systemRole: .surcharges)
      try references.save(surcharges)
    }
  }

  private var today: DateOnly { DateOnly(year: 2026, month: 9, day: 18) }

  private func noon(_ day: DateOnly) -> Date {
    calendar.startOfDay(day).addingTimeInterval(12 * 3600)
  }

  private var setting: ReimbursementRecording.Setting {
    ReimbursementRecording.Setting(
      surchargesCategoryId: surcharges.id, categories: CategoryTree([food, surcharges]),
      history: .empty, surplusNote: "Доплата", shortfallNote: "Недостача")
  }

  /// A dinner paid on the card where `owed` of it was for Anya, in `currency` at `rate`.
  @discardableResult
  private func dinner(
    _ note: String, owed: AmountE4, daysAgo: Int, currency: CurrencyCode = .rub,
    rate: Decimal? = nil, provisional: Bool = false
  ) throws -> TransactionEntry {
    let mine = AmountE4(whole: 5)
    var draft = TransactionDraft(
      kind: .expense, occurredAt: noon(calendar.adding(days: -daysAgo, to: today)),
      currency: currency, amount: mine + owed, rate: rate, rateDate: rate.map { _ in today },
      rateSource: rate.map { _ in .cbr }, rateProvisional: provisional, note: note,
      paymentMethodId: currency == .rub ? card.id : freedom.id)
    var theirs = PartDraft(amount: owed, note: note)
    theirs.categoryId = food.id
    theirs.reimbursable = true
    theirs.reimbursementStatus = .expected
    theirs.debtorPersonId = anya.id
    draft.parts = [PartDraft(categoryId: food.id, amount: mine), theirs]
    let entry = try draft.materialize(rublesConverter: { amount in
      guard let rate else { return amount }
      return try AmountE4(decimal: amount.decimal * rate)
    })
    return try transactions.save(entry)
  }

  /// The line as Enter reads it: the money back the confirmation opens with. `screen` is the
  /// account whose screen is open.
  private func enter(_ line: String, screen: UUID? = nil) throws -> MoneyBackPrefill {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: calendar)
    model.openAccountScreen = { screen }
    model.reload()
    let parsed = InputLineParser(
      vocabulary: ParserVocabulary(people: [.init(id: anya.id, name: anya.name)]),
      calendar: calendar
    ).parse(line, today: today)
    model.apply(parsed, amount: try AmountE4(decimal: try XCTUnwrap(parsed.amount)), today: today)
    XCTAssertTrue(model.recordsThroughReimbursementSheet, line)
    var draft = model.draftForSaving
    draft.occurredAt = noon(today)
    return MoneyBackPrefill(draft: draft)
  }

  private func confirm(
    _ prefill: MoneyBackPrefill, dollar: Decimal
  ) throws
    -> MoneyBackConfirmation
  {
    try MoneyBackConfirmation.make(
      draft: prefill.draft, owed: try transactions.owedParts(), debts: [],
      rates: RateTable(rates: [
        Rate(date: today, currency: .usd, rubPerUnit: dollar),
        Rate(date: today, currency: kzt, rubPerUnit: 20, nominal: 100),
      ]),
      calendar: calendar)
  }

  private let kzt = CurrencyCode("KZT")

  private func record(_ confirmation: MoneyBackConfirmation) throws {
    let written = try XCTUnwrap(try confirmation.recording(setting: setting))
    try transactions.apply(
      written.outcome, reimbursement: written.reimbursement, extra: written.extra)
  }

  private func all() throws -> [TransactionEntry] {
    try transactions.entries(from: .distantPast, to: .distantFuture)
  }

  // MARK: Rubles are written once

  /// 50 $ at 95 ₽ onto the dollar account for a part of 4,500 ₽: the part closes with its
  /// 4,500 ₽ and the 2.6316 $ over are income in «Доплаты» of exactly 250 ₽ — together the
  /// 4,750 ₽ that came in, not 4,750.0020 ₽.
  func testDollarsOverARublePartAreIncomeOfTheRublesLeft() throws {
    let part = try dinner("ужин", owed: AmountE4(whole: 4500), daysAgo: 3)
    var prefill = try enter("возврат денег 50$ от Ани")
    prefill.draft.paymentMethodId = freedom.id
    let confirmation = try confirm(prefill, dollar: 95)
    XCTAssertEqual(confirmation.plan.closes, [part.parts[1].id])
    try record(confirmation)

    let entries = try all()
    let moneyBack = try XCTUnwrap(entries.first { $0.transaction.kind == .reimbursement })
    let surplus = try XCTUnwrap(entries.first { $0.transaction.kind == .income })
    XCTAssertEqual(moneyBack.transaction.amountRubE4, AmountE4(whole: 4750))
    XCTAssertEqual(surplus.transaction.currency, .usd)
    XCTAssertEqual(surplus.transaction.amountE4, try AmountE4(decimal: Decimal(string: "2.6316")!))
    XCTAssertEqual(surplus.transaction.amountRubE4, AmountE4(whole: 250))
    XCTAssertEqual(surplus.parts.first?.categoryId, surcharges.id)
    XCTAssertEqual(surplus.transaction.paymentMethodId, freedom.id)
    XCTAssertEqual(
      confirmation.plan.allocatedRubE4 + surplus.transaction.amountRubE4,
      moneyBack.transaction.amountRubE4)
    XCTAssertTrue(try transactions.owedParts().isEmpty)
  }

  /// 20 $ onto the ruble card, which the statement says received 1,850 ₽ (the bank's rate
  /// would give 1,900 ₽): the parts are closed by what the card received — the 1,000 ₽ dinner
  /// whole, 850 ₽ of the 1,500 ₽ one — and 650 ₽ is still owed.
  func testDollarsOntoARubleCardCloseByWhatTheCardReceived() throws {
    let older = try dinner("ужин", owed: AmountE4(whole: 1000), daysAgo: 10)
    let newer = try dinner("кино", owed: AmountE4(whole: 1500), daysAgo: 5)
    var prefill = try enter("возврат денег 20$ от Ани")
    XCTAssertEqual(prefill.draft.currency, .usd)
    XCTAssertEqual(prefill.draft.paymentMethodId, card.id)
    prefill.draft.accountCurrency = .rub
    prefill.draft.accountAmount = AmountE4(whole: 1850)
    let confirmation = try confirm(prefill, dollar: 95)
    XCTAssertEqual(confirmation.entry.transaction.amountRubE4, AmountE4(whole: 1850))
    XCTAssertEqual(confirmation.plan.closes, [older.parts[1].id])
    XCTAssertEqual(confirmation.stillOwedRub, AmountE4(whole: 650))
    XCTAssertEqual(confirmation.plan.surplus, .zero)
    try record(confirmation)

    let owed = try transactions.owedParts()
    XCTAssertEqual(owed.map(\.partId), [newer.parts[1].id])
    XCTAssertEqual(owed.first?.remainingRubE4, AmountE4(whole: 650))
    XCTAssertFalse(try all().contains { $0.transaction.kind == .income }, "nothing is income")
  }

  // MARK: Provisional rates

  /// Anya's older part is in dollars on a rate still provisional: 1,000 ₽ back passes it over
  /// and goes to the newer ruble part, which keeps waiting with 500 ₽; the older one is owed
  /// whole, as before.
  func testAPartOnAProvisionalRateIsPassedOverForTheNextOne() throws {
    let older = try dinner(
      "такси", owed: AmountE4(whole: 10), daysAgo: 10, currency: .usd, rate: 95,
      provisional: true)
    let newer = try dinner("кино", owed: AmountE4(whole: 1500), daysAgo: 5)
    let confirmation = try confirm(try enter("возврат денег 1000 от Ани"), dollar: 95)
    XCTAssertNil(confirmation.plan.refusal)
    XCTAssertEqual(confirmation.plan.skippedProvisional, [older.parts[1].id])
    XCTAssertEqual(
      confirmation.plan.allocations,
      [ReimbursementAllocation(partId: newer.parts[1].id, amountE4: AmountE4(whole: 1000))])
    XCTAssertEqual(confirmation.stillOwedRub, AmountE4(whole: 950 + 500))
    try record(confirmation)

    let owed = try transactions.owedParts()
    XCTAssertEqual(Set(owed.map(\.partId)), [older.parts[1].id, newer.parts[1].id])
    XCTAssertEqual(
      owed.first { $0.partId == older.parts[1].id }?.remainingRubE4, AmountE4(whole: 950))
  }

  /// Money over the parts that can be closed while a part on a provisional rate still waits
  /// would be income now and close that part later all the same: nothing is recorded yet.
  func testMoneyOverWhileAProvisionalPartWaitsIsNotRecorded() throws {
    try dinner(
      "такси", owed: AmountE4(whole: 10), daysAgo: 10, currency: .usd, rate: 95,
      provisional: true)
    try dinner("кино", owed: AmountE4(whole: 500), daysAgo: 5)
    let confirmation = try confirm(try enter("возврат денег 2000 от Ани"), dollar: 95)
    XCTAssertEqual(confirmation.plan.refusal, .provisionalPartsOwed)
    XCTAssertNil(try confirmation.recording(setting: setting))
    XCTAssertEqual(try transactions.owedParts().count, 2)
  }

  // MARK: Deleting money back

  /// 1,700 ₽ back closed the 1,000 ₽ dinner and left 800 ₽ of the cinema, whose rest was then
  /// written off. Deleting the money back reopens both parts whole and takes the write-off
  /// along — the rest was never spent, since nothing came back —, and ⌘Z brings all of it back.
  func testDeletingMoneyBackReopensThePartsAndTakesTheWriteOffAlong() throws {
    let older = try dinner("ужин", owed: AmountE4(whole: 1000), daysAgo: 10)
    let newer = try dinner("кино", owed: AmountE4(whole: 1500), daysAgo: 5)
    try record(try confirm(try enter("возврат денег 1700 от Ани"), dollar: 95))
    let rest = try XCTUnwrap(try transactions.owedParts().first)
    let store = TransactionsStore(repository: transactions, references: references)
    XCTAssertEqual(
      ReimbursementSheet.writeOffRest(
        of: rest, repository: transactions, store: store, setting: setting, now: noon(today),
        scheduleBackup: {}),
      .writtenOff)
    XCTAssertTrue(try transactions.owedParts().isEmpty)
    let moneyBack = try XCTUnwrap(try all().first { $0.transaction.kind == .reimbursement })

    XCTAssertTrue(store.delete(id: moneyBack.id))
    let owed = try transactions.owedParts()
    XCTAssertEqual(Set(owed.map(\.partId)), [older.parts[1].id, newer.parts[1].id])
    XCTAssertEqual(
      AmountE4.sum(owed.map(\.remainingRubE4)), AmountE4(whole: 2500), "both owed whole")
    XCTAssertFalse(
      try all().contains { $0.transaction.externalId?.hasPrefix("writeoff:") == true },
      "the write-off went with the money back")

    store.undo()
    XCTAssertTrue(try transactions.owedParts().isEmpty)
    XCTAssertTrue(
      try all().contains { $0.transaction.externalId?.hasPrefix("writeoff:") == true })
    XCTAssertTrue(try all().contains { $0.id == moneyBack.id })
  }

  /// «для Ани» still names whom money back came from, as «от Ани» does.
  func testForAnyaNamesThePersonOfMoneyBackToo() throws {
    try dinner("ужин", owed: AmountE4(whole: 1000), daysAgo: 3)
    let prefill = try enter("возврат денег 400 для Ани")
    XCTAssertEqual(prefill.personId, anya.id)
    let confirmation = try confirm(prefill, dollar: 95)
    XCTAssertEqual(confirmation.stillOwedRub, AmountE4(whole: 600))
  }

  // MARK: The surplus and the rate

  /// 50 $ at 95 ₽ over a part of 4,500 ₽: the 2.6316 $ of «Доплаты» are 250 ₽ and show the rate
  /// the money came at, 95 — not 250 ÷ 2.6316 = 94.999240, a rate nobody had.
  func testTheSurplusShowsTheRateTheMoneyCameAt() throws {
    try dinner("ужин", owed: AmountE4(whole: 4500), daysAgo: 3)
    var prefill = try enter("возврат денег 50$ от Ани")
    prefill.draft.paymentMethodId = freedom.id
    try record(try confirm(prefill, dollar: 95))
    let surplus = try XCTUnwrap(try all().first { $0.transaction.kind == .income })
    XCTAssertEqual(surplus.transaction.rate, 95)
    XCTAssertEqual(surplus.transaction.amountRubE4, AmountE4(whole: 250))
  }

  // MARK: On the screen of a tenge account

  /// «возврат денег 5000 от Ани» on the Kaspi screen: 5,000 ₸ at 20 ₽ for 100 ₸ are 1,000 ₽.
  /// The 700 ₽ dinner closes with its 700 ₽ (3,500 ₸), and the 1,500 ₸ over are income in
  /// «Доплаты» in tenge, on Kaspi, of exactly the 300 ₽ left, at the rate the money came at.
  func testMoneyBackOnATengeScreenIsPlannedAndPaidOverInTenge() throws {
    let kaspi = PaymentMethod(name: "Kaspi", currency: kzt)
    try references.save(kaspi)
    let part = try dinner("ужин", owed: AmountE4(whole: 700), daysAgo: 3)
    let prefill = try enter("возврат денег 5000 от Ани", screen: kaspi.id)
    XCTAssertEqual(prefill.draft.currency, kzt)
    XCTAssertEqual(prefill.draft.paymentMethodId, kaspi.id)
    let confirmation = try confirm(prefill, dollar: 95)
    XCTAssertEqual(confirmation.plan.currency, kzt)
    XCTAssertEqual(confirmation.plan.closes, [part.parts[1].id])
    XCTAssertEqual(confirmation.plan.allocatedRubE4, AmountE4(whole: 700))
    XCTAssertEqual(confirmation.plan.surplus, AmountE4(whole: 1500))
    XCTAssertEqual(confirmation.plan.surplusRub, AmountE4(whole: 300))
    try record(confirmation)

    let entries = try all()
    let moneyBack = try XCTUnwrap(entries.first { $0.transaction.kind == .reimbursement })
    XCTAssertEqual(moneyBack.transaction.amountRubE4, AmountE4(whole: 1000))
    let surplus = try XCTUnwrap(entries.first { $0.transaction.kind == .income })
    XCTAssertEqual(surplus.transaction.currency, kzt)
    XCTAssertEqual(surplus.transaction.amountE4, AmountE4(whole: 1500))
    XCTAssertEqual(surplus.transaction.amountRubE4, AmountE4(whole: 300))
    XCTAssertEqual(surplus.transaction.rate, Decimal(string: "0.2"))
    XCTAssertEqual(surplus.transaction.paymentMethodId, kaspi.id)
    XCTAssertEqual(surplus.parts.first?.categoryId, surcharges.id)
    XCTAssertTrue(try transactions.owedParts().isEmpty)
  }

  // MARK: «Списать остаток» in dollars

  /// A 10 $ taxi for Anya on the dollar account at 95 ₽ (950 ₽); 5 $ came back onto the same
  /// account, 475 ₽ is still owed, and the owner writes the rest off. The write-off is my
  /// spending of 475 ₽ in the taxi's category: a line of the books, which moves no money on the
  /// dollar account — nor on rubles it does not hold — and asks for no «Списано».
  func testWritingOffTheRestOfADollarPartMovesNoMoneyOnTheDollarAccount() throws {
    let taxi = try dinner(
      "такси", owed: AmountE4(whole: 10), daysAgo: 5, currency: .usd, rate: 95)
    var prefill = try enter("возврат денег 5$ от Ани")
    prefill.draft.paymentMethodId = freedom.id
    let confirmation = try confirm(prefill, dollar: 95)
    XCTAssertEqual(
      confirmation.plan.allocations,
      [ReimbursementAllocation(partId: taxi.parts[1].id, amountE4: AmountE4(whole: 475))])
    try record(confirmation)
    let rest = try XCTUnwrap(try transactions.owedParts().first)
    XCTAssertEqual(rest.remainingRubE4, AmountE4(whole: 475))

    let before = try balances()
    let store = TransactionsStore(repository: transactions, references: references)
    XCTAssertEqual(
      ReimbursementSheet.writeOffRest(
        of: rest, repository: transactions, store: store, setting: setting, now: noon(today),
        scheduleBackup: {}),
      .writtenOff)
    XCTAssertTrue(try transactions.owedParts().isEmpty)
    let writeOff = try XCTUnwrap(
      try all().first { $0.transaction.externalId?.hasPrefix("writeoff:") == true })
    XCTAssertEqual(writeOff.transaction.kind, .expense)
    XCTAssertEqual(writeOff.transaction.currency, .rub)
    XCTAssertEqual(writeOff.transaction.amountRubE4, AmountE4(whole: 475))
    XCTAssertEqual(writeOff.transaction.paymentMethodId, freedom.id)
    XCTAssertNil(writeOff.transaction.accountAmountE4, "no «Списано» on a line of the books")
    XCTAssertEqual(writeOff.parts.first?.categoryId, food.id)

    let after = try balances()
    let dollars = BalanceKey(accountId: freedom.id, currency: .usd)
    XCTAssertEqual(after[dollars]?.movedSinceAnchor, before[dollars]?.movedSinceAnchor)
    let rubles = BalanceKey(accountId: freedom.id, currency: .rub)
    XCTAssertEqual(
      after[rubles]?.movedSinceAnchor ?? .zero, before[rubles]?.movedSinceAnchor ?? .zero)
  }

  private func balances() throws -> AccountBalances {
    AccountBalances.build(
      entries: try all(), transfers: [], debtEntries: [], debts: [:], reconciliations: [],
      balances: [], accounts: [card, freedom], tree: CategoryTree([food, surcharges]),
      now: noon(calendar.adding(days: 1, to: today)), calendar: calendar)
  }
}
