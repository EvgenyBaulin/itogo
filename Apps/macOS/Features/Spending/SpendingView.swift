import AppCore
import SwiftUI
import TipKit

/// «Траты»: every operation of the main window in one list by day, newest first — what Overview
/// listed under its cards before it kept the cards alone. ↓ in the entry line comes here, onto
/// the newest row. The search looks through the whole history by words of the operation, its
/// category and its place; without it the list shows the last two months, as Overview did. The
/// rows are the ones of Overview; a double click edits, the menu acts on the selection — the
/// Transactions window (⌘⇧T) stays the full table with its filters.
struct SpendingView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  let actions: OperationActions
  @State private var search = ""

  private func t(_ key: String) -> String { environment.language(key, table: "Overview") }

  var body: some View {
    @Bindable var actions = actions
    let groups = shownGroups
    DayList(
      groups: groups,
      selection: $actions.selection,
      ledger: compute.snapshot?.ledger,
      emptyText: emptyText,
      waiting: waiting,
      header: { searchField },
      menu: { ids in
        BulkMenuItems(ids: ids, actions: actions, offersEdit: true)
      },
      primaryAction: { ids in actions.edit(ids, store: store) },
      deleteAction: { ids in actions.requestDeletion(of: ids, store: store) }
    )
    .onAppear {
      followData()
      GuideStore.shared.report(GuideEvent.spendingOpened)
    }
    .onChange(of: compute.generation) { _, _ in followData() }
    .onChange(of: search) { _, text in
      if !text.trimmingCharacters(in: .whitespaces).isEmpty {
        GuideStore.shared.report(GuideEvent.searched)
      }
      actions.keep(only: Set(groups.flatMap(\.selectableIds)))
    }
  }

  private var searchField: some View {
    TextField(text: $search, prompt: Text(verbatim: t("spending.search.prompt"))) {
      Text(verbatim: t("spending.search"))
    }
    .textFieldStyle(.roundedBorder)
    .labelsHidden()
    .padding(.vertical, 6)
    .listRowSeparator(.hidden)
    .selectionDisabled()
    .accessibilityIdentifier("transactions.search")
    .guideTarget("transactions.search")
    .popoverTip(SpendingSearchTip())
  }

  /// The last two months, or everything the search finds.
  private var shownGroups: [TransactionsStore.DayGroup] {
    guard let snapshot = compute.snapshot else { return [] }
    let query = search.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return snapshot.recentGroups }
    let ledger = snapshot.ledger
    let dataset = snapshot.dataset
    let names = SpendingSearch.Names(dataset)
    let found = dataset.entries.filter { entry in
      !entry.transaction.isDeleted && SpendingSearch.matches(entry, query: query, names: names)
    }
    return TransactionsStore.group(
      found, calendar: environment.calendar, debts: dataset.debtsById,
      refunds: ledger.refundIndex)
  }

  private var waiting: ListWaiting? {
    guard compute.snapshot == nil, let state = compute.states.data.waiting else { return nil }
    return ListWaiting(state: state) { compute.retry(ComputeStep.data) }
  }

  private var emptyText: String? {
    guard let snapshot = compute.snapshot else { return nil }
    if !search.trimmingCharacters(in: .whitespaces).isEmpty { return t("spending.search.nothing") }
    return OverviewView.emptyLine(for: snapshot).map {
      environment.language($0.key, table: $0.table)
    }
  }

  private func followData() {
    guard let snapshot = compute.snapshot else { return }
    actions.reloadDictionaries(from: snapshot.dataset)
    actions.keep(only: Set(shownGroups.flatMap(\.selectableIds)))
  }
}

/// The search of «Траты»: every word of the query is somewhere in the operation — its
/// description, the notes of its parts, the names of their categories or its place —, case and
/// «ё» aside.
enum SpendingSearch {
  struct Names {
    let categories: [UUID: String]
    let places: [UUID: String]

    init(_ dataset: Dataset) {
      categories = Dictionary(
        dataset.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
      places = Dictionary(
        dataset.places.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    init(categories: [UUID: String] = [:], places: [UUID: String] = [:]) {
      self.categories = categories
      self.places = places
    }
  }

  static func matches(_ entry: TransactionEntry, query: String, names: Names) -> Bool {
    var texts: [String] = [entry.transaction.note ?? ""]
    texts += entry.parts.map { $0.note ?? "" }
    texts += entry.parts.compactMap { $0.categoryId.flatMap { names.categories[$0] } }
    if let place = entry.transaction.placeId.flatMap({ names.places[$0] }) { texts.append(place) }
    let haystack = NameKey.fold(texts.joined(separator: " "))
    return query.split(separator: " ").allSatisfy { haystack.contains(NameKey.fold(String($0))) }
  }
}
