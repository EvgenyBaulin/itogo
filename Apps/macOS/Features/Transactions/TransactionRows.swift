import AppCore
import Foundation

/// What a row of the Transactions table stands for: an operation, or one part of a split
/// under it. Only operations are ever selected, changed or deleted; a part is shown so the
/// split can be read, and is changed through its operation.
enum RowID: Hashable, Sendable {
  case transaction(UUID)
  case part(UUID)
}

/// «Category › Subcategory» as the dictionary names them, root first. `archived` is set when
/// either of the two has been retired: the cell says «(archived)» after the path.
struct CategoryPath: Hashable, Sendable {
  var names: [String]
  var archived: Bool

  init(names: [String], archived: Bool = false) {
    self.names = names
    self.archived = archived
  }

  /// `nil` for a part without a category, and for an id the dictionary no longer has.
  init?(_ id: UUID?, tree: CategoryTree) {
    guard let category = tree.category(id) else { return nil }
    if let parent = tree.parent(of: category.id) {
      self.init(
        names: [parent.name, category.name], archived: parent.archived || category.archived)
    } else {
      self.init(names: [category.name], archived: category.archived)
    }
  }

  var text: String { names.joined(separator: " › ") }
}

/// What names an operation in a list. Its description when it has one; otherwise its
/// category, so a row typed as «250» with a category picked in the panel still says what
/// it is (first live run, 18 September: such rows read «—»); otherwise its kind. Only the
/// description is the owner's own words — the other two are shown in the secondary style.
enum RowTitle: Hashable, Sendable {
  case note(String)
  case category(CategoryPath)
  case kind(TransactionKind)

  static func resolve(note: String?, category: CategoryPath?, kind: TransactionKind) -> RowTitle {
    if let note = note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
      return .note(note)
    }
    if let category { return .category(category) }
    return .kind(kind)
  }

  /// A split names itself by the category of its first part that has one: that is the part
  /// the entry line and the panel fill first.
  static func of(_ entry: TransactionEntry, tree: CategoryTree) -> RowTitle {
    let category = entry.parts.lazy.compactMap { CategoryPath($0.categoryId, tree: tree) }.first
    return resolve(note: entry.transaction.note, category: category, kind: entry.transaction.kind)
  }

  /// Whether the title is the owner's own description.
  var isNote: Bool {
    if case .note = self { return true }
    return false
  }
}

/// A cell of an operation that may differ between its parts: nothing, one value, or
/// «several» when the parts of a split disagree.
enum RowCell<Value: Hashable & Sendable>: Hashable, Sendable {
  case none
  case one(Value)
  case several

  /// One value when every part has the same, «several» otherwise; `none` when there are no
  /// values at all or all of them are missing.
  static func of(_ values: [Value?]) -> RowCell {
    guard let first = values.first else { return .none }
    guard values.allSatisfy({ $0 == first }) else { return .several }
    return first.map(RowCell.one) ?? .none
  }
}

/// «For whom» of a part: a value, a person it was for, or — for a part of a purchase paid
/// for somebody else — who owes it and what became of the money.
enum ForWhomValue: Hashable, Sendable {
  case value(ForWhom)
  case person(String)
  case owed(by: String?, ReimbursementStatus)
}

/// One row of the table: an operation, or a part of a split under it. Everything a cell
/// shows is resolved here, off the main thread, from the data of the pipeline; the words
/// that depend on the language — kinds, «several», «(archived)», the status of money owed —
/// are put in by the cells.
struct TransactionRowItem: Identifiable, Hashable, Sendable {
  let id: RowID
  /// The operation of the row: itself, or the one the part belongs to.
  let transactionId: UUID
  let kind: TransactionKind
  let occurredAt: Date
  /// The description of an operation, the note of a part.
  let note: String?
  /// What names the row when it has no description of its own.
  let title: RowTitle
  let expression: String?
  /// The position of a part inside its operation, from 1; `nil` for an operation.
  let partNumber: Int?
  let place: String?
  let category: RowCell<CategoryPath>
  let forWhom: RowCell<ForWhomValue>
  let event: RowCell<String>
  let paymentMethod: String?
  let quality: RowCell<Quality>
  let amount: AmountE4
  let currency: CurrencyCode
  let amountRub: AmountE4
  /// How many parts the operation has; 1 for a part and for an operation that is not split.
  let partCount: Int
  /// The mark of an operation with parts paid for somebody else: waiting while any of them
  /// waits, then returned, then written off. Purchases only.
  let owedMark: ReimbursementStatus?
  /// The parts of a split, shown under it; `nil` for everything else, so no disclosure
  /// triangle is drawn.
  var parts: [TransactionRowItem]?

