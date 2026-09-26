import AppCore
import AppDatabase
import Foundation

/// A transfer as the sheet holds it while the owner fills it in: where the money leaves, where
/// it arrives, how much went and came, the fee, the day and the note. Nothing here is written.
struct TransferForm: Hashable, Sendable {
  var fromAccountId: UUID?
  var fromCurrency: CurrencyCode?
  var toAccountId: UUID?
  var toCurrency: CurrencyCode?
  /// What left the account, in its currency.
  var sent: AmountE4 = .zero
  /// What arrived, in the currency of the other side; the same as `sent` in one currency.
  var received: AmountE4 = .zero
  /// What the bank took for it, in the currency the money left in; zero means no fee.
  var fee: AmountE4 = .zero
  var day: DateOnly
  var note: String = ""
  /// The transfer being edited; `nil` for a new one.
  var previous: Transfer?

  /// A new transfer from `account` in its main currency, on `day`. The other side is the main
  /// account when the money leaves another one, and nothing otherwise.
  init(from account: PaymentMethod?, accounts: [PaymentMethod], day: DateOnly) {
    self.day = day
    fromAccountId = account?.id
    fromCurrency = account?.mainCurrency
    if let main = accounts.first(where: { $0.isDefault && !$0.archived }), main.id != account?.id {
      toAccountId = main.id
      toCurrency = Self.currency(on: main, preferring: fromCurrency)
    }
  }

  /// «Перевести остаток…»: the money of `account` moved away whole — from the first of its
  /// currencies that holds money, the whole of it, to the main account as a new transfer goes.
  /// With nothing known on it, the form of a new transfer from it.
  init(
    movingBalanceOf account: PaymentMethod, balances: AccountBalances, accounts: [PaymentMethod],
    day: DateOnly
  ) {
    self.init(from: account, accounts: accounts, day: day)
    let held = account.currencies.lazy.compactMap { currency -> (CurrencyCode, AmountE4)? in
      guard
        let amount = balances[BalanceKey(accountId: account.id, currency: currency)]?.amountE4,
        amount.raw > 0
      else { return nil }
      return (currency, amount)
    }
    guard let (currency, amount) = held.first else { return }
    fromCurrency = currency
    sent = amount
    if let toAccountId, let main = accounts.first(where: { $0.id == toAccountId }) {
      toCurrency = Self.currency(on: main, preferring: currency)
    }
  }

  /// The form of a saved transfer and its fee.
  init(editing transfer: Transfer, fee: AmountE4?, calendar: CalendarContext) {
    previous = transfer
    fromAccountId = transfer.fromAccountId
    fromCurrency = transfer.fromCurrency
    toAccountId = transfer.toAccountId
    toCurrency = transfer.toCurrency
    sent = transfer.fromAmountE4
    received = transfer.toAmountE4
    self.fee = fee ?? .zero
    day = calendar.day(of: transfer.occurredAt)
    note = transfer.note ?? ""
  }

  /// Money changes currency: both amounts are asked, as the bank shows them.
  var isExchange: Bool {
    guard let fromCurrency, let toCurrency else { return false }
    return fromCurrency != toCurrency
  }

  /// What arrived: typed for an exchange, the money sent otherwise.
  var receivedAmount: AmountE4 { isExchange ? received : sent }

  /// Units received for one unit sent, as the two amounts imply; for showing only.
  var impliedRate: Decimal? {
    guard isExchange, sent.raw > 0, received.raw > 0 else { return nil }
    return received.decimal / sent.decimal
  }

  /// The side the money leaves from moved to another account: its currency follows the
  /// account unless the account holds the one chosen.
  mutating func chooseFrom(_ account: PaymentMethod) {
    fromAccountId = account.id
    fromCurrency = Self.currency(on: account, preferring: fromCurrency)
  }

  /// The side the money arrives at moved to another account: the currency the money leaves in
  /// when the account holds it — a plain transfer —, else the account's main currency.
  mutating func chooseTo(_ account: PaymentMethod) {
    toAccountId = account.id
    toCurrency = Self.currency(on: account, preferring: fromCurrency ?? toCurrency)
  }

  static func currency(
    on account: PaymentMethod, preferring currency: CurrencyCode?
  )
    -> CurrencyCode
  {
    if let currency, account.holds(currency) { return currency }
    return account.mainCurrency
  }

