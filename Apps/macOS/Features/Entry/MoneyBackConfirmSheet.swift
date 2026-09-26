import AppCore
import AppDatabase
import SwiftUI

/// Money back typed in the entry line — «возврат денег 1700 от Ани» — as the confirmation opens
/// with it: the draft of the line, in its currency, on its account.
struct MoneyBackPrefill: Identifiable, Equatable {
  let id = UUID()
  var draft: TransactionDraft

  /// Whom the line or the panel named, if anyone.
  var personId: UUID? { draft.parts.first?.forPersonId }
}

/// Money back worked out before anything is written: the operation as it goes in, and how the
/// money spreads over what the person owes (`MoneyBack.plan`) — oldest part first, a part it
/// covers only partly waiting for the rest, money over everything owed income in «Доплаты» —
/// all in the currency the money came in, at its own rate.
struct MoneyBackConfirmation {
  /// Why the money back cannot be worked out yet.
  enum Problem: Error, Equatable {
    /// Nobody is named: money back is money from a person.
    case noPerson
    /// A foreign amount with no rate and no figure in rubles for the account.
    case rateMissing
  }

  /// The money back as it will be written: kind, amount, currency, rubles, account, person.
  let entry: TransactionEntry
  let plan: MoneyBackPlan
  /// What the person owes, oldest first, as read when the confirmation was made.
  let owed: [OwedPart]
  /// Parts «за другого» that name nobody are waiting — kept from before a part had to name
  /// its debtor. They may be this person's, so the money is not called income while they wait.
  var unnamedPartsWait = false

  var person: UUID? { entry.parts.first?.forPersonId }

  /// `draft` is the money back of the line: its person in the first part, its account and,
  /// when the account does not hold the currency, what the account received. The rate of a
  /// foreign amount is laid from `rates` the way the save lays it, unless it was typed.
  static func make(
    draft: TransactionDraft, owed: [OwedPart], debts: [Debt], rates: RateTable,
    calendar: CalendarContext, id: UUID = UUID(), now: Date = Date()
  ) throws -> MoneyBackConfirmation {
    guard let person = draft.parts.first?.forPersonId else { throw Problem.noPerson }
    var money = draft
    money.kind = .reimbursement
    money.parts = [PartDraft(amount: draft.amount, forPersonId: person)]
    // What the account received is a figure with its currency, or nothing at all.
    if money.accountAmount == nil { money.accountCurrency = nil }
    AppEnvironment.applyRate(to: &money, from: rates, calendar: calendar)
    let rate = money.rate
    let currency = money.currency
    let entry = try money.materialize(
      id: id, now: now,
      rublesConverter: { amount in
        guard currency != .rub else { return amount }
        guard let rate, rate > 0 else { throw Problem.rateMissing }
        return try AmountE4(decimal: amount.decimal * rate)
      })
    let transaction = entry.transaction
    let theirs = owed.filter { $0.debtorPersonId == person }
      .sorted(by: MyExpensesRule.oldestFirst)
    // A person who owes on an open debt does not owe nothing, whatever the debt's currency:
    // the money is its repayment, never income. One kept in another currency is repaid in its
    // payment form (`repaymentForm`), since the line cannot write rubles on a dollar debt.
    let plan = MoneyBack.plan(
      received: transaction.amountE4, currency: transaction.currency,
      receivedRub: transaction.amountRubE4,
      rateProvisional: transaction.currency != .rub && transaction.rateProvisional
        && transaction.rateSource != .manual,
      person: person, owed: theirs, openDebts: debts)
    var confirmation = MoneyBackConfirmation(entry: entry, plan: plan, owed: theirs)
    confirmation.unnamedPartsWait = owed.contains { $0.debtorPersonId == nil }
    return confirmation
  }

