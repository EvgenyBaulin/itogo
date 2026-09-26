import AppCore
import SwiftUI

/// An account as the editor holds it until «Сохранить»: its name and kind, its currencies in
/// order — the first is the main one —, its group, whether it is main, its other names and
/// the balances typed for currencies never counted.
struct AccountDraft: Equatable {
  var id: UUID
  var name: String
  var kind: PaymentMethodKind
  /// The first is the main currency: an operation in a currency the account does not hold is
  /// charged in it.
  var currencies: [CurrencyCode]
  var groupId: UUID?
  var isMain: Bool
  var aliases: [String]
  /// «Остаток сейчас», as typed, by currency; an empty field counts nothing.
  var openings: [CurrencyCode: String] = [:]

  /// The fields of an account there is.
  init(_ account: PaymentMethod) {
    id = account.id
    name = account.name
    kind = account.kind
    currencies = account.currencies
    groupId = account.groupId
    isMain = account.isDefault
    aliases = account.aliases
  }

  /// A new account: a bank account in the default currency, in no group.
  init(newIn currency: CurrencyCode, kind: PaymentMethodKind = .card) {
    id = UUID()
    name = ""
    self.kind = kind
    currencies = [currency]
    groupId = nil
    isMain = false
    aliases = []
  }

  /// The account the draft saves, over `previous` so what the editor does not show — the
  /// place in the list, the archive — stays as it was.
  func account(over previous: PaymentMethod?) -> PaymentMethod {
    var account =
      previous ?? PaymentMethod(id: id, name: name)
    account.name = name
    account.kind = kind
    account.currency = currencies.first
    account.otherCurrencies = Array(currencies.dropFirst())
    account.groupId = groupId
    account.isDefault = isMain
    account.aliases = aliases
    return account
  }

  mutating func add(_ currency: CurrencyCode) {
    guard !currencies.contains(currency) else { return }
    currencies.append(currency)
  }

  /// Takes a currency off; the last one stays — an account holds at least its main currency.
  mutating func remove(_ currency: CurrencyCode) {
    guard currencies.count > 1 else { return }
    currencies.removeAll { $0 == currency }
    openings[currency] = nil
  }

  /// The currency becomes the first, the main one; the others keep their order.
  mutating func makeMain(_ currency: CurrencyCode) {
    guard let index = currencies.firstIndex(of: currency), index > 0 else { return }
    currencies.insert(currencies.remove(at: index), at: 0)
  }

  /// One place up (`by: -1`) or down (`by: 1`).
  mutating func move(_ currency: CurrencyCode, by step: Int) {
    guard let index = currencies.firstIndex(of: currency) else { return }
    let target = index + step
    guard currencies.indices.contains(target) else { return }
    currencies.swapAt(index, target)
  }

  /// The balances typed, read as amounts: an empty field is left out, a field that does not
  /// read is refused by its currency.
  func typedOpenings() -> Result<[CurrencyCode: AmountE4], AccountRefusal> {
    var result: [CurrencyCode: AmountE4] = [:]
    for currency in currencies {
      let text = (openings[currency] ?? "").trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { continue }
      // Read by the rule of every amount field: «1,500» is 1 500, «1,5» is 1.5, a formula
      // counts.
      guard let value = try? ExpressionEvaluator.evaluate(text),
        let amount = try? AmountE4(decimal: value)
      else {
        return .failure(.unreadableBalance(currency))
      }
      result[currency] = amount
    }
    return .success(result)
  }
}

