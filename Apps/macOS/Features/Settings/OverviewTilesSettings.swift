import AppCore
import SwiftUI

/// Settings → «Оформление» → «Плитки обзора»: which tiles Overview shows, at most twelve, and in
/// what order. The tiles shown come first, in their order, and are moved by dragging a row with
/// the mouse onto the row whose place it takes (`draggable` and `dropDestination`: the grouped
/// form of macOS is drawn by SwiftUI, not a table, and `onMove` would do nothing in it); VoiceOver
/// moves a tile by the actions «Выше» and «Ниже» of its row, as there are no arrows to press.
/// The rest follow in
/// the order of the catalog, unticked, and are not dragged. A thirteenth tile cannot be ticked —
/// the box is grey and the footer says why — and the last tile cannot be unticked. A preference
/// of the owner's, like the theme: kept in `UserDefaults`, carried by the transfer archive, not a
/// step of ⌘Z.
struct OverviewTilesSection: View {
  @Dependency(\.environment) private var environment
  /// The row a dragged tile is over: it is shaded where the tile will land.
  @State private var targeted: OverviewTile?

  var body: some View {
    let shown = environment.overviewTiles
    Section {
      ForEach(shown, id: \.self) { tile in
        row(tile, isShown: true)
          .background {
            if targeted == tile {
              RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            }
          }
          .draggable(OverviewTilesActions.payload(of: tile)) {
            Text(verbatim: OverviewTileText.name(of: tile, environment))
              .padding(6)
          }
          .dropDestination(for: String.self) { payloads, _ in
            guard let dragged = payloads.lazy.compactMap(OverviewTilesActions.tile).first
            else { return false }
            return OverviewTilesActions.drop(environment, dragged, onto: tile)
          } isTargeted: { isTargeted in
            if isTargeted {
              targeted = tile
            } else if targeted == tile {
              targeted = nil
            }
          }
      }
      ForEach(OverviewTilesActions.hidden(shown), id: \.self) { tile in
        row(tile, isShown: false)
      }
    } header: {
      Text(verbatim: t("settings.tiles"))
        .accessibilityIdentifier("settings.tiles")
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        Text(
          verbatim: environment.format(
            "settings.tiles.count", table: "Settings", shown.count, OverviewTiles.maximum)
        )
        .monospacedDigit()
        if shown.count >= OverviewTiles.maximum {
          Label {
            Text(verbatim: t("settings.tiles.full"))
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "info.circle")
          }
        }
        Text(verbatim: t("settings.tiles.hint"))
          .fixedSize(horizontal: false, vertical: true)
        Button(t("settings.tiles.reset")) { OverviewTilesActions.reset(environment) }
          .disabled(OverviewTiles.isStandard(shown))
      }
      .foregroundStyle(.secondary)
    }
  }

  /// A tile: its box and its name; a tile shown has a grip that says it can be dragged, and the
  /// actions «Выше» and «Ниже» for VoiceOver where the tile can go.
  private func row(_ tile: OverviewTile, isShown: Bool) -> some View {
    let name = OverviewTileText.name(of: tile, environment)
    return HStack(spacing: 8) {
      Toggle(
        isOn: Binding(
          get: { isShown },
          set: { _ in OverviewTilesActions.toggle(environment, tile) })
      ) {
        Text(verbatim: name)
      }
      .toggleStyle(.checkbox)
      .disabled(!OverviewTilesActions.canSwitch(environment, tile))
      .accessibilityIdentifier("settings.tiles.\(tile.rawValue)")
      .accessibilityActions {
        ForEach(OverviewTilesActions.moves(environment, tile), id: \.self) { step in
          Button(t(step < 0 ? "settings.entry.moveUp" : "settings.entry.moveDown")) {
            OverviewTilesActions.move(environment, tile, by: step)
          }
        }
      }
      Spacer()
      if isShown {
        Image(systemName: "line.3.horizontal")
          .foregroundStyle(.tertiary)
          .help(t("settings.tiles.drag"))
          .accessibilityHidden(true)
      }
    }
    .contentShape(Rectangle())
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }
}