  /// What recording it writes: the money back, a link for every part the money reached, the
  /// parts it settles, and the surplus — income in «Доплаты», in the money back's currency and
  /// on its account. Nothing when the plan refuses.
  func recording(
    setting: ReimbursementRecording.Setting, now: Date = Date()
  ) throws -> (
    outcome: ReimbursementOutcome, reimbursement: TransactionEntry, extra: [TransactionEntry]
  )? {
    guard plan.refusal == nil else { return nil }
    let transaction = entry.transaction
    let outcome = MoneyBack.outcome(
      plan, reimbursementTxId: entry.id, accountId: transaction.paymentMethodId)
    var extra: [TransactionEntry] = []
    if let surplus = outcome.surplus {
      // The rate the money itself came at — its rubles over its amount, as the plan took it.
      let rate =
        transaction.amountE4.isZero
        ? nil
        : DecimalMath.round(
          transaction.amountRubE4.decimal / transaction.amountE4.decimal, scale: 6)
      extra.append(
        try ReimbursementRecording.surplusEntry(
          surplus, of: entry.id, on: transaction.occurredAt, now: now,
          rate: rate, rateDate: transaction.rateDate, setting: setting))
    }
    return (outcome, entry, extra)
  }

  /// What the money closes and what the person still owes after it, for the one line of the
  /// sheet: the parts closed, oldest first, each with its description; the rubles still owed.
  var closedParts: [OwedPart] {
    owed.filter { plan.closes.contains($0.partId) }
  }

  var stillOwedRub: AmountE4 { AmountE4.sum(plan.stillOwed.map(\.remainingRubE4)) }

  /// Whether the money can be recorded as income instead: the person owes nothing, and no
  /// part that names nobody may be theirs.
  var offersIncome: Bool { plan.refusal == .owesNothing && !unnamedPartsWait }

  /// The payment form of the debt `debtId` a money back repays, when the line cannot write the
  /// repayment itself: the money came in another currency than the debt's (500 ₽ on a dollar
  /// debt). The form opens on the account the money came to, and the owner types there how
  /// much of the debt it repaid. `nil` when the line writes it, or the debt is gone.
  @MainActor static func repaymentForm(
    of debtId: UUID, money: Money, account: UUID?, among debts: [Debt]
  ) -> DebtSheet? {
    guard let debt = debts.first(where: { $0.id == debtId }) else { return nil }
    return DebtActions.repaymentSheetIfNeeded(of: debt, money: money, account: account)
  }

  /// What the account received when it does not hold the currency the money came in: the
  /// money at the bank's rates of its day, through rubles (`AccountRules.prefillLeg`). Nil when
  /// the account holds the currency, or a rate is missing and the figure has to be typed.
  static func prefilledLeg(
    for draft: TransactionDraft, account: PaymentMethod?, rates: RateTable,
    calendar: CalendarContext
  ) -> MoneyLeg? {
    guard let account,
      let leg = AccountRules.legCurrency(for: draft.currency, account: account)
    else { return nil }
    var rated = draft
    AppEnvironment.applyRate(to: &rated, from: rates, calendar: calendar)
    var series: [CurrencyCode: [DayRate]] = [:]
    for rate in rates.rates {
      series[rate.currency, default: []].append(DayRate(day: rate.date, perUnit: rate.perUnit))
    }
    guard
      let amount = AccountRules.prefillLeg(
        amount: draft.amount, currency: draft.currency, rate: rated.rate,
        day: calendar.day(of: draft.occurredAt), account: account,
        rates: DayRates(series: series))
    else { return MoneyLeg(currency: leg, amount: .zero) }
    return MoneyLeg(currency: leg, amount: amount)
  }
}