/// The form of one account, new or there already: name, kind, currencies in order, group,
/// «Основной счёт», other names and, for a currency never counted, «Остаток сейчас». Shown
/// as a sheet from the settings and from the sidebar; «Сохранить» is one step of ⌘Z.
struct AccountEditor: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  /// `nil` for a new account.
  let previous: PaymentMethod?
  /// Called once the sheet is done with: the id of the account saved or brought back from the
  /// archive, `nil` when nothing was written.
  let finish: (UUID?) -> Void

  @State private var draft: AccountDraft
  @State private var books: AccountBooks?
  @State private var groups: [AccountGroup] = []
  @State private var enabled: [CurrencyCode] = []
  @State private var refusal: AccountRefusal?
  @State private var failed = false

  init(
    previous: PaymentMethod?, defaultCurrency: CurrencyCode,
    finish: @escaping (UUID?) -> Void
  ) {
    self.previous = previous
    self.finish = finish
    _draft = State(
      initialValue: previous.map(AccountDraft.init) ?? AccountDraft(newIn: defaultCurrency))
  }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  private func t(_ key: String) -> String { environment.language(key, table: "Accounts") }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t(previous == nil ? "account.editor.newTitle" : "account.editor.title"))
        .font(.headline)
      Form {
        TextField(text: $draft.name) {
          Text(verbatim: t("account.editor.name"))
        }
        .accessibilityIdentifier("account.editor.name")
        Picker(selection: $draft.kind) {
          ForEach(PaymentMethodKind.allCases, id: \.self) { kind in
            Text(verbatim: t(AccountText.kindKey(kind))).tag(kind)
          }
        } label: {
          Text(verbatim: t("account.editor.kind"))
        }
        currenciesSection
        Section {
          Picker(selection: $draft.groupId) {
            Text(verbatim: t("account.editor.noGroup")).tag(UUID?.none)
            ForEach(groupChoices, id: \.id) { group in
              Text(verbatim: AccountText.groupTitle(group, environment)).tag(UUID?.some(group.id))
            }
          } label: {
            Text(verbatim: t("account.editor.group"))
          }
          Toggle(isOn: $draft.isMain) {
            Text(verbatim: t("account.editor.main"))
          }
          .disabled(wasMain || previous?.archived == true)
        } footer: {
          Text(verbatim: t(wasMain ? "account.editor.mainStays" : "account.editor.mainHint"))
            .foregroundStyle(.secondary)
        }
        Section {
          AccountOtherNames(names: $draft.aliases)
        } header: {
          Text(verbatim: t("account.editor.otherNames"))
        } footer: {
          Text(verbatim: t("account.editor.otherNamesHint"))
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)

      if let refusal {
        AccountRefusalNote(refusal: refusal, restore: restoreFromArchive)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { finish(nil) }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save"), action: save)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(books == nil || store.isWritingInBackground)
      }
    }
    .padding(20)
    .frame(width: 480, height: 620)
    .task {
      groups = actions.groups
      enabled = actions.enabledCurrencies
      books = await actions.books()
      // Without the books nothing can be checked or saved: said, not a greyed button alone.
      if books == nil { failed = true }
    }
    .onChange(of: draft) { _, _ in refusal = nil }
    .refusedWriteAlert($failed, environment)
  }

  // MARK: Currencies

  private var currenciesSection: some View {
    Section {
      ForEach(Array(draft.currencies.enumerated()), id: \.element) { index, currency in
        currencyRow(currency, isMain: index == 0, index: index)
        if countsOpening(currency) {
          LabeledContent {
            TextField(
              text: Binding(
                get: { draft.openings[currency] ?? "" },
                set: { draft.openings[currency] = $0 })
            ) {
              // Empty means not counted — no starting point —, which is not a zero balance.
              Text(verbatim: t("account.editor.notCounted"))
            }
            .font(.body.monospacedDigit())
            .multilineTextAlignment(.trailing)
            .frame(width: 140)
            .onSubmit { settleOpening(currency) }
          } label: {
            Text(
              verbatim: environment.format(
                "account.editor.balanceNow", table: "Accounts", currency.code))
          }
        }
      }
      Menu {
        ForEach(addable, id: \.code) { currency in
          Button(currency.code) { draft.add(currency) }
        }
      } label: {
        Label {
          Text(verbatim: t("account.editor.addCurrency"))
        } icon: {
          Image(systemName: "plus")
        }
      }
      .disabled(addable.isEmpty)
    } header: {
      Text(verbatim: t("account.editor.currencies"))
    } footer: {
      Text(verbatim: t("account.editor.currenciesHint"))
        .foregroundStyle(.secondary)
    }
  }

  private func currencyRow(_ currency: CurrencyCode, isMain: Bool, index: Int) -> some View {
    let locked = hasMoney(currency)
    let unknown = locked && books?.isUnknown(key(currency)) == true
    return HStack(spacing: 8) {
      Text(verbatim: currency.code)
        .font(.body.monospaced())
      Text(verbatim: environment.money.symbol(for: currency))
        .foregroundStyle(.secondary)
      if isMain {
        Text(verbatim: t("account.editor.mainCurrency"))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      if locked {
        // Said in words, not only by a greyed button: money in this currency keeps it here —
        // or a balance nobody knows yet, which is not called money.
        Label {
          Text(
            verbatim: t(
              unknown ? "account.editor.currencyBalanceUnknown" : "account.editor.currencyHasMoney"
            ))
        } icon: {
          Image(systemName: "lock")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Menu {
        if !isMain {
          Button(t("account.editor.makeMainCurrency")) { draft.makeMain(currency) }
        }
        Button(t("account.editor.up")) { draft.move(currency, by: -1) }
          .disabled(index == 0)
        Button(t("account.editor.down")) { draft.move(currency, by: 1) }
          .disabled(index == draft.currencies.count - 1)
        Divider()
        Button(t("account.editor.removeCurrency"), role: .destructive) { draft.remove(currency) }
          .disabled(locked || draft.currencies.count == 1)
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel(Text(verbatim: t("account.editor.currencyMenu")))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
  }

  /// Currencies switched on that the account does not hold yet.
  private var addable: [CurrencyCode] {
    enabled.filter { !draft.currencies.contains($0) }
  }

  /// The groups to file it under: the live ones, and the one it is in even when archived.
  private var groupChoices: [AccountGroup] {
    groups.filter { !$0.archived || $0.id == draft.groupId }
  }

  private var wasMain: Bool { previous?.isDefault == true && previous?.archived == false }

  private func key(_ currency: CurrencyCode) -> BalanceKey {
    BalanceKey(accountId: draft.id, currency: currency)
  }

  /// Money on the account in this currency: it cannot be taken off.
  private func hasMoney(_ currency: CurrencyCode) -> Bool {
    guard previous != nil, let books else { return false }
    return books.hasMoney(key(currency))
  }

  /// A currency never counted and never moved asks for its balance now.
  private func countsOpening(_ currency: CurrencyCode) -> Bool {
    guard let books else { return false }
    return !books.balances.hasHistory(key(currency))
  }

  /// Enter writes the balance back the way the app writes amounts.
  private func settleOpening(_ currency: CurrencyCode) {
    guard let text = draft.openings[currency], let settled = AmountField.settledText(text)
    else { return }
    draft.openings[currency] = settled
  }

  // MARK: Saving

  private func save() {
    guard let books else { return }
    guard !draft.currencies.isEmpty else {
      refusal = .noCurrency
      return
    }
    let openings: [CurrencyCode: AmountE4]
    switch draft.typedOpenings() {
    case .success(let typed): openings = typed
    case .failure(let reason):
      refusal = reason
      return
    }
    let account = draft.account(over: previous)
    switch actions.save(account, previous: previous, openings: openings, books: books) {
    case .done: finish(account.id)
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
  }

  /// A new account named like one in the archive: that one comes back instead of a second
  /// account with the same name.
  private func restoreFromArchive(_ id: UUID) {
    switch actions.restore(id) {
    case .done: finish(id)
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
  }
}

/// The other names of an account, one row each with ×, and a field to add one: the entry line
/// knows the account by any of them («Т-Банк» — «тинькофф», «тинек»).
private struct AccountOtherNames: View {
  @Dependency(\.environment) private var environment
  @Binding var names: [String]
  @State private var typed = ""

  var body: some View {
    ForEach(Array(names.enumerated()), id: \.offset) { index, name in
      HStack {
        Text(verbatim: name)
        Spacer()
        Button {
          names.remove(at: index)
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
            .accessibilityLabel(
              Text(verbatim: environment.language("account.editor.removeName", table: "Accounts")))
        }
        .buttonStyle(.borderless)
      }
    }
    HStack {
      TextField(text: $typed) {
        Text(verbatim: environment.language("account.editor.newName", table: "Accounts"))
      }
      .onSubmit(add)
      Button(environment.language("action.add"), action: add)
        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
    }
  }

  private func add() {
    let name = typed.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return }
    let key = AccountActions.folded(name)
    if !names.contains(where: { AccountActions.folded($0) == key }) { names.append(name) }
    typed = ""
  }
}
