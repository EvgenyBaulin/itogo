import AppCore
import SwiftUI

/// What «Кэшбэк · <месяц>» of an account's screen shows: for each card (or the account's own
/// line) the cashback its rules promise for the month's purchases next to what was received for
/// the month, exact, per currency, and the rules that apply this month.
struct AccountCashbackModel: Equatable, Sendable {
  struct Line: Equatable, Sendable, Identifiable {
    /// `nil`: the account's own line — purchases of no card, or an account without cards.
    var cardId: UUID?
    var cardName: String?
    var expected: [Money]
    var received: [Money]
    /// The rules of the line that apply in the month: the month's first, then «always».
    var rules: [CashbackRule]
    var id: String { cardId?.uuidString ?? "account" }
  }

  var month: MonthKey
  var lines: [Line]
  /// The account's main currency: an empty side of a line is zero in it.
  var currency: CurrencyCode = .rub

  /// No rule applies and nothing was received: the block says so and offers the rules.
  var isEmpty: Bool {
    lines.allSatisfy { $0.rules.isEmpty && $0.received.isEmpty && $0.expected.isEmpty }
  }

  static func build(month: MonthKey, accountId: UUID, ledger: Ledger) -> AccountCashbackModel {
    let dataset = ledger.dataset
    let book = CashbackRuleBook(rules: dataset.cashbackRules, tree: ledger.tree)
    let cards = Dictionary(
      dataset.cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func money(_ amounts: [CurrencyCode: AmountE4]) -> [Money] {
      amounts.filter { !$0.value.isZero || amounts.count == 1 }
        .map { Money(amount: $0.value, currency: $0.key) }
        .sorted { $0.currency.code < $1.currency.code }
    }
    let lines = AccountCashbackSummary.month(month, accountId: accountId, ledger: ledger).map {
      cell in
      let holder: CashbackHolder =
        cell.holder.cardId.map(CashbackHolder.card) ?? .account(accountId)
      let rules = book.rules(of: holder).filter { $0.month == month || $0.month == nil }
        .sorted { ($0.month != nil ? 0 : 1) < ($1.month != nil ? 0 : 1) }
      return Line(
        cardId: cell.holder.cardId, cardName: cell.holder.cardId.flatMap { cards[$0]?.name },
        expected: money(cell.expected), received: money(cell.received), rules: rules)
    }
    let currency = dataset.paymentMethods.first { $0.id == accountId }?.currency ?? .rub
    return AccountCashbackModel(month: month, lines: lines, currency: currency)
  }
}

/// «Кэшбэк · Сентябрь 2026» on an account's screen, under its cards: expected is an
/// expectation, never income; what was received is income in the cashback category, by the
/// month it is for. «Правила кэшбэка…» opens the rules of the account's cards.
struct AccountCashbackBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  let accountId: UUID

  @State private var model: AccountCashbackModel?
  @State private var editsRules = false

  private func t(_ key: String) -> String { environment.language(key, table: CardText.table) }

  private var month: MonthKey { environment.today.monthKey }

  private var state: BlockState<AccountCashbackModel> {
    guard let model, model.month == month else { return .calculating }
    return .ready(model, at: environment.now())
  }

  var body: some View {
    ComputedBlock(
      title: environment.format(
        "account.screen.cashback", table: CardText.table, environment.dates.monthTitle(month)),
      state: state, retry: nil
    ) { model in
      VStack(alignment: .leading, spacing: 8) {
        if model.isEmpty {
          Text(verbatim: t("account.screen.cashbackNone")).foregroundStyle(.secondary)
        } else {
          ForEach(model.lines) { line in
            lineView(line, currency: model.currency)
          }
        }
        Button(t("cashback.rules")) { editsRules = true }
          .accessibilityIdentifier("account.cashback.rules")
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .accessibilityIdentifier("account.cashback")
    .task(id: CashbackKey(account: accountId, month: month, generation: compute.generation)) {
      guard let ledger = compute.snapshot?.ledger else { return }
      let month = self.month
      let accountId = self.accountId
      model = await Task.detached(priority: .userInitiated) {
        AccountCashbackModel.build(month: month, accountId: accountId, ledger: ledger)
      }.value
    }
    .sheet(isPresented: $editsRules) {
      CashbackRulesSheet(accountId: accountId) { editsRules = false }
        .handingOver(dependencies)
    }
  }

  private func lineView(_ line: AccountCashbackModel.Line, currency: CurrencyCode) -> some View {
    let names = Dictionary(
      (compute.snapshot?.dataset.categories ?? []).map { ($0.id, $0.name) },
      uniquingKeysWith: { first, _ in first })
    return VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Image(systemName: line.cardId == nil ? "building.columns" : "creditcard")
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(verbatim: line.cardName ?? t("account.screen.cashbackAccountLine"))
          .fontWeight(.medium)
        Spacer()
        Text(
          verbatim: environment.format(
            "account.screen.cashbackLine", table: CardText.table,
            amounts(line.expected, currency: currency), amounts(line.received, currency: currency))
        )
        .monospacedDigit()
      }
      if !line.rules.isEmpty {
        Text(
          verbatim: line.rules.map { CardText.ruleLine($0, categories: names, environment) }
            .joined(separator: " · ")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }

  /// «280.55 ₽», «100 ₸, 18.50 ₽»; nothing — zero in the account's currency, «0.00 ₸».
  private func amounts(_ values: [Money], currency: CurrencyCode) -> String {
    guard !values.isEmpty else { return environment.money.exact(.zero, currency: currency) }
    return values.map { environment.money.exact($0.amount, currency: $0.currency) }
      .joined(separator: ", ")
  }
}

private struct CashbackKey: Hashable {
  var account: UUID
  var month: MonthKey
  var generation: Int
}
