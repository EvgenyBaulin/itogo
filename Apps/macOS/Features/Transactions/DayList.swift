import AppCore
import AppKit
import SwiftUI

/// Operations by day, newest first: the days of Overview. Income and expenses are listed
/// separately inside a day, and the header of the day says what it comes to. The Transactions
/// window shows the whole history in a table of its own (`TransactionsTable`).
///
/// Selection is the list's own: click, ⌘-click and ⇧-click are native, ⌘A is the system
/// «Select All», Esc clears it. A double click and the context menu go through
/// `contextMenu(forSelectionType:)`, because a tap gesture on a row fights the selection.
/// Only operations can be selected: the rows that head a day's income and expenses, and
/// whatever `header` puts on top, carry no tag.
///
/// The list owns no sheets and no dialogs. Rows are redrawn on every change of the data,
/// and a sheet hung on a row goes away with it — so everything the menu opens hangs on the
/// root of the screen instead.
struct DayList<Header: View, MenuItems: View>: View {
  @Dependency(\.environment) private var environment

  let groups: [TransactionsStore.DayGroup]
  @Binding var selection: Set<UUID>
  /// The ledger of the data: a row without a description is named by its category, and a
  /// row shows the quality the rules give its parts, as the table of Transactions does.
  var ledger: Ledger?
  /// Shown as a row under `header` when there is nothing to list.
  var emptyText: String?
  /// The list has no data yet: the state of the step that brings it is shown instead of the
  /// days.
  var waiting: ListWaiting?
  @ViewBuilder var header: () -> Header
  @ViewBuilder var menu: (Set<UUID>) -> MenuItems
  var primaryAction: (Set<UUID>) -> Void
  /// ⌫ on the selection. `nil` leaves the key alone.
  var deleteAction: ((Set<UUID>) -> Void)?

  var body: some View {
    List(selection: $selection) { rows }
      .listStyle(.inset)
      .contextMenu(forSelectionType: UUID.self, menu: menu, primaryAction: primaryAction)
      .onExitCommand { selection = [] }
      // ⌘A is the system «Select All», and a focused list answers it by itself. This is the
      // way back when it does not reach the list: the same thing, done by hand.
      .onCommand(#selector(NSResponder.selectAll(_:))) {
        selection = Set(groups.flatMap(\.entries).map(\.id))
      }
      .onDeleteCommand {
        guard let deleteAction, !selection.isEmpty else { return }
        deleteAction(selection)
      }
  }

  @ViewBuilder
  private var rows: some View {
    header()
    if let waiting {
      ComputedBlock(waiting: waiting.state, retry: waiting.retry)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .listRowSeparator(.hidden)
        .selectionDisabled()
    } else if groups.isEmpty, let emptyText {
      emptyRow(emptyText)
    }
    ForEach(groups) { group in
      Section {
        if !group.income.isEmpty {
          sideHeader("transactions.income")
          ForEach(group.income) { entry in
            row(entry)
          }
        }
        if !group.expenses.isEmpty {
          sideHeader("transactions.expenses")
          ForEach(group.expenses) { entry in
            row(entry)
          }
        }
      } header: {
        DayHeader(day: group.day, totals: group.totals)
      }
    }
  }

  private func row(_ entry: TransactionEntry) -> some View {
    TransactionRow(
      entry: entry, names: ledger?.tree ?? CategoryTree(),
      quality: TransactionListing.quality(of: entry, ledger: ledger)
    )
    .tag(entry.id)
  }

  /// «Доходы» and «Расходы» inside a day: a heading, not something to select.
  private func sideHeader(_ key: String) -> some View {
    Text(verbatim: environment.language(key, table: "Transactions"))
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.secondary)
      .listRowSeparator(.hidden)
      .selectionDisabled()
  }

  private func emptyRow(_ text: String) -> some View {
    VStack(spacing: 8) {
      Image(systemName: "list.bullet.rectangle")
        .font(.title)
        .foregroundStyle(.secondary)
      Text(verbatim: text)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 32)
    .listRowSeparator(.hidden)
    .selectionDisabled()
  }
}

/// A list that has no data yet: what the step that brings it is doing, and how to run it
/// again when it failed.
struct ListWaiting {
  let state: BlockState<Never>
  let retry: () -> Void
}

