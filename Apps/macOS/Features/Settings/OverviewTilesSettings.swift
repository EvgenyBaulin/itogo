import AppCore
import SwiftUI

/// Settings → «Оформление» → «Плитки обзора»: which tiles Overview shows, at most twelve, and in
/// what order. The tiles shown come first, in their order, each with «Выше» and «Ниже»; the rest
/// follow in the order of the catalog, unticked. A thirteenth tile cannot be ticked — the box is
/// grey and the footer says why — and the last tile cannot be unticked. A preference of the
/// owner's, like the theme: kept in `UserDefaults`, carried by the transfer archive, not a step
/// of ⌘Z.
struct OverviewTilesSection: View {
  @Dependency(\.environment) private var environment

  var body: some View {
    let shown = environment.overviewTiles
    Section {
      ForEach(OverviewTilesActions.rows(shown), id: \.self) { tile in
        row(tile, isShown: shown.contains(tile))
      }
    } header: {
      Text(verbatim: t("settings.tiles"))
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
    .accessibilityIdentifier("settings.tiles")
  }

  /// A tile: its box, its name and, while it is shown, «Выше» and «Ниже».
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
      Spacer()
      if isShown {
        Button {
          OverviewTilesActions.move(environment, tile, by: -1)
        } label: {
          Image(systemName: "chevron.up")
        }
        .buttonStyle(.borderless)
        .disabled(!OverviewTilesActions.canMove(environment, tile, by: -1))
        .help(t("settings.entry.moveUp"))
        .accessibilityLabel(Text(verbatim: t("settings.entry.moveUp")))
        Button {
          OverviewTilesActions.move(environment, tile, by: 1)
        } label: {
          Image(systemName: "chevron.down")
        }
        .buttonStyle(.borderless)
        .disabled(!OverviewTilesActions.canMove(environment, tile, by: 1))
        .help(t("settings.entry.moveDown"))
        .accessibilityLabel(Text(verbatim: t("settings.entry.moveDown")))
      }
    }
    .accessibilityIdentifier("settings.tiles.\(tile.rawValue)")
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
    shown + OverviewTile.allCases.filter { !shown.contains($0) }
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

  /// A drag of the tiles shown (`onMove`).
  static func move(_ environment: AppEnvironment, from source: IndexSet, to destination: Int) {
    environment.overviewTiles = OverviewTiles.moving(
      environment.overviewTiles, from: source, to: destination)
  }

  /// «Выше» (`by: -1`) or «Ниже» (`by: 1`).
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

  /// «Как было»: the twelve cards of 1.2 in their order.
  static func reset(_ environment: AppEnvironment) {
    environment.overviewTiles = OverviewTiles.standard
  }
}
