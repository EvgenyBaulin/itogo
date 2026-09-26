import AppCore
import SwiftUI

/// «Сверка»: how much money is on every account, in each of its currencies, against what the
/// books expect. Every live account × each of its currencies is one row, the expected balance
/// already in its field: the owner fixes only the rows that differ, and zero is a count like
/// any other. Each row's difference is in its own currency — a rate that moved is never a
/// difference. The first count of a balance is its starting point: nothing is compared and
/// nothing is written but the count.
///
/// «Записать разницу» writes every difference as an operation in «Сверка» on its account, in
/// its currency; «Сохранить без записи» keeps only the counts. Either is one write and one
/// step of ⌘Z. The groups left out of the summary are counted too — their money is real — and
/// their rows say they are apart.
struct ReconcileSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWindow) private var openWindow

  /// What the owner typed, by balance: a row he never touched counts its expected balance.
  @State private var typed: [BalanceKey: AmountE4] = [:]
  /// Fields the owner emptied: a starting point left empty is not counted.
  @State private var blank: Set<BalanceKey> = []
  /// The moment the expected balances are counted for, and the reconciliation is stamped with.
  @State private var now = Date()
  @State private var showsHistory = false
  /// The key of why the last press saved nothing, until the next one: the sheet is never left
  /// open without a word.
  @State private var failure: String?

  var body: some View {
    let snapshot = compute.snapshot
    let rows =
      snapshot.map {
        Self.rows(
          of: $0, at: now, first: environment.focusedAccountId,
          locale: environment.language.locale)
      } ?? []
    let counted = Self.counted(rows: rows, typed: typed, blank: blank)
    let differs = Self.differs(rows: rows, counted: counted ?? [:])
    let noRate = Self.differencesWithoutRate(
      rows: rows, counted: counted ?? [:], rubPerUnit: snapshot?.context.rubPerUnit ?? [:])
    let notHeld = Self.differencesNotHeld(rows: rows, counted: counted ?? [:])
    let comparesAny = rows.contains { $0.expected != nil }
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("reconcile.title")).font(.headline)
      Text(verbatim: t("reconcile.accountsQuestion"))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      if let snapshot {
        if rows.isEmpty {
          Text(verbatim: t("reconcile.noAccounts")).foregroundStyle(.secondary)
        } else {
          ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
              ForEach(rows, id: \.key) { row in
                rowView(row, snapshot: snapshot, counted: counted)
              }
            }
            .padding(.vertical, 2)
          }
          .frame(maxHeight: 340)
        }
      } else {
        // Without the data the sheet cannot tell a starting point from a count to compare:
        // nothing is saved until it is here.
        ComputedBlock(
          title: nil, state: compute.states.data, style: .plain,
          retry: { compute.retry(ComputeStep.data) }
        ) { _ in EmptyView() }
      }
      if counted == nil {
        notice("reconcile.negative", symbol: "exclamationmark.triangle")
      }
      if !noRate.isEmpty {
        notice(
          environment.format(
            "reconcile.noRateForDifference", table: "Planning",
            noRate.map(\.code).joined(separator: ", ")),
          symbol: "exclamationmark.triangle", translated: true)
      }
      if !notHeld.isEmpty, let snapshot {
        notice(
          environment.format(
            "reconcile.notHeldDifference", table: "Planning",
            notHeld.map { "\(accountName($0.key.accountId, snapshot)) \($0.key.currency.code)" }
              .joined(separator: ", ")),
          symbol: "exclamationmark.triangle", translated: true)
      }
      DisclosureGroup(isExpanded: $showsHistory) {
        history(snapshot)
      } label: {
        Text(verbatim: t("reconcile.history"))
      }
      if let failure {
        Label {
          Text(verbatim: t(failure)).fixedSize(horizontal: false, vertical: true)
        } icon: {
          Image(systemName: "exclamationmark.octagon")
        }
        .font(.caption)
        .foregroundStyle(.red)
      }
      HStack {
        if let last = snapshot?.planning.lastReconciliation {
          Button(t("reconcile.findMissing")) {
            environment.pendingTransactionsRange = DayRange(last.date, environment.today)
            openWindow(id: "transactions")
          }
        }
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        let savable = snapshot != nil && !(counted ?? [:]).isEmpty
        if comparesAny {
          Button(t("reconcile.saveOnly")) { save(counted, rows, record: false) }
            .disabled(!savable)
            .modifier(DefaultAction(isDefault: !differs))
          Button(t("reconcile.record")) { save(counted, rows, record: true) }
            .disabled(!savable || !differs || !noRate.isEmpty || !notHeld.isEmpty)
            .help(t("reconcile.recordHint"))
            .modifier(DefaultAction(isDefault: differs))
        } else {
          Button(t("reconcile.saveStart")) { save(counted, rows, record: false) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!savable)
        }
      }
    }
    .padding(20)
    .frame(width: 620)
    .onAppear { now = Date() }
    // An operation entered while the sheet stands open — the coffee «Найти пропущенные…» went
    // looking for — comes with new data, and the moment moves with it: the expected balances
    // take it in, the untouched fields follow them, and what the owner typed stays.
    .onChange(of: compute.generation) { _, _ in now = Date() }
  }

  // MARK: Rows

  @ViewBuilder
  private func rowView(
    _ row: ReconcileRow, snapshot: DataSnapshot, counted: [BalanceKey: AmountE4]?
  ) -> some View {
    let currency = row.key.currency
    let name = accountName(row.key.accountId, snapshot)
    GridRow(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: name).lineLimit(1)
        if !row.isInSummary {
          Label {
            Text(verbatim: t("reconcile.notInSummary"))
          } icon: {
            Image(systemName: "eye.slash")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        if let note = Self.note(for: row, accounts: snapshot.dataset.paymentMethods) {
          Text(verbatim: t(note))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(minWidth: 150, alignment: .leading)
      Text(verbatim: currency.code)
        .monospacedDigit()
        .foregroundStyle(.secondary)
      if let expected = row.expected {
        Text(verbatim: environment.money.exact(expected, currency: currency))
          .monospacedDigit()
          .foregroundStyle(.secondary)
          .help(t("reconcile.expectedHint"))
      } else {
        Label {
          Text(verbatim: t("reconcile.startingPoint"))
        } icon: {
          Image(systemName: "flag")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(t("reconcile.first"))
      }
      AmountField(
        amount: Binding(
          get: { typed[row.key] ?? row.expected ?? .zero },
          set: { typed[row.key] = $0 }),
        onTyped: { amount, text in
          Self.typing(amount, text: text, row: row, typed: &typed, blank: &blank)
        }
      )
      .frame(width: 130)
      .accessibilityLabel(Text(verbatim: "\(name) \(currency.code)"))
      // A row that differs stands out by its sign and weight; a matching one stays quiet.
      let differs = Self.differs(rows: [row], counted: counted ?? [:])
      Text(verbatim: differenceText(row, counted: counted))
        .monospacedDigit()
        .fontWeight(differs ? .semibold : .regular)
        .foregroundStyle(differs ? .primary : .secondary)
        .frame(minWidth: 100, alignment: .trailing)
        // Read on its own, the figure says whose difference it is.
        .accessibilityLabel(
          Text(verbatim: "\(t("reconcile.difference")) \(name) \(currency.code)")
        )
        .accessibilityValue(Text(verbatim: differenceText(row, counted: counted)))
    }
  }

  /// «−500.00 ₽», «+10.00 $», «0 ₽» — in the row's currency; «—» for a starting point or a row
  /// not counted.
  private func differenceText(_ row: ReconcileRow, counted: [BalanceKey: AmountE4]?) -> String {
    guard let expected = row.expected, let actual = counted?[row.key] else { return "—" }
    return Self.signed(actual - expected, currency: row.key.currency, money: environment.money)
  }

  private func accountName(_ id: UUID, _ snapshot: DataSnapshot) -> String {
    snapshot.dataset.paymentMethods.first { $0.id == id }?.name ?? "—"
  }

  private func notice(_ text: String, symbol: String, translated: Bool = false) -> some View {
    Label {
      Text(verbatim: translated ? text : t(text)).fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: symbol)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  // MARK: The rules of the sheet

  /// The rows of the sheet at `t0` (`AccountReconciliation.rows`), those of `first` — the
  /// account whose screen asked for the sheet — on top.
  static func rows(
    of snapshot: DataSnapshot, at t0: Date, first: UUID?, locale: Locale
  ) -> [ReconcileRow] {
    let rows = AccountReconciliation.rows(
      accounts: snapshot.dataset.paymentMethods, groups: snapshot.dataset.accountGroups,
      balances: snapshot.planning.accounts.balances, at: t0, locale: locale)
    guard let first else { return rows }
    return rows.filter { $0.key.accountId == first } + rows.filter { $0.key.accountId != first }
  }

  /// What the sheet counts, by balance: what the owner typed, else the expected balance he
  /// left as it is. A starting point left empty is not counted. Nil while a typed amount is
  /// below zero: money on an account is not.
  static func counted(
    rows: [ReconcileRow], typed: [BalanceKey: AmountE4], blank: Set<BalanceKey>
  ) -> [BalanceKey: AmountE4]? {
    var counted: [BalanceKey: AmountE4] = [:]
    for row in rows {
      if let value = typed[row.key] {
        if value.isNegative { return nil }
        if row.expected == nil, blank.contains(row.key) { continue }
        counted[row.key] = value
      } else if let expected = row.expected {
        counted[row.key] = expected
      }
    }
    return counted
  }

  /// What one field tells the sheet: the amount typed, with the text behind it.
  ///
  /// The field writes the amount it is given into itself — the expected balance when the sheet
  /// opens, a new one when new data comes — and tells that text like any other. It is not the
  /// owner counting: taken for a count, it would pin an untouched row to the expectation of the
  /// moment the field appeared, and the coffee «Найти пропущенные…» went looking for would
  /// show up as a difference nobody typed — or an expected balance below zero would stop the
  /// sheet from saving. So a row nobody typed in yet takes no text that is just what it shows
  /// by itself.
  static func typing(
    _ amount: AmountE4, text: String, row: ReconcileRow,
    typed: inout [BalanceKey: AmountE4], blank: inout Set<BalanceKey>
  ) {
    if typed[row.key] == nil, text == AmountField.text(for: row.expected ?? .zero) { return }
    typed[row.key] = amount
    if text.trimmingCharacters(in: .whitespaces).isEmpty {
      blank.insert(row.key)
    } else {
      blank.remove(row.key)
    }
  }

  /// Why a row is not an ordinary one, as a key of the Planning table: an archived account
  /// still holding money, or money in a currency the account does not list. Nil for the rest.
  static func note(for row: ReconcileRow, accounts: [PaymentMethod]) -> String? {
    guard !row.isHeld else { return nil }
    let account = accounts.first { $0.id == row.key.accountId }
    return account.map { !$0.archived } == true ? "reconcile.notHeld" : "reconcile.archived"
  }

  /// Rows that differ where no operation can be written: an archived account, or a currency
  /// the account does not hold — an operation there has no account to be taken from. Their
  /// difference is not recorded; «Сохранить без записи» still keeps the count.
  static func differencesNotHeld(
    rows: [ReconcileRow], counted: [BalanceKey: AmountE4]
  ) -> [ReconcileRow] {
    rows.filter { row in
      guard !row.isHeld, let expected = row.expected, let actual = counted[row.key] else {
        return false
      }
      return actual != expected
    }
  }

  /// Some compared row counts another amount than expected.
  static func differs(rows: [ReconcileRow], counted: [BalanceKey: AmountE4]) -> Bool {
    rows.contains { row in
      guard let expected = row.expected, let actual = counted[row.key] else { return false }
      return actual != expected
    }
  }

  /// Currencies of rows with a difference that has no rate today: that difference cannot be
  /// written in rubles, so «Записать разницу» waits for the rate.
  static func differencesWithoutRate(
    rows: [ReconcileRow], counted: [BalanceKey: AmountE4], rubPerUnit: [CurrencyCode: Decimal]
  ) -> [CurrencyCode] {
    var missing: Set<CurrencyCode> = []
    for row in rows where row.key.currency != .rub && rubPerUnit[row.key.currency] == nil {
      guard let expected = row.expected, let actual = counted[row.key], actual != expected
      else { continue }
      missing.insert(row.key.currency)
    }
    return missing.sorted { $0.code < $1.code }
  }

  /// A difference with its sign. Exact in the sheet: a reconciliation shows kopecks, and the
  /// operation it writes has them too. `rounded` — whole units — where amounts are shown to
  /// the ruble, as on the Overview card.
  static func signed(
    _ amount: AmountE4, currency: CurrencyCode, money: MoneyFormatter, rounded: Bool = false
  ) -> String {
    guard !rounded else { return money.signedRounded(amount, currency: currency) }
    return (amount.isNegative ? "−" : amount.isZero ? "" : "+")
      + money.exact(amount.magnitude, currency: currency)
  }

  // MARK: History

  private func history(_ snapshot: DataSnapshot?) -> some View {
    let book = snapshot?.dataset.planning
    let all = Array((book?.reconciliations ?? []).reversed())
    return VStack(alignment: .leading, spacing: 4) {
      if all.isEmpty { Text(verbatim: t("reconcile.historyNone")).foregroundStyle(.secondary) }
      ForEach(all, id: \.id) { item in
        HStack(alignment: .firstTextBaseline) {
          Text(verbatim: environment.dates.longDay(item.date))
          Text(verbatim: t("reconcile.kind.\(item.kind.rawValue)"))
            .foregroundStyle(.secondary)
          Spacer(minLength: 8)
          Text(verbatim: summary(of: item, snapshot))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
        }
        .font(.caption)
      }
    }
  }

  /// What one reconciliation found, as it found it: the differences of its balances, each in
  /// its currency; a reconciliation of one total gives its difference in rubles.
  private func summary(of item: Reconciliation, _ snapshot: DataSnapshot?) -> String {
    guard item.kind != .total else {
      return item.differenceE4.map { Self.signed($0, currency: .rub, money: environment.money) }
        ?? t("reconcile.startingPoint")
    }
    let balances = (snapshot?.dataset.planning.reconciledBalances ?? [])
      .filter { $0.reconciliationId == item.id }
    return Self.differencesText(
      balances, names: { id in snapshot.map { accountName(id, $0) } ?? "—" },
      money: environment.money, language: environment.language)
  }

  /// What the balances of one reconciliation found.
  enum Findings: Equatable {
    /// Nothing was compared: every balance was counted for the first time.
    case startingPoint
    /// Every compared balance was what the books expected.
    case noDifference
    /// The balances that differed, with their differences.
    case differences([ReconciledBalance])
  }

  static func findings(_ balances: [ReconciledBalance]) -> Findings {
    let compared = balances.filter { !$0.isStartingPoint }
    guard !compared.isEmpty else { return .startingPoint }
    let differing = compared.filter { !($0.differenceE4 ?? .zero).isZero }
    return differing.isEmpty ? .noDifference : .differences(differing)
  }

  /// «Т-Банк −500.00 ₽ · Freedom +10.00 $», each difference in its currency — «−500 ₽»
  /// with `rounded`; «без расхождений» when every compared balance matched, «точка отсчёта»
  /// when nothing was compared.
  static func differencesText(
    _ balances: [ReconciledBalance], names: (UUID) -> String, money: MoneyFormatter,
    language: AppLanguage, rounded: Bool = false
  ) -> String {
    switch findings(balances) {
    case .startingPoint: language("reconcile.startingPoint", table: "Planning")
    case .noDifference: language("reconcile.noDifference", table: "Planning")
    case .differences(let differing):
      differing.map {
        "\(names($0.accountId)) "
          + signed(
            $0.differenceE4 ?? .zero, currency: $0.currency, money: money, rounded: rounded)
      }.joined(separator: " · ")
    }
  }

  // MARK: Saving

  private func save(
    _ counted: [BalanceKey: AmountE4]?, _ rows: [ReconcileRow], record: Bool
  ) {
    guard let counted, let dependencies else { return }
    if let failure = Self.save(
      counted: counted, rows: rows, record: record, at: now, dependencies: dependencies)
    {
      self.failure = failure
      return
    }
    environment.showsReconciliation = false
    dismiss()
  }

  /// Writes the reconciliation: nil when it landed, or the key of what the sheet says when it
  /// did not. A refused save keeps the sheet open with the money counted in it — and says so,
  /// rather than leave a button that seems to do nothing (the journal has `reconcile.failed`).
  static func save(
    counted: [BalanceKey: AmountE4], rows: [ReconcileRow], record: Bool, at t0: Date,
    dependencies: AppDependencies
  ) -> String? {
    PlanningActions(dependencies).reconcile(
      counted: counted, rows: rows, recordDifference: record, at: t0)?.rawValue
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// The button Return presses: prominent, and the default action of the sheet.
private struct DefaultAction: ViewModifier {
  let isDefault: Bool

  func body(content: Content) -> some View {
    if isDefault {
      content.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
    } else {
      content
    }
  }
}