/// What the section does, apart from the view so a test reads it without a window. Every change
/// is written at once (`AppEnvironment.overviewTiles`), and Overview lays its grid again.
@MainActor
enum OverviewTilesActions {
  /// The rows of the section: the tiles shown, in their order, then the others in the order of
  /// the catalog.
  static func rows(_ shown: [OverviewTile]) -> [OverviewTile] {
    shown + hidden(shown)
  }

  /// The tiles not shown, in the order of the catalog: the rows below the ones dragged.
  static func hidden(_ shown: [OverviewTile]) -> [OverviewTile] {
    OverviewTile.allCases.filter { !shown.contains($0) }
  }

  /// Whether the box of `tile` can change: a tile shown can be unticked unless it is the last,
  /// a tile not shown can be ticked while fewer than twelve are.
  static func canSwitch(_ environment: AppEnvironment, _ tile: OverviewTile) -> Bool {
    let tiles = environment.overviewTiles
    return tiles.contains(tile)
      ? OverviewTiles.canRemove(tile, from: tiles) : OverviewTiles.canAdd(tile, to: tiles)
  }

  /// Ticks or unticks `tile`; a ticked tile goes to the end. Returns whether the choice changed —
  /// a thirteenth tile and the last one are refused, and nothing is written.
  @discardableResult
  static func toggle(_ environment: AppEnvironment, _ tile: OverviewTile) -> Bool {
    let tiles = environment.overviewTiles
    let changed =
      tiles.contains(tile)
      ? OverviewTiles.removing(tile, from: tiles) : OverviewTiles.adding(tile, to: tiles)
    guard let changed else { return false }
    environment.overviewTiles = changed
    return true
  }

  /// What a dragged row carries: the tile, marked as one, so text dragged in from elsewhere is
  /// never read as a tile.
  static func payload(of tile: OverviewTile) -> String {
    payloadPrefix + tile.rawValue
  }

  /// The tile a dragged row carries; nil for anything else dropped on the list.
  static func tile(_ payload: String) -> OverviewTile? {
    guard payload.hasPrefix(payloadPrefix) else { return nil }
    return OverviewTile(rawValue: String(payload.dropFirst(payloadPrefix.count)))
  }

  private static let payloadPrefix = "itogo.overview.tile:"

  /// `tile` dropped onto the row of `target`: it takes that row's place. Returns whether the
  /// drop was taken — a tile not shown, or onto itself, moves nothing.
  @discardableResult
  static func drop(
    _ environment: AppEnvironment, _ tile: OverviewTile, onto target: OverviewTile
  ) -> Bool {
    let tiles = environment.overviewTiles
    let dropped = OverviewTiles.dropping(tile, onto: target, in: tiles)
    guard dropped != tiles else { return false }
    environment.overviewTiles = dropped
    return true
  }

  /// A move of the tiles shown by their indices, as a list hands them over.
  static func move(_ environment: AppEnvironment, from source: IndexSet, to destination: Int) {
    environment.overviewTiles = OverviewTiles.moving(
      environment.overviewTiles, from: source, to: destination)
  }

  /// «Выше» (`by: -1`) or «Ниже» (`by: 1`): the actions VoiceOver has on a row.
  static func move(_ environment: AppEnvironment, _ tile: OverviewTile, by step: Int) {
    guard canMove(environment, tile, by: step),
      let index = environment.overviewTiles.firstIndex(of: tile)
    else { return }
    move(environment, from: IndexSet(integer: index), to: step < 0 ? index - 1 : index + 2)
  }

  static func canMove(_ environment: AppEnvironment, _ tile: OverviewTile, by step: Int) -> Bool {
    guard let index = environment.overviewTiles.firstIndex(of: tile) else { return false }
    return environment.overviewTiles.indices.contains(index + step)
  }

  /// The moves VoiceOver offers on the row of `tile`, as steps: −1 for «Выше», 1 for «Ниже» —
  /// only where the tile can go; none for a tile not shown.
  static func moves(_ environment: AppEnvironment, _ tile: OverviewTile) -> [Int] {
    [-1, 1].filter { canMove(environment, tile, by: $0) }
  }

  /// «Как было»: the twelve cards of 1.2 in their order.
  static func reset(_ environment: AppEnvironment) {
    environment.overviewTiles = OverviewTiles.standard
  }
}