  /// The transfer to write, at `occurredAt`; `nil` while a side is not chosen.
  func transfer(id: UUID, occurredAt: Date, now: Date) -> Transfer? {
    guard let fromAccountId, let fromCurrency, let toAccountId, let toCurrency else {
      return nil
    }
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    return Transfer(
      id: id, occurredAt: occurredAt, fromAccountId: fromAccountId, fromCurrency: fromCurrency,
      fromAmountE4: sent, toAccountId: toAccountId, toCurrency: toCurrency,
      toAmountE4: receivedAmount, note: trimmed.isEmpty ? nil : trimmed,
      createdAt: previous?.createdAt ?? now, updatedAt: now)
  }

  /// The moment of the transfer before the question about a count: a transfer of today
  /// happened now, one of another day at its noon — the same moments the entry line gives —,
  /// and an edit that keeps the day keeps the moment it had.
  func occurredAt(now: Date, calendar: CalendarContext) -> Date {
    if let previous, calendar.day(of: previous.occurredAt) == day { return previous.occurredAt }
    return calendar.day(of: now) == day ? now : calendar.noon(of: day)
  }

  /// Whether saving has to ask «Это было до сверки?»: a new transfer does; an edit only when
  /// its day or its accounts and currencies moved.
  func asksAboutTheCount(_ transfer: Transfer, calendar: CalendarContext) -> Bool {
    guard let previous else { return true }
    return calendar.day(of: previous.occurredAt) != calendar.day(of: transfer.occurredAt)
      || previous.from != transfer.from || previous.to != transfer.to
  }
}

/// «Это было до сверки в 10:00?» — and, when the transfer's day holds several counts of the
/// balances it moves, the next one after «Нет»: a transfer is never put inside or after a count
/// the owner was not asked about.
struct CountQuestions: Sendable {
  enum Step: Sendable {
    /// The next count to ask about.
    case ask(CountQuestions)
    /// The moment the answers give the transfer.
    case stamp(Date)
  }

  /// The counts of the day, oldest first; never empty.
  let counts: [Date]
  /// The one asked about now.
  private(set) var index = 0
  /// The moment the transfer would get without the questions.
  let occurredAt: Date
  /// The owner's calendar: no answer moves the transfer to another day.
  let calendar: CalendarContext

  init(counts: [Date], occurredAt: Date, calendar: CalendarContext) {
    self.counts = counts
    self.occurredAt = occurredAt
    self.calendar = calendar
  }

  var count: Date { counts[index] }

  /// «Да» puts the transfer just before this count — after the one before it, if any — unless
  /// it is dated before the count already, as an operation keeps its moment; «Нет»
  /// asks about the next count, or puts the transfer after the last. No answer leaves the day
  /// of the counts in the owner's `calendar`: a count at midnight answered «Да» keeps the
  /// transfer on its day, one in the day's last second answered «Нет» too.
  func answer(wasBefore: Bool) -> Step {
    func stamped(_ count: Date, wasBefore: Bool) -> Date {
      AccountReconciliation.stamped(
        occurredAt: occurredAt, count: count, wasBefore: wasBefore, calendar: calendar)
    }
    if wasBefore {
      guard index > 0 else { return .stamp(min(occurredAt, stamped(count, wasBefore: true))) }
      let previous = counts[index - 1]
      let between = min(stamped(previous, wasBefore: false), stamped(count, wasBefore: true))
      // Two counts less than a second apart at the start of the day leave no whole second
      // before the later one on that day: the middle of the two is after the one and before
      // the other.
      return .stamp(
        between > previous
          ? between : previous.addingTimeInterval(count.timeIntervalSince(previous) / 2))
    }
    guard index + 1 < counts.count else { return .stamp(stamped(count, wasBefore: false)) }
    var next = self
    next.index += 1
    return .ask(next)
  }
}

/// Why a transfer was not saved. Nothing is written then.
enum TransferRefusal: Error, Hashable, Sendable {
  /// No account or currency on the side the money leaves.
  case noFrom
  /// No account or currency on the side it arrives.
  case noTo
  case issue(TransferIssue)
  /// A fee below zero.
  case negativeFee
  /// The fee is in a currency whose rate is not known for the day: its rubles cannot be told.
  case rateMissing(CurrencyCode)
  /// The transfer is not there any more.
  case notFound
  /// A refund was recorded against the fee: it is not taken off, made smaller than what came
  /// back or moved to another currency, and the transfer is not deleted with it.
  case feeRefunded
  /// Money a person gave back was linked to the fee: its amount and currency stay, and a fee
  /// it closed is not taken off.
  case feeMoneyBack
}

