import AppCore
import AppKit
import SwiftUI

/// The table of the Transactions window: a section for each side of each day, newest day
/// first, with what that side comes to in its header; a split is one row with a disclosure
/// triangle and its parts under it.
///
/// Selection is the table's own — click, ⌘-click, ⇧-click, ⌘A — and holds operations only:
/// parts cannot be selected (`selectionDisabled`), since a part is changed and deleted with
/// its operation. Esc clears the selection, ⌫ deletes it after asking. A double click and
/// the context menu go through `contextMenu(forSelectionType:)`; on a part they act on its
/// operation.
///
/// Columns are hidden and moved with the system menu of the header, and the set is kept in
/// `UserDefaults` by the window (`transactions.columns`): a setting of the window, never in
/// the database or an archive. The description and the amount cannot be hidden.
struct TransactionsTable<MenuItems: View>: View {
  @Dependency(\.environment) private var environment

  /// Handed to every cell and every day header by hand. A `Table` on macOS shows each of
  /// them in a hosting view of its own, and such a host does not always get the environment
  /// of the column above it: in the window at 900 pt, with the sidebar folded
  /// away for the inspector, the cells of DayList and of this file were drawn with the
  /// stand-in and the red badge named them (23.09; `testADoubleClickThatAlsoSelectsTheRow
  /// InANarrowWindowSettles` under the whole suite).
  let deps: AppDependencies
  let listing: TransactionListing
  @Binding var selection: Set<UUID>
  @Binding var columns: TableColumnCustomization<TransactionRowItem>
  @ViewBuilder var menu: (Set<UUID>) -> MenuItems
  var primaryAction: (Set<UUID>) -> Void
  var deleteAction: (Set<UUID>) -> Void