  var isPart: Bool {
    if case .part = id { return true }
    return false
  }
}

/// One side of one day: its income — with the money people gave back — or its spending.
struct TransactionSection: Identifiable, Sendable {
  enum Side: String, Sendable {
    case income
    case expenses

    /// Money given back is listed among the income because money came in; it is never
    /// added to the income (`RowTotals` keeps it apart).
    static func of(_ kind: TransactionKind) -> Side {
      TransactionsStore.DayGroup.isListedWithIncome(kind) ? .income : .expenses
    }
  }

  let day: DateOnly
  let side: Side
  let rows: [TransactionRowItem]
  /// What this side of the day comes to, from `RowTotals`: the same function as the day of
  /// Overview, the selection bar and the delete confirmation.
  let totals: RowTotals

  var id: String { "\(day.iso).\(side.rawValue)" }
}

/// What the table shows for one filtering: sections newest day first, income before
/// spending within a day, operations newest first within a side.
struct TransactionListing: Sendable {
  let sections: [TransactionSection]
  /// The operations listed: the selection never reaches beyond them.
  let visibleIds: Set<UUID>
  /// The operation each listed part belongs to.
  let partOwners: [UUID: UUID]

  static let empty = TransactionListing(sections: [], visibleIds: [], partOwners: [:])

  var isEmpty: Bool { sections.isEmpty }
  var operationCount: Int { visibleIds.count }

  // MARK: Months at a time

  /// How many months the table shows at first, and how many more each «Show more» adds.
  /// SwiftUI's `Table` pays for every section on every change — a click that selects one
  /// row re-reads them all — and «All time» of two dense years is a thousand sections: a
  /// second per click in the measurement of step 7. Three months are under two hundred.
  static let monthsPerPage = 3

  /// The months the listing covers, newest first.
  var months: [MonthKey] {
    var months: [MonthKey] = []
    for section in sections where months.last != section.day.monthKey {
      months.append(section.day.monthKey)
    }
    return months
  }

  /// The newest `count` months of the listing, as the table shows them: the sections of
  /// those months, and only their operations and parts as the ones a selection may hold.
  func latestMonths(_ count: Int) -> TransactionListing {
    let months = self.months
    guard count < months.count else { return self }
    let kept = Set(months.prefix(max(count, 0)))
    let shown = sections.filter { kept.contains($0.day.monthKey) }
    var visible: Set<UUID> = []
    var owners: [UUID: UUID] = [:]
    for row in shown.lazy.flatMap(\.rows) {
      visible.insert(row.transactionId)
      for part in row.parts ?? [] {
        if case .part(let id) = part.id { owners[id] = row.transactionId }
      }
    }
    return TransactionListing(sections: shown, visibleIds: visible, partOwners: owners)
  }

  /// The operations among rows of the table. Parts are left out: they cannot be selected,
  /// and the selection holds operations only.
  static func operations(in rows: Set<RowID>) -> Set<UUID> {
    Set(
      rows.compactMap { row in
        if case .transaction(let id) = row { return id }
        return nil
      })
  }

  /// The operations rows stand for, a part standing for its operation: what a double click
  /// or the menu of a part of a split acts on.
  func owners(of rows: Set<RowID>) -> Set<UUID> {
    Set(
      rows.compactMap { row in
        switch row {
        case .transaction(let id): id
        case .part(let id): partOwners[id]
        }
      })
  }