/// What came of saving or deleting a transfer.
enum TransferOutcome: Hashable, Sendable {
  case done
  case refused(TransferRefusal)
  /// The database did not take the write; the journal says why.
  case failed
}

/// Transfers between accounts and between the currencies of one account: a new one, an edit,
/// a deletion — each one write with its fee and one step of ⌘Z.
///
/// A transfer is neither income nor spending. Its fee is an ordinary expense from the account
/// the money left, in the category the fees go to («Комиссии»), which points back at the
/// transfer by its key; the category is found or made at the first fee and remembered.
@MainActor
struct TransferActions {
  let environment: AppEnvironment
  let store: TransactionsStore

  init(environment: AppEnvironment, store: TransactionsStore) {
    self.environment = environment
    self.store = store
  }

  /// The books as the database has them now: the accounts, the transfers, the fees and the
  /// balances the question about a count is asked from.
  func books() async -> AccountBooks? {
    await AccountActions(environment: environment, store: store).books()
  }

  // MARK: Reading

  /// The live fee of a transfer, if it has one.
  nonisolated static func fee(
    of transferId: UUID, in entries: [TransactionEntry]
  )
    -> TransactionEntry?
  {
    let key = TransferRules.feeKey(of: transferId)
    return entries.first { $0.transaction.externalId == key && !$0.transaction.isDeleted }
  }

  /// The counts a transfer at `transfer.occurredAt`, saved at `savedAt`, has to ask about,
  /// oldest first: of each balance it moves, the latest count, when it was made on the
  /// transfer's day before the transfer is saved — the rule of
  /// `AccountReconciliation.beforeTheCount`, every count of the day rather than the earliest.
  nonisolated static func countMoments(
    for transfer: Transfer, savedAt: Date, balances: AccountBalances, calendar: CalendarContext
  ) -> [Date] {
    let day = calendar.day(of: transfer.occurredAt)
    let moments = Set(AccountReconciliation.movedKeys(of: transfer)).compactMap { key -> Date? in
      guard let anchor = balances.latestAnchor(key), calendar.day(of: anchor.at) == day,
        savedAt > anchor.at
      else { return nil }
      return anchor.at
    }
    return Set(moments).sorted()
  }