/// The title of a day and what it comes to. A section of the Transactions table names its
/// side of the day too: «Сегодня · Доходы».
struct DayHeader: View {
  @Dependency(\.environment) private var environment
  let day: DateOnly
  var sideKey: String?
  let totals: RowTotals

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(verbatim: title)
        .font(.headline)
      Spacer()
      RowTotalsLine(totals: totals)
    }
  }

  private var title: String {
    let day = environment.dates.dayTitle(
      day,
      today: environment.today,
      language: AppLanguageStrings(
        today: environment.language("common.today"),
        yesterday: environment.language("common.yesterday")))
    guard let sideKey else { return day }
    return "\(day) · \(environment.language(sideKey, table: "Transactions"))"
  }
}

/// The groups of `RowTotals` that are not empty, each with its caption, rounded to whole
/// rubles: the header of a day, the selection bar and the delete confirmation say it the
/// same way.
struct RowTotalsLine: View {
  @Dependency(\.environment) private var environment
  let totals: RowTotals

  var body: some View {
    HStack(spacing: 12) {
      ForEach(totals.nonEmptyGroups, id: \.self) { group in
        HStack(spacing: 4) {
          Text(verbatim: RowTotalsText.caption(group, language: environment.language))
            .foregroundStyle(.secondary)
          Text(verbatim: environment.money.rounded(totals[group]))
            .monospacedDigit()
        }
      }
    }
    .font(.subheadline)
  }
}

/// The same line as plain text, for places that take a string — the text of a dialog.
@MainActor
enum RowTotalsText {
  static func caption(_ group: RowTotals.Group, language: AppLanguage) -> String {
    language("totals.\(group.rawValue)", table: "Transactions")
  }

  static func line(_ totals: RowTotals, environment: AppEnvironment) -> String {
    totals.nonEmptyGroups
      .map {
        "\(caption($0, language: environment.language)) \(environment.money.rounded(totals[$0]))"
      }
      .joined(separator: " · ")
  }
}

struct TransactionRow: View {
  @Dependency(\.environment) private var environment

  let entry: TransactionEntry
  let names: CategoryTree
  /// The quality of its parts; «several» when they disagree (`TransactionListing.quality`).
  let quality: RowCell<Quality>

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: Palette.kindSymbol(entry.transaction.kind))
        .foregroundStyle(entry.transaction.kind == .income ? .green : .secondary)
      VStack(alignment: .leading, spacing: 2) {
        // A row typed without a description is named by its category, in the secondary
        // style, rather than by a dash nobody can tell apart (first live run, 18 September).
        RowTitleText(title: RowTitle.of(entry, tree: names))
        HStack(spacing: 8) {
          Text(verbatim: environment.dates.time(entry.transaction.occurredAt))
          if let expression = entry.transaction.amountExpr {
            Text(verbatim: expression)
          }
          if entry.transaction.kind == .reimbursement {
            // Listed among the income because money came in, but it is not income: it
            // closes what I paid for somebody else.
            Text(
              verbatim: environment.language(
                "transactions.moneyBackNotIncome", table: "Transactions"))
          }
          if entry.isSplit {
            Label {
              Text(verbatim: "\(entry.parts.count)")
            } icon: {
              Image(systemName: "square.split.2x1")
            }
          }
          if let status = TransactionListing.owedMark(of: entry) {
            let words = [
              environment.language("entry.paidForSomeone", table: "Entry"),
              environment.language(Palette.reimbursementKey(status)),
            ]
            .joined(separator: " · ")
            Image(systemName: Palette.reimbursementSymbol(status))
              .help(Text(verbatim: words))
              .accessibilityLabel(Text(verbatim: words))
          }
          switch quality {
          case .none:
            EmptyView()
          case .several:
            Text(verbatim: environment.language("transactions.several", table: "Transactions"))
          case .one(let quality):
            QualityTag(
              quality: quality,
              title: environment.language(Palette.qualityKey(quality)))
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Text(
        verbatim: environment.money.exact(
          entry.transaction.amountE4, currency: entry.transaction.currency)
      )
      .font(.body.monospacedDigit())
    }
    .padding(.vertical, 2)
    .contentShape(.rect)
    // One element for VoiceOver, which also hears where the money is filed: a row with a
    // description does not show its category. The UI test reads the same value.
    .accessibilityElement(children: .combine)
    .accessibilityValue(Text(verbatim: categories))
    .accessibilityIdentifier("operation.\(entry.transaction.kind.rawValue)")
  }

  /// The categories of the parts, each once: «Food out › Cafes; Groceries».
  private var categories: String {
    var seen: [String] = []
    for part in entry.parts {
      guard let path = CategoryPath(part.categoryId, tree: names)?.text, !seen.contains(path)
      else { continue }
      seen.append(path)
    }
    return seen.joined(separator: "; ")
  }
}
