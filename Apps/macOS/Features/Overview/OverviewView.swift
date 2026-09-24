import AppCore
import SwiftUI

/// The month so far and the operations by day. The cards and the days come from the
/// calculation pipeline (`ComputeStore`): nothing here reads the database, and nothing here
/// counts — every figure is the core's, only put into words.
///
/// The whole screen is one list: its first row is the grid of cards with the «coming later»
/// line and the status line under it, which cannot be selected, and the days follow. The
/// selection, the edit sheet, the reimbursement sheet and the bulk menu live in `actions`,
/// which the window presents from its root.
struct OverviewView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  let actions: OperationActions

  var body: some View {
    @Bindable var actions = actions
    DayList(
      groups: compute.snapshot?.recentGroups ?? [],
      selection: $actions.selection,
      ledger: compute.snapshot?.ledger,
      emptyText: emptyText,
      waiting: waiting,
      header: { OverviewHeader(actions: actions) },
      menu: { ids in
        BulkMenuItems(ids: ids, actions: actions, offersEdit: true)
      },
      primaryAction: { ids in actions.edit(ids, store: store) },
      deleteAction: { ids in actions.requestDeletion(of: ids, store: store) }
    )
    .onAppear(perform: followData)
    // Every change of the data, not only one that adds or removes a day: the dictionaries
    // of the bulk menu follow it, and the selection keeps only what is still listed.
    .onChange(of: compute.generation) { _, _ in followData() }
  }

  /// Until the first data arrives the days show the state of the data step; after that they
  /// always show the data the store has — during a full run and after a failed reload too.
  private var waiting: ListWaiting? {
    guard compute.snapshot == nil, let state = compute.states.data.waiting else { return nil }
    return ListWaiting(state: state) { compute.retry(ComputeStep.data) }
  }

  private var emptyText: String? {
    Self.emptyLine(for: compute.snapshot).map { environment.language($0.key, table: $0.table) }
  }

  /// The line under the cards when no day is listed, as a key and its table: an empty book
  /// asks for the first operation in the floating entry line at the bottom of the window; a
  /// book whose operations are all older than two months points to where they are. Nothing
  /// until the first data arrives — the list shows the state of the data step then.
  static func emptyLine(for snapshot: DataSnapshot?) -> (key: String, table: String)? {
    guard let snapshot else { return nil }
    return snapshot.dataset.entries.isEmpty
      ? ("transactions.empty", "Transactions") : ("overview.noRecent", "Overview")
  }

  private func followData() {
    guard let snapshot = compute.snapshot else { return }
    actions.reloadDictionaries(from: snapshot.dataset)
    actions.keep(only: snapshot.recentIds)
  }
}

/// The first row of the list: the grid of cards and the status of the recalculation right
/// under them — at the end of two months of days nobody would see it, and the bottom of the
/// window belongs to the entry bar. The line of what comes later is gone: there is nothing
/// left to announce.
private struct OverviewHeader: View {
  @Dependency(\.environment) private var environment
  let actions: OperationActions
  @State private var width: CGFloat = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      grid
      RecomputeStatusLine()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: {
      width = $0
    }
    .padding(.vertical, 8)
    .listRowSeparator(.hidden)
    .selectionDisabled()
  }

  /// Three columns on a wide list, two on a middling one, one on a narrow one. The cards of
  /// a row share its height: the grid is laid out at its natural height, and every card
  /// then fills the row it stands in.
  private var grid: some View {
    Grid(horizontalSpacing: 12, verticalSpacing: 12) {
      ForEach(OverviewCard.rows(columns: OverviewCard.columns(forWidth: width)), id: \.self) {
        row in
        GridRow {
          ForEach(row, id: \.self) { card in
            OverviewCardView(card: card, actions: actions)
          }
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}