  /// Why the fee `old` may not become `new` — `nil` takes it off —, or `nil` when it may.
  /// What came back for it leans on its money: a refund on the amount it took back and on the
  /// currency, money a person gave back on the amount and the currency it was worked out
  /// from. Taking a fee off follows the rule of deleting any operation
  /// (`BulkEditRule.deletion`). Another account or moment is no other money.
  nonisolated static func feeRefusal(
    _ old: TransactionEntry, becoming new: TransactionEntry?, refunds: RefundIndex,
    moneyBack: Set<UUID>
  ) -> TransferRefusal? {
    guard let new else {
      switch BulkEditRule.deletion(of: [old], refunds: refunds).skipped.first?.reason {
      case .hasRefunds: return .feeRefunded
      case .closedByReimbursement: return .feeMoneyBack
      default:
        return old.parts.contains { refunds.refunded(part: $0.id).raw > 0 } ? .feeRefunded : nil
      }
    }
    let currencyMoved = old.transaction.currency != new.transaction.currency
    let edited = Dictionary(new.parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for part in old.parts {
      let now = edited[part.id]
      let refunded = refunds.refunded(part: part.id)
      if refunded.raw > 0, currencyMoved || (now?.amountE4 ?? .zero) < refunded {
        return .feeRefunded
      }
      let cameBack = moneyBack.contains(part.id) || part.reimbursementStatus == .returned
      if cameBack, currencyMoved || now?.amountE4 != part.amountE4 {
        return .feeMoneyBack
      }
    }
    return nil
  }

  /// The category of fees the owner put into the archive, to be brought back when the next
  /// fee finds no live one: the one the fees were written to and remembered, while it is an
  /// ordinary expense category under a live parent; `nil` otherwise.
  nonisolated static func archivedFeeCategory(
    categories: [CoreKit.Category], remembered: UUID?
  ) -> CoreKit.Category? {
    let tree = CategoryTree(categories)
    guard let remembered, let category = categories.first(where: { $0.id == remembered }),
      category.archived, category.kind == .expense, tree.systemRole(of: category.id) == nil,
      !(tree.parent(of: category.id)?.archived ?? false)
    else { return nil }
    return category
  }

  /// Why deleting each of `transfers` is refused as `dataset` has them, by the transfer's id;
  /// a transfer that may go is not among them. A transfer of an account in the archive stays,
  /// as for an edit: taken away, it would move money on an account no total counts, and
  /// «Всего» would change out of nothing — «Вернуть» the account first. A fee something came
  /// back for keeps its transfer. The screen of an account and the lists of operations ask
  /// this one question. `refunds` are the live refunds of `dataset` (`refunds(in:)`).
  nonisolated static func deletionRefusals(
    of transfers: [Transfer], in dataset: Dataset, refunds: RefundIndex
  ) -> [UUID: TransferRefusal] {
    guard !transfers.isEmpty else { return [:] }
    let archived = Set(dataset.paymentMethods.filter(\.archived).map(\.id))
    let keys = Set(transfers.map { TransferRules.feeKey(of: $0.id) })
    // The live fee of each transfer, the first one as `fee(of:in:)` finds it.
    var fees: [String: TransactionEntry] = [:]
    for entry in dataset.entries where !entry.transaction.isDeleted {
      guard let key = entry.transaction.externalId, keys.contains(key), fees[key] == nil
      else { continue }
      fees[key] = entry
    }
    let moneyBack = fees.isEmpty ? [] : Self.moneyBack(in: dataset)
    var refusals: [UUID: TransferRefusal] = [:]
    for transfer in transfers {
      if archived.contains(transfer.fromAccountId) || archived.contains(transfer.toAccountId) {
        refusals[transfer.id] = .issue(.archivedAccount)
      } else if let fee = fees[TransferRules.feeKey(of: transfer.id)],
        let refusal = Self.feeRefusal(fee, becoming: nil, refunds: refunds, moneyBack: moneyBack)
      {
        refusals[transfer.id] = refusal
      }
    }
    return refusals
  }

  /// The parts some live money back was linked to.
  nonisolated static func moneyBack(in dataset: Dataset) -> Set<UUID> {
    let live = Set(dataset.entries.filter { !$0.transaction.isDeleted }.map(\.id))
    return Set(dataset.links.filter { live.contains($0.reimbursementTxId) }.map(\.partId))
  }

  /// What the live refunds of `dataset` took back from each part.
  nonisolated static func refunds(in dataset: Dataset) -> RefundIndex {
    RefundIndex(entries: dataset.entries, debts: dataset.debtsById)
  }

  // MARK: Writing, one step of ⌘Z each

  /// Saves a new transfer or an edit of `form.previous`, with its fee, in one write.
  @discardableResult
  func save(_ form: TransferForm, occurredAt: Date, books: AccountBooks) -> TransferOutcome {
    switch change(for: form, occurredAt: occurredAt, books: books) {
    case .failure(let refusal):
      return .refused(refusal)
    case .success(let change):
      guard store.apply(change) else { return .failed }
      let shape = [
        LogPair("exchange", .flag(form.isExchange)), LogPair("fee", .flag(form.fee.raw > 0)),
      ]
      if form.previous == nil {
        AppLog.info("transfer.created", .db, "a transfer was written", shape)
      } else {
        AppLog.info("transfer.edited", .db, "a transfer was edited", shape)
      }
      return .done
    }
  }

  /// Deletes a transfer and its fee, in one write — the fee as the books have it now, not as a
  /// list shows it: a list a moment behind would leave the fee with nothing to belong to.
  @discardableResult
  func delete(_ transfer: Transfer) async -> TransferOutcome {
    guard let books = await books() else { return .failed }
    return delete(transfer, books: books)
  }

  /// Deletes a transfer and its fee as `books` has them, in one write — unless
  /// `deletionRefusals` keeps it, which is then refused in words.
  @discardableResult
  func delete(_ transfer: Transfer, books: AccountBooks) -> TransferOutcome {
    let dataset = books.dataset
    guard let stored = dataset.transfers.first(where: { $0.id == transfer.id }) else {
      return .refused(.notFound)
    }
    let refusals = Self.deletionRefusals(
      of: [stored], in: dataset, refunds: Self.refunds(in: dataset))
    if let refusal = refusals[stored.id] { return .refused(refusal) }
    let fee = Self.fee(of: transfer.id, in: dataset.entries)
    let change = PlanningChange(
      delete: PlanningRowIDs(transfers: [transfer.id]),
      softDeleted: fee.map { [$0.id] } ?? [], at: environment.now())
    guard store.apply(change) else { return .failed }
    AppLog.info(
      "transfer.deleted", .db, "a transfer was deleted",
      [LogPair("fee", .flag(fee != nil))])
    return .done
  }

  /// The one write a form comes to: the transfer, and its fee created, rewritten or deleted —
  /// with the category of the fees made and remembered at the first one.
  func change(
    for form: TransferForm, occurredAt: Date, books: AccountBooks
  ) -> Result<PlanningChange, TransferRefusal> {
    guard form.fromAccountId != nil, form.fromCurrency != nil else { return .failure(.noFrom) }
    guard form.toAccountId != nil, form.toCurrency != nil else { return .failure(.noTo) }
    let now = environment.now()
    let dataset = books.dataset
    if let previous = form.previous,
      !dataset.transfers.contains(where: { $0.id == previous.id })
    {
      return .failure(.notFound)
    }
    guard
      let transfer = form.transfer(
        id: form.previous?.id ?? UUID(), occurredAt: occurredAt, now: now)
    else { return .failure(.noFrom) }
    if let issue = TransferRules.validate(transfer, accounts: dataset.paymentMethods) {
      return .failure(.issue(issue))
    }
    guard form.fee.raw >= 0 else { return .failure(.negativeFee) }

    var rows = PlanningRows(transfers: [transfer])
    var change = PlanningChange(upsert: rows, at: now)
    let old = form.previous.flatMap { Self.fee(of: $0.id, in: dataset.entries) }
    let refunds = old == nil ? RefundIndex.empty : Self.refunds(in: dataset)
    let moneyBack = old == nil ? [] : Self.moneyBack(in: dataset)
    guard form.fee.raw > 0 else {
      if let old {
        if let refusal = Self.feeRefusal(old, becoming: nil, refunds: refunds, moneyBack: moneyBack)
        {
          return .failure(refusal)
        }
        change.softDeleted = [old.id]
      }
      return .success(change)
    }
    if let old {
      return rewriteFee(old, to: form.fee, of: transfer, refunds: refunds, moneyBack: moneyBack)
        .map { rewritten in
          change.rewritten = rewritten.map { [$0] } ?? []
          return change
        }
    }

    // A new fee: in the category of fees, made and remembered at the first one.
    let categories = store.categories()
    var tree = CategoryTree(categories)
    let categoryId: UUID
    let stored = try? environment.settings?.string(AccountSettings.transferFeeCategoryKey)
    let remembered = stored.flatMap {
      UUID(uuidString: $0.trimmingCharacters(in: .whitespaces))
    }
    switch TransferRules.feeCategory(categories: categories, remembered: remembered) {
    case .existing(let id):
      categoryId = id
    case .create(let nameKey, let parent, let quality):
      let name = environment.language(nameKey, table: AccountText.table)
      if var back = Self.archivedFeeCategory(categories: categories, remembered: remembered) {
        // The owner put the category of fees into the archive: a category the app still
        // writes into is brought back — in the same step of ⌘Z — rather than made again.
        back.archived = false
        rows.categories = [back]
        tree = CategoryTree(categories.map { $0.id == back.id ? back : $0 })
        categoryId = back.id
      } else {
        let siblings = categories.filter { $0.parentId == parent && $0.kind == .expense }
        let made = CoreKit.Category(
          parentId: parent, kind: .expense, name: name,
          sort: (siblings.map(\.sort).max() ?? 0) + 1, quality: quality)
        rows.categories = [made]
        tree = CategoryTree(categories + [made])
        categoryId = made.id
      }
    }
    if remembered != categoryId {
      change.settings = [AccountSettings.transferFeeCategoryKey: categoryId.uuidString]
    }
    change.upsert = rows

    var draft = TransferRules.feeDraft(
      transfer: transfer, fee: form.fee, categoryId: categoryId, tree: tree)
    environment.applyRate(to: &draft)
    let convert = environment.rublesConverter(for: draft)
    do {
      var entry = try draft.materialize(now: now, rublesConverter: convert)
      entry.transaction.externalId = TransferRules.feeKey(of: transfer.id)
      change.created = [entry]
    } catch {
      return .failure(.rateMissing(draft.currency))
    }
    return .success(change)
  }

  /// The fee `old` following its transfer: the amount the form gives it, the account, the
  /// currency and the moment of the transfer — and nothing else. Its parts, their notes,
  /// categories, ratings and whom they were for stay as the owner left them; a fee of several
  /// parts shares the new amount out as the old one was. `nil` when nothing it is made of
  /// moved: the fee is not written at all.
  private func rewriteFee(
    _ old: TransactionEntry, to amount: AmountE4, of transfer: Transfer, refunds: RefundIndex,
    moneyBack: Set<UUID>
  ) -> Result<TransactionEntry?, TransferRefusal> {
    let before = old.transaction
    if before.amountE4 == amount, before.currency == transfer.fromCurrency,
      before.paymentMethodId == transfer.fromAccountId, before.occurredAt == transfer.occurredAt
    {
      return .success(nil)
    }
    var draft = TransactionDraft(entry: old)
    if draft.currency != transfer.fromCurrency {
      // Another currency takes the rate of its own.
      draft.currency = transfer.fromCurrency
      draft.rate = nil
      draft.rateDate = nil
      draft.rateSource = nil
      draft.rateProvisional = false
    }
    draft.occurredAt = transfer.occurredAt
    draft.paymentMethodId = transfer.fromAccountId
    // The account holds the currency the money left in: nothing to say about a charge.
    draft.accountCurrency = nil
    draft.accountAmount = nil
    if draft.amount != amount {
      let shares = amount.allocated(
        proportionallyTo: draft.parts.map(\.amount), outOf: draft.amount)
      for index in draft.parts.indices {
        draft.parts[index].amount = shares[index]
        draft.parts[index].amountExpression = nil
      }
      draft.amount = amount
      draft.amountExpression = nil
    }
    environment.applyRate(to: &draft)
    let convert = environment.rublesConverter(for: draft)
    let now = environment.now()
    let rewritten: TransactionEntry
    do {
      rewritten = try draft.materialize(updating: old, now: now, rublesConverter: convert)
    } catch {
      return .failure(.rateMissing(draft.currency))
    }
    if let refusal = Self.feeRefusal(
      old, becoming: rewritten, refunds: refunds, moneyBack: moneyBack)
    {
      return .failure(refusal)
    }
    return .success(rewritten)
  }
}

/// The words of transfers.
@MainActor
enum TransferText {
  /// What the refusal says.
  static func message(_ refusal: TransferRefusal, _ environment: AppEnvironment) -> String {
    func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }
    switch refusal {
    case .noFrom: return t("transfer.refusal.noFrom")
    case .noTo: return t("transfer.refusal.noTo")
    case .negativeFee: return t("transfer.refusal.negativeFee")
    case .notFound: return t("account.refusal.notFound")
    case .feeRefunded: return t("transfer.refusal.feeRefunded")
    case .feeMoneyBack: return t("transfer.refusal.feeMoneyBack")
    case .rateMissing(let currency):
      return environment.format(
        "transfer.refusal.rateMissing", table: AccountText.table, currency.code)
    case .issue(let issue):
      switch issue {
      case .sameKey: return t("transfer.refusal.sameKey")
      case .currencyNotHeld(let side):
        return t(side == .from ? "transfer.refusal.fromCurrency" : "transfer.refusal.toCurrency")
      case .archivedAccount: return t("transfer.refusal.archived")
      case .amountsDiffer: return t("transfer.refusal.amountsDiffer")
      case .notPositive: return t("transfer.refusal.notPositive")
      }
    }
  }

  /// The rate an exchange implies, the stronger currency counted as one unit: «1 € = 98.5 ₽»,
  /// never «1 ₽ = 0.0102 €».
  static func rate(
    sent: AmountE4, from: CurrencyCode, received: AmountE4, to: CurrencyCode,
    money: MoneyFormatter
  ) -> String? {
    guard from != to, sent.raw > 0, received.raw > 0 else { return nil }
    let perSent = received.decimal / sent.decimal
    if perSent >= 1 {
      return
        "1\u{00A0}\(money.symbol(for: from)) = \(money.rate(perSent))\u{00A0}\(money.symbol(for: to))"
    }
    let perReceived = sent.decimal / received.decimal
    return
      "1\u{00A0}\(money.symbol(for: to)) = \(money.rate(perReceived))\u{00A0}\(money.symbol(for: from))"
  }
}