  var body: some View {
    Table(of: TransactionRowItem.self, selection: rowSelection, columnCustomization: $columns) {
      allColumns
    } rows: {
      allRows
    }
    .contextMenu(forSelectionType: RowID.self) { rows in
      menu(listing.owners(of: rows))
    } primaryAction: { rows in
      primaryAction(listing.owners(of: rows))
    }
    .onExitCommand { selection = [] }
    // ⌘A is the system «Select All», and a focused table answers it by itself. This is the
    // way back when it does not reach the table: every operation listed, no part.
    .onCommand(#selector(NSResponder.selectAll(_:))) { selection = listing.visibleIds }
    .onDeleteCommand {
      guard !selection.isEmpty else { return }
      deleteAction(selection)
    }
  }

  /// The table selects rows; the window keeps operations. A part never gets in: it cannot
  /// be selected anyway, and the selection bar, the menu and ⌘A count operations.
  private var rowSelection: Binding<Set<RowID>> {
    Binding(
      get: { Set(selection.map(RowID.transaction)) },
      set: { selection = TransactionListing.operations(in: $0) })
  }

  // MARK: Rows

  @TableRowBuilder<TransactionRowItem>
  private var allRows: some TableRowContent<TransactionRowItem> {
    ForEach(listing.sections) { section in
      Section {
        OutlineGroup(section.rows, children: \.parts) { item in
          TableRow(item)
            .selectionDisabled(item.isPart)
        }
      } header: {
        DayHeader(
          day: section.day,
          sideKey: section.side == .income ? "transactions.income" : "transactions.expenses",
          totals: section.totals
        )
        .appDependencies(deps)
      }
    }
  }

  // MARK: Columns
  //
  // Three groups rather than one list of nine: the type checker gives up on a single builder
  // of nine customised columns.
  //
  // The amount stands right after the description. A `Table` spreads spare
  // room over its columns, but short of room it does not always squeeze them: with the old
  // widths a window of 1120 pt kept every column at its ideal width and pushed the amount past
  // the edge, while a window opened at 820 pt squeezed them to their minimums. What does not
  // fit scrolls sideways. At the end of the row the amount was the first thing to go (the live
  // run of 19 September); after the description it stays on screen at the smallest window,
  // with the inspector open too. The ideal widths add up to the table of the default window,
  // 1120 pt with the filters at their ideal width, so there every column shows.

  @TableColumnBuilder<TransactionRowItem, Never>
  private var allColumns: some TableColumnContent<TransactionRowItem, Never> {
    leadingColumns
    middleColumns
    trailingColumns
  }

  @TableColumnBuilder<TransactionRowItem, Never>
  private var leadingColumns: some TableColumnContent<TransactionRowItem, Never> {
    TableColumn(title("time")) { item in
      Group {
        if !item.isPart {
          Text(verbatim: environment.dates.time(item.occurredAt))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      }
      .appDependencies(deps)
    }
    .width(min: TransactionColumnWidths.time, ideal: TransactionColumnWidths.time, max: 96)
    .customizationID("time")

    TableColumn(title("description")) { item in
      DescriptionCell(item: item).appDependencies(deps)
    }
    .width(min: 120, ideal: 160)
    .customizationID("description")
    .disabledCustomizationBehavior(.visibility)

    TableColumn(title("amount")) { item in
      AmountCell(item: item).appDependencies(deps)
    }
    .width(min: TransactionColumnWidths.amount, ideal: TransactionColumnWidths.amount)
    .alignment(.trailing)
    .customizationID("amount")
    .disabledCustomizationBehavior(.visibility)
  }

  @TableColumnBuilder<TransactionRowItem, Never>
  private var middleColumns: some TableColumnContent<TransactionRowItem, Never> {
    TableColumn(title("place")) { item in
      Text(verbatim: item.place ?? "").appDependencies(deps)
    }
    .width(min: 60, ideal: 80)
    .customizationID("place")

    TableColumn(title("category")) { item in
      CategoryCell(item: item).appDependencies(deps)
    }
    .width(min: 80, ideal: 120)
    .customizationID("category")

    TableColumn(title("forWhom")) { item in
      ForWhomCell(cell: item.forWhom).appDependencies(deps)
    }
    .width(min: 60, ideal: 76)
    .customizationID("forWhom")
  }

  @TableColumnBuilder<TransactionRowItem, Never>
  private var trailingColumns: some TableColumnContent<TransactionRowItem, Never> {
    TableColumn(title("event")) { item in
      NameCell(cell: item.event).appDependencies(deps)
    }
    .width(min: 60, ideal: 90)
    .customizationID("event")
    .defaultVisibility(.hidden)

    TableColumn(title("paymentMethod")) { item in
      Text(verbatim: item.paymentMethod ?? "").appDependencies(deps)
    }
    .width(min: 60, ideal: 90)
    .customizationID("paymentMethod")
    .defaultVisibility(.hidden)

    TableColumn(title("quality")) { item in
      QualityCell(cell: item.quality).appDependencies(deps)
    }
    .width(min: 60, ideal: 76)
    .customizationID("quality")
  }

  private func title(_ column: String) -> Text {
    Text(verbatim: environment.language("transactions.column.\(column)", table: "Transactions"))
  }
}

/// The widths the table cannot go below (`TransactionsTable`): the ones a fixed text needs.
enum TransactionColumnWidths {
  /// The time column: «00:00» in the monospaced digits of the body font, after the room the
  /// first column keeps in every row for the disclosure triangle of a split and the insets of
  /// the cell — `timeInset`, measured on macOS 26 with a few points to spare. At 48 pt the
  /// time read «1…» (the live run of 19 September).
  static let time: CGFloat = 64
  static let timeInset: CGFloat = 26
  /// The amount column: «1 234 567,89 ₽» or «1,234,567.89 ₽» in the monospaced digits of the
  /// body font and the insets of the cell.
  static let amount: CGFloat = 104
  static let amountInset: CGFloat = 4
}

// MARK: - Cells

/// The description, or what names the row without one; the marks of the operation beside
/// it — the parts of a split, money owed, money back that is not income — and the amount
/// as it was typed under it.
private struct DescriptionCell: View {
  @Dependency(\.environment) private var environment
  let item: TransactionRowItem

  /// What kind of row this is, so a UI test can double-click a plain operation, a split and
  /// a part of one without reading their descriptions.
  private var identifier: String {
    if item.isPart { return "transactions.row.part" }
    return item.partCount > 1 ? "transactions.row.split" : "transactions.row.single"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 6) {
        title
          .lineLimit(1)
        if item.partCount > 1 {
          Label {
            Text(verbatim: "\(item.partCount)")
          } icon: {
            Image(systemName: "square.split.2x1")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        if let mark = item.owedMark {
          let words = [
            environment.language("entry.paidForSomeone", table: "Entry"),
            environment.language(Palette.reimbursementKey(mark)),
          ]
          .joined(separator: " · ")
          Image(systemName: Palette.reimbursementSymbol(mark))
            .foregroundStyle(.secondary)
            .help(Text(verbatim: words))
            .accessibilityLabel(Text(verbatim: words))
        }
        if item.kind == .reimbursement, !item.isPart {
          // Listed among the income because money came in, but it is not income: it
          // closes what I paid for somebody else.
          Text(
            verbatim: environment.language(
              "transactions.moneyBackNotIncome", table: "Transactions")
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
      if let expression = item.expression {
        Text(verbatim: expression)
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityIdentifier(identifier)
  }

  /// A part says «part 2» when it has no note of its own: its category is in the next
  /// column already.
  @ViewBuilder
  private var title: some View {
    if let number = item.partNumber, !item.title.isNote {
      Text(
        verbatim: environment.language.format("transactions.part", table: "Transactions", number)
      )
      .foregroundStyle(.secondary)
    } else {
      RowTitleText(title: item.title)
    }
  }
}

private struct CategoryCell: View {
  @Dependency(\.environment) private var environment
  let item: TransactionRowItem

  var body: some View {
    switch item.category {
    case .one(let path):
      Text(verbatim: CategoryPathText.text(path, language: environment.language))
    case .several:
      SeveralText()
    case .none:
      // Money given back has no category; anything else without one says so.
      if item.kind != .reimbursement {
        Text(verbatim: environment.language("category.uncategorized"))
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// «For whom»: the value or the person; a part paid for somebody else carries the symbol of
/// its status and its words — «за Аню · ждёт» — never the colour alone.
private struct ForWhomCell: View {
  @Dependency(\.environment) private var environment
  let cell: RowCell<ForWhomValue>

  var body: some View {
    switch cell {
    case .none:
      EmptyView()
    case .several:
      SeveralText()
    case .one(.value(let value)):
      Text(verbatim: environment.label(for: value))
        .foregroundStyle(value == .me ? .secondary : .primary)
    case .one(.person(let name)):
      Text(verbatim: name)
    case .one(.owed(let name, let status)):
      let words = ForWhomText.owed(by: name, status, language: environment.language)
      Label {
        Text(verbatim: words)
      } icon: {
        Image(systemName: Palette.reimbursementSymbol(status))
      }
      .foregroundStyle(.secondary)
      .accessibilityLabel(Text(verbatim: words))
    }
  }
}

/// The words of a part paid for somebody else: «за Аню · ждёт».
@MainActor
enum ForWhomText {
  static func owed(
    by name: String?, _ status: ReimbursementStatus, language: AppLanguage
  )
    -> String
  {
    let who =
      name.map { language.format("transactions.paidFor", table: "Transactions", $0) }
      ?? language("entry.paidForSomeone", table: "Entry")
    return "\(who) · \(language(Palette.reimbursementKey(status)))"
  }
}

private struct NameCell: View {
  let cell: RowCell<String>

  var body: some View {
    switch cell {
    case .none: EmptyView()
    case .several: SeveralText()
    case .one(let name): Text(verbatim: name)
    }
  }
}

private struct QualityCell: View {
  @Dependency(\.environment) private var environment
  let cell: RowCell<Quality>

  var body: some View {
    switch cell {
    case .none:
      EmptyView()
    case .several:
      SeveralText()
    case .one(let quality):
      QualityTag(
        quality: quality, title: environment.language(Palette.qualityKey(quality)), font: .body)
    }
  }
}

/// The exact amount in the currency of the operation; a foreign one says what it came to in
/// rubles under it.
private struct AmountCell: View {
  @Dependency(\.environment) private var environment
  let item: TransactionRowItem

  var body: some View {
    VStack(alignment: .trailing, spacing: 1) {
      Text(verbatim: environment.money.exact(item.amount, currency: item.currency))
        .monospacedDigit()
        .foregroundStyle(item.isPart ? .secondary : .primary)
      if item.currency != .rub {
        Text(verbatim: "≈ \(environment.money.rounded(item.amountRub))")
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// «Several»: the parts of a split disagree on this cell.
private struct SeveralText: View {
  @Dependency(\.environment) private var environment

  var body: some View {
    Text(verbatim: environment.language("transactions.several", table: "Transactions"))
      .foregroundStyle(.secondary)
  }
}
