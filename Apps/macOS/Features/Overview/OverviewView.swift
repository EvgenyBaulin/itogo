import AppCore
import SwiftUI

/// The month so far, as tiles. The cards come from the calculation pipeline (`ComputeStore`):
/// nothing here reads the database, and nothing here counts — every figure is the core's, only
/// put into words. The operations by day are «Траты» of the sidebar (`SpendingView`); ↓ in the
/// entry line goes there. The sheets the cards open live in `actions`, which the window presents
/// from its root.
struct OverviewView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  let actions: OperationActions

  var body: some View {
    ScrollView {
      OverviewHeader(actions: actions)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
    .onAppear(perform: followData)
    // Every change of the data: the dictionaries of the menus the cards open follow it.
    .onChange(of: compute.generation) { _, _ in followData() }
  }

  /// The line of «Траты» when no day is listed, as a key and its table: an empty book asks for
  /// the first operation in the floating entry line at the bottom of the window; a book whose
  /// operations are all older than two months points to where they are. Nothing until the
  /// first data arrives — the list shows the state of the data step then.
  static func emptyLine(for snapshot: DataSnapshot?) -> (key: String, table: String)? {
    guard let snapshot else { return nil }
    return snapshot.dataset.entries.isEmpty
      ? ("transactions.empty", "Transactions") : ("overview.noRecent", "Overview")
  }

  private func followData() {
    guard let snapshot = compute.snapshot else { return }
    actions.reloadDictionaries(from: snapshot.dataset)
  }
}

/// The grid of cards and the status of the recalculation right under them — the bottom of the
/// window belongs to the entry bar.
///
/// The way back to the setup of the accounts stands above the grid, the full width of it,
/// and only while the setup is put off: it is no cell of the grid, so once the setup is done
/// no empty row is left behind.
///
/// Above everything, «Последняя запись»: when the owner last wrote something down says whether
/// the figures under it are up to date, so it comes before them — the bottom of the grid is
/// often out of view.
private struct OverviewHeader: View {
  @Dependency(\.environment) private var environment
  let actions: OperationActions
  @State private var width: CGFloat = 0

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      LastRecordLine()
      if AccountsSetupCard.shows(setup: environment.accountSetup) {
        AccountsSetupCard()
      }
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
      ForEach(
        OverviewCard.rows(
          environment.overviewTiles, columns: OverviewCard.columns(forWidth: width)),
        id: \.self
      ) { row in
        GridRow {
          ForEach(row, id: \.self) { tile in
            OverviewCardView(tile: tile, actions: actions)
          }
        }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }
}