  /// Builds the rows of the operations the filter found, newest first, from the ledger
  /// they were found in. Pure, and meant for `ComputeStore.compute`.
  static func build(_ ids: [UUID], ledger: Ledger) -> TransactionListing {
    let names = Names(ledger.dataset)
    let debts = ledger.debtsById
    var sections: [TransactionSection] = []
    var partOwners: [UUID: UUID] = [:]
    var visible: Set<UUID> = []
    visible.reserveCapacity(ids.count)

    var day: DateOnly?
    var income: [TransactionEntry] = []
    var expenses: [TransactionEntry] = []
    func closeDay() {
      guard let day else { return }
      for (side, entries) in [(TransactionSection.Side.income, income), (.expenses, expenses)]
      where !entries.isEmpty {
        sections.append(
          TransactionSection(
            day: day, side: side,
            rows: entries.map { row(for: $0, ledger: ledger, names: names) },
            totals: RowTotals(entries: entries, debts: debts)))
      }
      income.removeAll(keepingCapacity: true)
      expenses.removeAll(keepingCapacity: true)
    }

    for id in ids {
      guard let entry = ledger.entry(id), visible.insert(id).inserted else { continue }
      let entryDay = ledger.calendar.day(of: entry.transaction.occurredAt)
      if entryDay != day {
        closeDay()
        day = entryDay
      }
      if TransactionSection.Side.of(entry.transaction.kind) == .income {
        income.append(entry)
      } else {
        expenses.append(entry)
      }
      if entry.isSplit {
        for part in entry.parts { partOwners[part.id] = id }
      }
    }
    closeDay()
    return TransactionListing(sections: sections, visibleIds: visible, partOwners: partOwners)
  }

  // MARK: - Rows

  private static func row(
    for entry: TransactionEntry, ledger: Ledger, names: Names
  ) -> TransactionRowItem {
    let transaction = entry.transaction
    let cells = entry.parts.map { PartCells($0, in: transaction, ledger: ledger, names: names) }
    let parts: [TransactionRowItem]? =
      entry.isSplit
      ? zip(entry.parts, cells).enumerated().map { index, pair in
        let (part, cell) = pair
        return TransactionRowItem(
          id: .part(part.id), transactionId: transaction.id, kind: transaction.kind,
          occurredAt: transaction.occurredAt, note: part.note,
          title: RowTitle.resolve(note: part.note, category: cell.category, kind: transaction.kind),
          expression: nil, partNumber: index + 1, place: nil,
          category: cell.category.map(RowCell.one) ?? .none,
          forWhom: cell.forWhom.map(RowCell.one) ?? .none,
          event: cell.event.map(RowCell.one) ?? .none, paymentMethod: nil,
          quality: cell.quality.map(RowCell.one) ?? .none, amount: part.amountE4,
          currency: transaction.currency, amountRub: part.amountRubE4, partCount: 1,
          owedMark: nil, parts: nil)
      } : nil
    let category = RowCell.of(cells.map(\.category))
    return TransactionRowItem(
      id: .transaction(transaction.id), transactionId: transaction.id, kind: transaction.kind,
      occurredAt: transaction.occurredAt, note: transaction.note,
      title: RowTitle.resolve(
        note: transaction.note, category: cells.lazy.compactMap(\.category).first,
        kind: transaction.kind),
      expression: transaction.amountExpr, partNumber: nil,
      place: transaction.placeId.flatMap { names.places[$0] },
      category: category,
      forWhom: RowCell.of(cells.map(\.forWhom)),
      event: RowCell.of(cells.map(\.event)),
      paymentMethod: transaction.paymentMethodId.flatMap { names.paymentMethods[$0] },
      quality: RowCell.of(cells.map(\.quality)),
      amount: transaction.amountE4, currency: transaction.currency,
      amountRub: transaction.amountRubE4, partCount: entry.parts.count,
      owedMark: owedMark(of: entry), parts: parts)
  }

  /// The quality of an operation as a row of the list of days shows it, the way the table
  /// does: the rules' quality of each part (the one the filter and every figure use, none
  /// for income), one value when the parts agree and «several» when they do not. A part the
  /// ledger does not know yet — the data has not come — shows what it stores.
  static func quality(of entry: TransactionEntry, ledger: Ledger?) -> RowCell<Quality> {
    RowCell.of(
      entry.parts.map { part in ledger?.row(ofPart: part.id).map(\.quality) ?? part.quality })
  }

  /// The mark of a purchase with parts paid for somebody else: waiting while any of them
  /// waits, then returned, then written off. `reimbursable` stays set after the money came
  /// back, so it alone would keep a settled row «waiting» forever. Only a purchase is
  /// waited for: a friend's ticket taken back in a refund carries no mark.
  static func owedMark(of entry: TransactionEntry) -> ReimbursementStatus? {
    guard entry.transaction.kind == .expense else { return nil }
    let statuses = Set(
      entry.parts.filter(\.reimbursable).map { $0.reimbursementStatus ?? .expected })
    return [ReimbursementStatus.expected, .returned, .writtenOff].first(where: statuses.contains)
  }