/// The short confirmation Enter opens for money back: from whom, how much and in which
/// currency, onto which account, and in one line what it settles — «закроет: …; останется
/// должен: …». «Вручную…» opens the per-part sheet. A person who owes nothing is refused with
/// the hint to record the money as income, or — when they owe on an open «Мне должны» debt —
/// with the offer to record it as a repayment of that debt.
struct MoneyBackConfirmSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dismiss) private var dismiss
  /// Handed to the per-part sheet, which SwiftUI lays out in a host of its own.
  @Environment(\.dependencies) private var dependencies

  let prefill: MoneyBackPrefill
  /// The person owes nothing: the line records the money, as the sheet holds it, as income.
  let recordAsIncome: (TransactionDraft) -> Void
  /// The person owes on an open debt: the line records the money, as the sheet holds it, as
  /// that debt's repayment.
  let recordAsDebtRepayment: (UUID, TransactionDraft) -> Void
  /// The money back went in: the line starts over.
  let recorded: () -> Void

  @State private var personId: UUID?
  @State private var amount: AmountE4 = .zero
  @State private var currency: CurrencyCode = .rub
  @State private var accountId: UUID?
  /// What the account received, typed from the statement; nil follows the prefill.
  @State private var typedLeg: AmountE4?
  /// A rate typed for a day the bank has not published yet, or has no rate for.
  @State private var typedRate = ""
  @State private var people: [Person] = []
  @State private var owed: [OwedPart] = []
  @State private var debts: [Debt] = []
  @State private var accounts: [PaymentMethod] = []
  @State private var rates = RateTable()
  @State private var errorKey: String?
  @State private var manual: ReimbursementPrefill?

  init(
    prefill: MoneyBackPrefill, recordAsIncome: @escaping (TransactionDraft) -> Void,
    recordAsDebtRepayment: @escaping (UUID, TransactionDraft) -> Void,
    recorded: @escaping () -> Void
  ) {
    self.prefill = prefill
    self.recordAsIncome = recordAsIncome
    self.recordAsDebtRepayment = recordAsDebtRepayment
    self.recorded = recorded
    _personId = State(initialValue: prefill.personId)
    _amount = State(initialValue: prefill.draft.amount)
    _currency = State(initialValue: prefill.draft.currency)
    _accountId = State(initialValue: prefill.draft.paymentMethodId)
    _typedLeg = State(initialValue: prefill.draft.accountAmount)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(verbatim: t("moneyBack.title"))
        .font(.headline)
      fields
      Divider()
      summary
      if let errorKey {
        Text(verbatim: t(errorKey))
          .font(.caption)
          .foregroundStyle(.red)
      }
      buttons
    }
    .padding(20)
    .frame(minWidth: 460)
    .onAppear(perform: reload)
    // The line asked the bank for the rate of the day as it opened this: once it came, the
    // data was computed again, and the money is worked out at it.
    .onChange(of: compute.generation) { _, _ in
      rates = (try? environment.rates?.table()) ?? RateTable()
    }
    .sheet(item: $manual) { prefill in
      ReimbursementSheet(prefill: prefill) {
        recorded()
        dismiss()
      }
      .handingOver(dependencies)
    }
  }

  // MARK: Fields

  private var fields: some View {
    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
      GridRow {
        label("entry.fromWhom")
        Picker(selection: $personId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(orderedPeople, id: \.id) { person in
            Text(verbatim: person.name).tag(UUID?.some(person.id))
          }
        } label: {
          Text(verbatim: t("entry.fromWhom"))
        }
        .labelsHidden()
        .accessibilityIdentifier("moneyBack.person")
      }
      GridRow {
        label("entry.amount")
        HStack(spacing: 8) {
          AmountField(amount: $amount)
            .frame(width: 140)
            .accessibilityLabel(Text(verbatim: t("entry.amount")))
            // What the account received was for the amount the line had.
            .onChange(of: amount) { _, _ in typedLeg = nil }
          Picker(selection: $currency) {
            ForEach(currencyChoices, id: \.code) { code in
              Text(verbatim: code.code).tag(code)
            }
          } label: {
            Text(verbatim: t("entry.currency"))
          }
          .labelsHidden()
          .fixedSize()
          .onChange(of: currency) { _, _ in typedLeg = nil }
        }
      }
      GridRow {
        label("entry.account.to")
        Picker(selection: $accountId) {
          ForEach(orderedAccounts, id: \.id) { account in
            Text(verbatim: account.name).tag(UUID?.some(account.id))
          }
        } label: {
          Text(verbatim: t("entry.account.to"))
        }
        .labelsHidden()
        .onChange(of: accountId) { _, _ in typedLeg = nil }
      }
      if let leg = legShown {
        GridRow {
          label("moneyBack.received")
          HStack(spacing: 8) {
            AmountField(
              amount: Binding(
                get: { typedLeg ?? leg.amount },
                set: { typedLeg = $0.isZero ? nil : $0 })
            )
            .frame(width: 140)
            .accessibilityLabel(Text(verbatim: t("moneyBack.received")))
            Text(verbatim: leg.currency.code)
              .foregroundStyle(.secondary)
          }
        }
      }
      // The bank has no rate of the day yet, or none at all: the rate is typed, or the money
      // back waits for it (Cancel keeps the line).
      if currency != .rub, needsRate || !typedRate.isEmpty {
        GridRow {
          label("entry.rate")
          TextField(text: $typedRate, prompt: Text(verbatim: "0.00")) {
            Text(verbatim: t("entry.rate"))
          }
          .labelsHidden()
          .frame(width: 140)
          .onChange(of: typedRate) { _, _ in typedLeg = nil }
        }
      }
    }
  }

  /// The money back cannot be worked out at the bank's rate: it has none, or not a final one.
  private var needsRate: Bool {
    switch confirmation {
    case .failure(.rateMissing): return true
    case .success(let confirmation): return confirmation.plan.refusal == .provisionalRate
    case .failure: return false
    }
  }

  /// The rate typed, when it is a number above zero.
  private var manualRate: Decimal? {
    let trimmed = typedRate.trimmingCharacters(in: .whitespaces)
    guard let value = DecimalMath.parse(trimmed), value > 0 else { return nil }
    return value
  }

  // MARK: Summary

  @ViewBuilder
  private var summary: some View {
    switch confirmation {
    case .success(let confirmation):
      if let refusal = confirmation.plan.refusal {
        refusalView(refusal, of: confirmation)
      } else {
        planView(confirmation)
      }
    case .failure(.noPerson):
      // Nobody picked — perhaps a name the dictionaries do not know: it can still be income.
      VStack(alignment: .leading, spacing: 8) {
        caption("moneyBack.choosePerson")
        Button(t("moneyBack.asIncome")) {
          recordAsIncome(draft)
          dismiss()
        }
      }
    case .failure(.rateMissing):
      caption("entry.error.rateMissing")
    }
  }

  private func planView(_ confirmation: MoneyBackConfirmation) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: Self.summaryLine(confirmation, words: environment.language, money: money))
        .accessibilityIdentifier("moneyBack.summary")
      if confirmation.plan.surplus.raw > 0 {
        Text(
          verbatim: environment.language.format(
            "moneyBack.surplus", table: "Entry",
            money.exact(confirmation.plan.surplus, currency: confirmation.plan.currency))
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      if !confirmation.plan.skippedProvisional.isEmpty {
        Label {
          Text(
            verbatim: environment.language.format(
              "moneyBack.skipped", table: "Entry",
              counts: confirmation.plan.skippedProvisional.count))
        } icon: {
          Image(systemName: "hourglass")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  /// «закроет: ужин, кино; останется должен: 800.00 ₽» — or «больше ничего не должен».
  static func summaryLine(
    _ confirmation: MoneyBackConfirmation, words: AppLanguage, money: MoneyFormatter
  ) -> String {
    var pieces: [String] = []
    let closed = confirmation.closedParts
    if !closed.isEmpty {
      let names = closed.map { part in
        let name = part.note ?? words("moneyBack.partWithoutNote", table: "Entry")
        return "\(name) (\(money.exact(part.remainingRubE4)))"
      }
      pieces.append(
        words.format("moneyBack.closes", table: "Entry", names.joined(separator: ", ")))
    }
    let still = confirmation.stillOwedRub
    pieces.append(
      still.raw > 0
        ? words.format("moneyBack.stillOwes", table: "Entry", money.exact(still))
        : words("moneyBack.owesNothingMore", table: "Entry"))
    return pieces.joined(separator: "; ")
  }

  @ViewBuilder
  private func refusalView(
    _ refusal: MoneyBackRefusal, of confirmation: MoneyBackConfirmation
  ) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Label {
        Text(
          verbatim: t(
            refusal == .owesNothing && !confirmation.offersIncome
              ? "moneyBack.unnamedParts" : Self.refusalKey(refusal)))
      } icon: {
        Image(systemName: "exclamationmark.triangle")
      }
      .accessibilityIdentifier("moneyBack.refusal")
      switch refusal {
      case .owesNothing:
        if confirmation.offersIncome {
          Button(t("moneyBack.asIncome")) {
            recordAsIncome(draft)
            dismiss()
          }
        }
      case .owesOnDebt(let debt):
        Button(t("moneyBack.asDebtRepayment")) {
          recordAsDebtRepayment(debt, draft)
          dismiss()
        }
      case .onlyProvisional, .provisionalRate, .provisionalPartsOwed:
        EmptyView()
      }
    }
  }

  static func refusalKey(_ refusal: MoneyBackRefusal) -> String {
    switch refusal {
    case .owesNothing: "moneyBack.owesNothing"
    case .owesOnDebt: "moneyBack.owesOnDebt"
    case .onlyProvisional: "moneyBack.onlyProvisional"
    case .provisionalRate: "moneyBack.provisionalRate"
    case .provisionalPartsOwed: "moneyBack.provisionalPartsOwed"
    }
  }

  // MARK: Buttons

  private var buttons: some View {
    HStack {
      Button(t("moneyBack.manual")) { openManual() }
        .disabled(personId == nil && owed.isEmpty)
      Spacer()
      Button(environment.language("action.cancel"), role: .cancel) { dismiss() }
      Button(t("moneyBack.record"), action: record)
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!canRecord)
    }
  }

  private var canRecord: Bool {
    guard case .success(let confirmation) = confirmation else { return false }
    return confirmation.plan.refusal == nil && amount.raw > 0
  }

  // MARK: The draft

  /// The money back as the sheet holds it now.
  private var draft: TransactionDraft {
    var draft = prefill.draft
    draft.kind = .reimbursement
    draft.amount = amount
    draft.amountExpression = nil
    draft.currency = currency
    draft.paymentMethodId = accountId
    draft.parts = [PartDraft(amount: amount, forPersonId: personId)]
    if currency != prefill.draft.currency {
      draft.rate = nil
      draft.rateDate = nil
      draft.rateSource = nil
      draft.rateProvisional = false
    }
    if currency != .rub, let rate = manualRate {
      draft.rate = rate
      draft.rateDate = environment.calendar.day(of: draft.occurredAt)
      draft.rateSource = .manual
      draft.rateProvisional = false
    }
    let leg = legShown
    draft.accountCurrency = leg?.currency
    draft.accountAmount = leg.map { typedLeg ?? $0.amount }.flatMap { $0.isZero ? nil : $0 }
    return draft
  }

  private var account: PaymentMethod? {
    accounts.first { $0.id == accountId } ?? accounts.first(where: \.isDefault)
  }

  /// «Зачислено на счёт», shown while the account does not hold the currency.
  private var legShown: MoneyLeg? {
    var bare = prefill.draft
    bare.amount = amount
    bare.currency = currency
    if currency != prefill.draft.currency { bare.rate = nil; bare.rateSource = nil }
    if currency != .rub, let rate = manualRate {
      bare.rate = rate
      bare.rateSource = .manual
      bare.rateProvisional = false
    }
    return MoneyBackConfirmation.prefilledLeg(
      for: bare, account: account, rates: rates, calendar: environment.calendar)
  }

  private var confirmation: Result<MoneyBackConfirmation, MoneyBackConfirmation.Problem> {
    do {
      return .success(
        try MoneyBackConfirmation.make(
          draft: draft, owed: owed, debts: debts, rates: rates, calendar: environment.calendar))
    } catch let problem as MoneyBackConfirmation.Problem {
      return .failure(problem)
    } catch {
      return .failure(.rateMissing)
    }
  }

  // MARK: Actions

  private func reload() {
    people = (try? environment.references?.people()) ?? []
    owed = (try? environment.transactions?.owedParts()) ?? []
    debts = (try? environment.references?.debts()) ?? []
    accounts = (try? environment.references?.paymentMethods()) ?? []
    rates = (try? environment.rates?.table()) ?? RateTable()
    if accountId == nil { accountId = accounts.first(where: \.isDefault)?.id }
    // With nobody named, the one person who owes anything is the one.
    if personId == nil {
      let debtors = Set(owed.compactMap(\.debtorPersonId))
      if debtors.count == 1 { personId = debtors.first }
    }
  }

  private func record() {
    guard case .success(let confirmation) = confirmation,
      let repository = environment.transactions
    else { return }
    do {
      guard let written = try confirmation.recording(setting: try setting(repository)) else {
        return
      }
      try repository.apply(
        written.outcome, reimbursement: written.reimbursement, extra: written.extra)
      environment.scheduleBackup()
      // Several operations and the links between them went in at once; a single undo step
      // cannot take that back, so ⌘Z is not offered rather than undoing something else.
      store.forgetUndoHistory()
      recorded()
      dismiss()
    } catch ReimbursementError.partNoLongerOwed {
      errorKey = "reimbursement.partGone"
      reload()
    } catch ReimbursementRecording.Failure.noSurchargesCategory {
      AppLog.error("reimb.noSurcharges", .db, "no Surcharges category for a surplus")
      errorKey = "reimbursement.noSurcharges"
    } catch AccountWriteError.chargeMissing {
      errorKey = "entry.error.chargeMissing"
    } catch {
      AppLog.error(
        "reimbursement.failed", .db, "a reimbursement was not recorded",
        [LogPair("error", .error(error))])
      errorKey = "reimbursement.failed"
    }
  }

  /// «Вручную…»: the per-part sheet, in rubles, with this money and this account.
  private func openManual() {
    let current = draft
    let rubles =
      (try? MoneyBackConfirmation.make(
        draft: current, owed: owed, debts: debts, rates: rates, calendar: environment.calendar))?
      .entry.transaction.amountRubE4
    var prefillDraft = current
    if personId == nil { prefillDraft.parts[0].forPersonId = nil }
    manual = ReimbursementPrefill(
      draft: prefillDraft, received: rubles ?? (currency == .rub ? amount : .zero),
      accounts: accounts)
  }

  private func setting(
    _ repository: TransactionRepository
  ) throws
    -> ReimbursementRecording.Setting
  {
    let categories = try environment.references?.categories(includeArchived: true) ?? []
    return ReimbursementRecording.Setting(
      surchargesCategoryId: try environment.references?
        .category(systemRole: .surcharges, kind: .income)?.id,
      categories: CategoryTree(categories),
      history: try repository.manualQualityHistory(),
      surplusNote: t("reimbursement.surplus"),
      shortfallNote: t("reimbursement.shortfall"))
  }

  // MARK: Pieces

  /// People who owe something first, then everyone else, each group by name.
  private var orderedPeople: [Person] {
    let debtors = Set(owed.compactMap(\.debtorPersonId))
    return people.sorted { left, right in
      let leftOwes = debtors.contains(left.id)
      let rightOwes = debtors.contains(right.id)
      if leftOwes != rightOwes { return leftOwes }
      return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }
  }

  private var orderedAccounts: [PaymentMethod] {
    let live = AccountRules.ordered(accounts, locale: environment.language.locale)
    guard let accountId, !live.contains(where: { $0.id == accountId }),
      let current = accounts.first(where: { $0.id == accountId })
    else { return live }
    return live + [current]
  }

  private var currencyChoices: [CurrencyCode] {
    var codes = environment.vocabulary.enabledCurrencies
    if !codes.contains(currency) { codes.append(currency) }
    return codes
  }

  private var money: MoneyFormatter { environment.money }

  private func label(_ key: String) -> some View {
    Text(verbatim: t(key))
      .font(.caption)
      .foregroundStyle(.secondary)
      .gridColumnAlignment(.leading)
  }

  private func caption(_ key: String) -> some View {
    Text(verbatim: t(key))
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Entry") }
}
