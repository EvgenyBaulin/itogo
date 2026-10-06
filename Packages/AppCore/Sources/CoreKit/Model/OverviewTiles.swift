import Foundation

/// A tile of Overview the owner can show. The raw value is what the setting `overview.tiles` and
/// the archive keep: a case is never renamed. The cases are in the order the settings list them.
public enum OverviewTile: String, CaseIterable, Sendable, Hashable, Codable {
  /// «С начала месяца»: spending, income and their difference from the 1st to today.
  case monthToDate
  /// «Топ категорий»: the largest categories of my spending this month, «Сверка» left out.
  case topCategories
  /// «Хорошие и плохие».
  case qualities
  /// «Можно отложить».
  case canSave
  /// «Прогноз расхода до конца месяца».
  case spendingForecast
  /// «Прогноз дохода до конца месяца».
  case incomeForecast
  /// «Прогноз остатка до конца месяца»: the money of the accounts in the summary at the end of
  /// the month.
  case balanceForecast
  /// «Лимиты».
  case limits
  /// «Платежи на 7 дней».
  case upcoming
  /// «Ожидаемые поступления».
  case expectedIncome
  /// «Мне должны».
  case owedToMe
  /// «Я должен».
  case iOwe
  /// «Событие».
  case event
  /// «Последняя сверка».
  case lastCount
  /// «Последняя операция».
  case lastRecord
  /// «Последняя сверка и операция», one tile for both.
  case lastCountAndRecord
  /// «Стоит посмотреть».
  case worthALook
  /// «Свободные средства».
  case freeMoney
}

/// Which tiles Overview shows and in what order, as the owner chose them, and the one rule that
/// reads the choice back. Whatever the stored text says — written by another build, carried by
/// an archive of another Mac, edited by hand — it reads as a choice the grid can show: known
/// tiles, each once, at least one and at most `maximum`.
public enum OverviewTiles {
  /// How many tiles the grid shows at most.
  public static let maximum = 12

  /// The tiles Overview had before they could be chosen, in their order: nothing moves for an
  /// owner who never opens the setting.
  public static let standard: [OverviewTile] = [
    .monthToDate, .topCategories, .qualities, .canSave, .spendingForecast, .limits, .upcoming,
    .expectedIncome, .owedToMe, .event, .lastCount, .worthALook,
  ]

  /// The choice kept as text; nothing, an empty text or one that names no known tile is the
  /// standard choice.
  public static func decode(_ stored: String?) -> [OverviewTile] {
    guard let stored else { return standard }
    let tiles = stored.split(separator: ",", omittingEmptySubsequences: true).compactMap {
      OverviewTile(rawValue: $0.trimmingCharacters(in: .whitespaces))
    }
    return sanitized(tiles)
  }

  /// The raw values in their order, joined by commas: «monthToDate,topCategories,…».
  public static func encode(_ tiles: [OverviewTile]) -> String {
    tiles.map(\.rawValue).joined(separator: ",")
  }

  /// A choice the grid can show: a tile named twice keeps its first place, the tiles past the
  /// `maximum` go, and no tile at all is the standard choice.
  public static func sanitized(_ tiles: [OverviewTile]) -> [OverviewTile] {
    var result: [OverviewTile] = []
    for tile in tiles where !result.contains(tile) && result.count < maximum {
      result.append(tile)
    }
    return result.isEmpty ? standard : result
  }

  /// Whether `tile` can be switched on: it is not shown yet and the grid has room for it.
  public static func canAdd(_ tile: OverviewTile, to tiles: [OverviewTile]) -> Bool {
    !tiles.contains(tile) && tiles.count < maximum
  }

  /// Whether `tile` can be switched off: it is shown, and it is not the last one.
  public static func canRemove(_ tile: OverviewTile, from tiles: [OverviewTile]) -> Bool {
    tiles.contains(tile) && tiles.count > 1
  }

  /// The choice with `tile` switched on, at the end; `nil` when it cannot be — a thirteenth tile
  /// is refused, not put in place of another.
  public static func adding(_ tile: OverviewTile, to tiles: [OverviewTile]) -> [OverviewTile]? {
    guard canAdd(tile, to: tiles) else { return nil }
    return tiles + [tile]
  }

  /// The choice with `tile` switched off; `nil` when it cannot be — the last tile stays.
  public static func removing(
    _ tile: OverviewTile, from tiles: [OverviewTile]
  ) -> [OverviewTile]? {
    guard canRemove(tile, from: tiles) else { return nil }
    return tiles.filter { $0 != tile }
  }

  /// The choice after rows were dragged, as a list moves them: the rows at `source` go before the
  /// row that was at `destination` — counted before they left —, or to the end. Indices outside
  /// the choice are passed over; nothing is lost.
  public static func moving(
    _ tiles: [OverviewTile], from source: IndexSet, to destination: Int
  ) -> [OverviewTile] {
    let moved = source.filter { tiles.indices.contains($0) }
    guard !moved.isEmpty else { return tiles }
    let target = min(max(destination, 0), tiles.count)
    let taken = moved.map { tiles[$0] }
    var rest: [OverviewTile] = []
    var insertion = 0
    for (index, tile) in tiles.enumerated() {
      if index == target { insertion = rest.count }
      if !moved.contains(index) { rest.append(tile) }
    }
    if target == tiles.count { insertion = rest.count }
    rest.insert(contentsOf: taken, at: insertion)
    return rest
  }

  /// The choice is the standard one: «Сбросить» has nothing to do.
  public static func isStandard(_ tiles: [OverviewTile]) -> Bool {
    tiles == standard
  }
}