  /// The cells of one part, as the operation's row compares them across its parts.
  private struct PartCells {
    var category: CategoryPath?
    var forWhom: ForWhomValue?
    var event: String?
    var quality: Quality?

    init(_ part: TransactionPart, in transaction: Transaction, ledger: Ledger, names: Names) {
      category = CategoryPath(part.categoryId, tree: ledger.tree)
      event = part.eventId.flatMap { names.events[$0] }
      // The rules' quality, the one the filter and every figure use; none for income.
      quality = ledger.row(ofPart: part.id)?.quality
      switch transaction.kind {
      case .income:
        forWhom = nil
      case .reimbursement:
        // Who gave the money back.
        forWhom = part.forPersonId.flatMap { names.people[$0] }.map(ForWhomValue.person)
      case .expense where part.reimbursable:
        forWhom = .owed(
          by: (part.debtorPersonId ?? part.forPersonId).flatMap { names.people[$0] },
          part.reimbursementStatus ?? .expected)
      case .expense, .refund:
        forWhom =
          part.forPersonId.flatMap { names.people[$0] }.map(ForWhomValue.person)
          ?? .value(part.forWhom)
      }
    }
  }

  /// Names of the dictionaries, archived ones included: an operation filed under a retired
  /// place still says where it was.
  private struct Names {
    let people: [UUID: String]
    let places: [UUID: String]
    let events: [UUID: String]
    let paymentMethods: [UUID: String]

    init(_ dataset: Dataset) {
      func index<T>(
        _ items: [T], _ id: KeyPath<T, UUID>, _ name: KeyPath<T, String>
      ) -> [UUID:
        String]
      {
        Dictionary(
          items.map { ($0[keyPath: id], $0[keyPath: name]) }, uniquingKeysWith: { a, _ in a })
      }
      people = index(dataset.people, \.id, \.name)
      places = index(dataset.places, \.id, \.name)
      events = index(dataset.events, \.id, \.name)
      paymentMethods = index(dataset.paymentMethods, \.id, \.name)
    }
  }
}

/// What the table shows of what the filters found, a few months at a time,
/// kept in step while two things change it at once: a filtering — of a new filter, or of new
/// data — and «Show more». Both cut the page off the main thread and land whenever they are
/// done, in either order, so each landing checks what it was cut for:
///
/// * a filtering cut its page for the months shown when it started; if «Show more» asked
///   for more meanwhile, the new listing is shown at once and cut again for them;
/// * a page «Show more» cut lands only if it was cut from the listing shown now, for the
///   months asked for now. Cut from an older listing, it would bring back operations the
///   data no longer has, and a selection could hold them.
struct TransactionPages {
  /// A page to cut off the main thread: from which listing, how many months, and the stamp
  /// of that listing.
  struct Request: Sendable {
    let listing: TransactionListing
    let months: Int
    fileprivate let serial: Int
  }

  /// What the filters found; `nil` until the first filtering is done.
  private(set) var listing: TransactionListing?
  /// The newest months of it the table shows.
  private(set) var shown: TransactionListing?
  /// How many months the table shows: a new filter starts again from the first page, new
  /// data keeps what was opened.
  private(set) var monthsShown = TransactionListing.monthsPerPage
  /// Moves on with every listing that lands.
  private var serial = 0

  /// Another filter or search starts from the newest months again.
  mutating func startOver() {
    monthsShown = TransactionListing.monthsPerPage
  }

  /// A filtering landed: what it found, and the page cut from it for `months`. The table
  /// shows them at once; when «Show more» asked for another number of months while the
  /// filtering ran, the page still to cut for them is returned.
  mutating func land(
    found: TransactionListing, page: TransactionListing, cutFor months: Int
  ) -> Request? {
    serial += 1
    listing = found
    shown = page
    guard months != monthsShown else { return nil }
    return Request(listing: found, months: monthsShown, serial: serial)
  }

  /// «Show more»: a few more months of the listing shown now.
  mutating func showMore() -> Request? {
    guard let listing else { return nil }
    monthsShown += TransactionListing.monthsPerPage
    return Request(listing: listing, months: monthsShown, serial: serial)
  }

  /// A page cut for `request` landed; returns whether it is shown. Only a page cut from the
  /// listing shown now, for the months asked for now, is — any other is dropped.
  mutating func land(_ page: TransactionListing, for request: Request) -> Bool {
    guard request.serial == serial, request.months == monthsShown else { return false }
    shown = page
    return true
  }
}
