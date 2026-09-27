import AppCore
import SwiftUI

/// What «Карты» of an account's screen shows: its live cards in the order of the lists, and the
/// archived ones apart.
struct AccountCardsModel: Equatable {
  struct Card: Equatable, Identifiable {
    var card: PaymentCard
    /// The other names in one line: «виртуалка, virt».
    var otherNames: String?
    /// How many cashback rules the card holds.
    var rules: Int
    var id: UUID { card.id }
  }

  var live: [Card]
  var archived: [Card]

  init(accountId: UUID, cards: [PaymentCard], rules: [CashbackRule], locale: Locale) {
    let counts = Dictionary(grouping: rules.compactMap(\.cardId), by: { $0 }).mapValues(\.count)
    func card(_ card: PaymentCard) -> Card {
      Card(
        card: card, otherNames: card.aliases.isEmpty ? nil : card.aliases.joined(separator: ", "),
        rules: counts[card.id] ?? 0)
    }
    let own = cards.filter { $0.accountId == accountId }
      .sorted { CardRules.precedes($0, $1, locale: locale) }
    live = own.filter { !$0.archived }.map(card)
    archived = own.filter(\.archived).map(card)
  }
}

/// «Карты» of an account's screen: each live card with its other names and a menu — «Изменить…»,
/// «Кэшбэк…», «В архив», «Удалить…» —, «Добавить карту…», and the archived cards behind «В архиве:
/// N» with «Вернуть». Every action is one step of ⌘Z.
struct AccountCardsBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  let accountId: UUID

  @State private var sheet: Sheet?
  @State private var deleting: PaymentCard?
  @State private var refusal: CardRefusal?
  @State private var failed = false

  enum Sheet: Identifiable {
    case edit(PaymentCard?)
    case rules(CashbackHolder)

    var id: String {
      switch self {
      case .edit(let card): "card.\(card?.id.uuidString ?? "new")"
      case .rules(let holder): "rules.\(holder)"
      }
    }
  }

  private var actions: CardActions { CardActions(environment: environment, store: store) }
  private func t(_ key: String) -> String { environment.language(key, table: CardText.table) }

  private var model: AccountCardsModel {
    AccountCardsModel(
      accountId: accountId, cards: compute.snapshot?.dataset.cards ?? [],
      rules: compute.snapshot?.dataset.cashbackRules ?? [], locale: environment.language.locale)
  }

  var body: some View {
    let model = self.model
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(verbatim: t("card.section.title")).font(.headline)
        Spacer()
        Button {
          sheet = .edit(nil)
        } label: {
          Label {
            Text(verbatim: t("card.add"))
          } icon: {
            Image(systemName: "plus")
          }
        }
        .accessibilityIdentifier("account.cards.add")
      }
      if model.live.isEmpty {
        Text(verbatim: t("card.none")).foregroundStyle(.secondary)
      }
      ForEach(model.live) { item in
        row(item)
      }
      if !model.archived.isEmpty {
        DisclosureGroup {
          ForEach(model.archived) { item in
            HStack {
              Image(systemName: "creditcard").foregroundStyle(.secondary)
                .accessibilityHidden(true)
              Text(verbatim: item.card.name).foregroundStyle(.secondary)
              Spacer()
              Button(t("card.restore")) { run(actions.restore(item.id)) }
            }
          }
        } label: {
          Text(
            verbatim: environment.format(
              "card.archivedCount", table: CardText.table, counts: model.archived.count))
        }
      }
      if let refusal { CardRefusalNote(refusal: refusal) }
    }
    .contentCard()
    .sheet(item: $sheet) { sheet in
      content(sheet).handingOver(dependencies)
    }
    .confirmationDialog(
      deleting.map {
        environment.format("card.delete.title", table: CardText.table, $0.name)
      } ?? "",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      Button(environment.language("action.delete"), role: .destructive) {
        if let card = deleting { run(actions.delete(card.id)) }
        deleting = nil
      }
      Button(environment.language("action.cancel"), role: .cancel) { deleting = nil }
    } message: {
      Text(verbatim: t("card.delete.message"))
    }
    .refusedWriteAlert($failed, environment)
  }

  private func row(_ item: AccountCardsModel.Card) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: "creditcard")
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: item.card.name)
        Text(
          verbatim: [
            item.otherNames,
            environment.format("card.caption", table: CardText.table, counts: item.rules),
          ].compactMap { $0 }.joined(separator: " · ")
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Menu {
        Button(environment.language("action.edit")) { sheet = .edit(item.card) }
        Button(t("card.cashback")) { sheet = .rules(.card(item.id)) }
        Button(t("card.archive")) { run(actions.archive(item.id)) }
        Button(t("card.delete"), role: .destructive) { deleting = item.card }
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
      .accessibilityLabel(Text(verbatim: SettingsRowMenu.label(item.card.name, environment)))
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func content(_ sheet: Sheet) -> some View {
    switch sheet {
    case .edit(let card):
      CardEditor(previous: card, accountId: accountId) { _ in self.sheet = nil }
    case .rules(let holder):
      CashbackRulesSheet(accountId: accountId, holder: holder) { self.sheet = nil }
    }
  }

  private func run(_ outcome: CardActionOutcome) {
    switch outcome {
    case .done: refusal = nil
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
  }
}
