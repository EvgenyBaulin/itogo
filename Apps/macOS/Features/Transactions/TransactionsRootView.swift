import AppCore
import SwiftUI

/// The Transactions window: every operation of the history in a table, with the filters in
/// the sidebar, search in the toolbar (⌘F) and the operation being edited in the inspector.
///
/// The table is the whole history the pipeline holds (`ComputeStore`), filtered by
/// `EntryFilter` and turned into rows off the main thread, 150 ms after the last change of
/// a filter, of the search or of the data, the previous filtering cancelled. Until the
/// first data arrives the window shows the state of the data step; after that it keeps the
/// rows it has while the data is read again.
///
/// Selecting many and changing them works as in Overview: the same `OperationActions`, the
/// same bulk menu and confirmations, the same bar — here a glass capsule of its own at the
/// bottom of the table.
struct TransactionsRootView: View {
  let deps: AppDependencies

  /// The window makes its own `OperationActions`; a test hands in the one it holds, so it can
  /// ask for the same edit a double click asks for (`TransactionsLayoutTests`).
  init(
    deps: AppDependencies, actions: OperationActions = OperationActions(),
    editing: TransactionEditorModel? = nil
  ) {
    self.deps = deps
    _actions = State(initialValue: actions)
    _editor = State(initialValue: editing)
  }

  private var environment: AppEnvironment { deps.environment }
  private var store: TransactionsStore { deps.store }
  private var compute: ComputeStore { deps.compute }

  @State private var filters = TransactionFilters(today: CalendarContext.system.day(of: Date()))
  @State private var choices = FilterChoices()
  /// What the filters found and the newest months of it the table shows.
  @State private var pages = TransactionPages()
  @State private var actions: OperationActions
  /// The operation in the inspector. It stays there until «Save» or «Cancel», whatever is
  /// selected meanwhile.
  @State private var editor: TransactionEditorModel?
  /// The one question the inspector can be asking. One state, not three flags: two
  /// `confirmationDialog`s cannot both be «presented» at once, and one of them cannot be
  /// dropped in silence with its flag left set to fire later.
  @State private var dialog: InspectorDialog = .none
  /// Shown unless the inspector needs its room (`makeRoomForTheInspector`). Never
  /// `.automatic`: that is a request, not a state, and `columnVisibility` is a two-way
  /// binding — whatever resolves it writes a concrete value back, and a guard comparing
  /// against `.automatic` would then write again on every pass.
  @State private var sidebar: NavigationSplitViewVisibility = .all
  /// Whether **this view** is the one holding the sidebar closed. `columnVisibility` is
  /// two-way, so the owner closing the filters himself — the toolbar's sidebar button, ⌃⌘S,
  /// a drag of the divider — writes `.detailOnly` too, and without this flag the next change
  /// of width would open it again on him.
  @State private var collapsedForTheInspector = false
  /// What the window gives this view. It decides whether all three columns can be shown at
  /// once; it never decides a height.
  @State private var width: CGFloat = 0
  @FocusState private var searchFocused: Bool
  /// Which columns are shown, in which order and how wide: a setting of this window, kept in
  /// `UserDefaults` and never in the database or an archive.
  @AppStorage("transactions.columns") private var columns =
    TableColumnCustomization<TransactionRowItem>()

  /// Nothing is asked, another operation is waiting, or a folded-away inspector is holding
  /// an unsaved edit. The edit lives here while the question is up: the inspector is already
  /// gone, because SwiftUI asked for it to be.
  enum InspectorDialog {
    case none
    case switching(TransactionEntry)
    case closing(TransactionEditorModel)
  }

  private var switchingTo: TransactionEntry? {
    if case .switching(let entry) = dialog { entry } else { nil }
  }

  private var closingEdited: TransactionEditorModel? {
    if case .closing(let model) = dialog { model } else { nil }
  }

  var body: some View {
    NavigationSplitView(columnVisibility: $sidebar) {
      TransactionFiltersForm(filters: $filters, choices: choices)
        .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
        // A column of a split view is a host of its own, and such a host does not always get
        // the environment of the scene on macOS 26 — the same reason the inspector
        // below is handed the dependencies explicitly.
        .appDependencies(deps)
    } detail: {
      detail
        .appDependencies(deps)
        .inspector(isPresented: inspectorShown) {
          Group {
            if let editor {
              TransactionInspector(deps: deps, editor: editor) { closeOnPurpose() }
                // The operation, not the object: `followData` makes a fresh model for the
                // same operation on every generation of the data, and identity by object
                // then tears the whole column down and builds it again — a column's worth of
                // views added and removed on every pass.
                .id(editor.id)
            }
          }
          .inspectorColumnWidth(min: 300, ideal: TransactionInspector.idealWidth, max: 440)
        }
    }
    .searchable(
      text: $filters.search, placement: .toolbar,
      prompt: Text(verbatim: t("transactions.search"))
    )
    .searchFocused($searchFocused)
    .task {
      // `--present inspector`: the newest operation in the inspector, as a double click does.
      guard await LaunchPresentation.due(.inspector) else { return }
      // The data may still be on its way three seconds after the window appears.
      for _ in 0..<50 where compute.snapshot == nil {
        try? await Task.sleep(for: .milliseconds(200))
      }
      if let newest = compute.snapshot?.dataset.entries
        .filter({ $0.transaction.deletedAt == nil })
        .max(by: { $0.transaction.occurredAt < $1.transaction.occurredAt })
      {
        if LaunchOptions.current.presents.contains(.selection) {
          actions.selection = [newest.id]
        }
        request(newest)
      }
    }
    .navigationSubtitle(subtitle)
    .frame(minWidth: 820, minHeight: 480)
    // The window is never widened for the inspector; the sidebar steps aside instead.
    // A width taken off the screen is allowed to decide a layout — it comes
    // from the window, top down, and settles in one pass; a height would not.
    .onGeometryChange(for: CGFloat.self) {
      $0.size.width
    } action: { width in
      self.width = width
      makeRoomForTheInspector()
    }
    .onChange(of: editor == nil) { _, _ in makeRoomForTheInspector() }
    .confirmationDialog(
      t("inspector.unsavedTitle"), isPresented: isAskingToSwitch, titleVisibility: .visible,
      presenting: switchingTo
    ) { next in
      // Offered only when «Save» of the inspector could be pressed: a total of zero, parts
      // that do not add up or a large write landing leave «Don't Save» and «Cancel».
      if editor?.canSave(in: store) == true {
        Button(environment.language("action.save")) { saveAndSwitch(to: next) }
      }
      Button(t("inspector.discard"), role: .destructive) {
        dialog = .none
        open(next)
      }
      Button(environment.language("action.cancel"), role: .cancel) { dialog = .none }
    } message: { _ in
      Text(verbatim: t("inspector.unsavedMessage"))
    }
    .confirmationDialog(
      t("inspector.closedTitle"), isPresented: isAskingAboutClosing, titleVisibility: .visible,
      presenting: closingEdited
    ) { parked in
      if parked.canSave(in: store) == true {
        Button(environment.language("action.save")) { saveAndClose(parked) }
      }
      Button(t("inspector.discard"), role: .destructive) { dialog = .none }
      // The inspector comes back with the edit still in it. It was folded away for room, and
      // there is room now: the sidebar is what gives way in a narrow window, not the
      // inspector.
      Button(environment.language("action.cancel"), role: .cancel) {
        editor = parked
        dialog = .none
      }
    } message: { _ in
      Text(verbatim: t("inspector.closedMessage"))
    }
    .onAppear {
      // A double click is an `NSTableView` delegate callback: the inspector opens on the next
      // turn of the main queue, so the window is not rearranged while the table is still
      // handling the click.
      actions.opensEditor = { entry in MainQueue.afterCallback { request(entry) } }
      followData()
      takeSearchFocus()
      takeRange()
    }
    // Every change of the data: the dictionaries the filters and the bulk menu offer follow
    // it, and the inspector follows the operation it holds (`TransactionEditorModel.follow`).
    .onChange(of: compute.generation) { _, _ in followData() }
    // ⌘F while the window is already open; when it opens, `onAppear` takes the flag.
    .onChange(of: environment.pendingSearchFocus) { _, _ in takeSearchFocus() }
    .onChange(of: environment.pendingTransactionsRange) { _, _ in takeRange() }
    // Another filter or search starts from the newest months again.
    .onChange(of: filters.entryFilter(today: environment.today)) { _, _ in
      pages.startOver()
    }
    .task(
      id: FilterKey(
        filter: filters.entryFilter(today: environment.today), generation: compute.generation)
    ) {
      await refilter()
    }
  }

  // MARK: The table and its states

  private var detail: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      // The bar floats over the last rows and keeps them clear of it. The height it needs is
      // left to the safe area, never measured back into `@State`: with the inspector open,
      // a measured height fed back into the padding never settled — the window kept asking
      // for another Update Constraints pass until AppKit gave up and threw.
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if showsBar {
          GlassEffectContainer {
            SelectionBar(actions: actions, hugsContent: true)
          }
          .frame(maxWidth: Self.barMaxWidth)
          .padding(.horizontal, 16)
          .padding(.vertical, Self.barGap)
          .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
      }
      .animation(.snappy, value: showsBar)
      // The root of the screen: the selection bar reports its frame in this space, and the
      // popovers and confirmations of the bulk menu hang here, not on the rows of the table.
      .coordinateSpace(.named(OperationActions.coordinateSpace))
      .operationPresentations(actions)
  }

  @ViewBuilder
  private var content: some View {
    if compute.snapshot == nil, let state = compute.states.data.waiting {
      ComputedBlock(waiting: state) { compute.retry(ComputeStep.data) }
    } else if compute.snapshot?.ledger.rows.isEmpty == true {
      ContentUnavailableView {
        Label {
          Text(verbatim: t("transactions.noneYet"))
        } icon: {
          Image(systemName: "list.bullet.rectangle")
        }
      } description: {
        Text(verbatim: t("transactions.noneYetHint"))
      }
    } else if let listing = pages.listing, let shown = pages.shown, !listing.isEmpty {
      VStack(spacing: 0) {
        TransactionsTable(
          deps: deps,
          listing: shown,
          selection: $actions.selection,
          columns: $columns,
          menu: { ids in BulkMenuItems(ids: ids, actions: actions, offersEdit: true) },
          primaryAction: { ids in actions.edit(ids, store: store) },
          deleteAction: { ids in actions.requestDeletion(of: ids, store: store) })
        if shown.operationCount < listing.operationCount {
          earlierMonths(hidden: listing.operationCount - shown.operationCount)
        }
      }
    } else if pages.listing != nil {
      nothingFound
    } else {
      ProgressView()
    }
  }

  /// The table shows the newest months of what was found; earlier ones come a few months at
  /// a time.
  private func earlierMonths(hidden: Int) -> some View {
    VStack(spacing: 0) {
      Divider()
      HStack(spacing: 12) {
        Text(
          verbatim: environment.language.format(
            "transactions.olderHidden", table: "Transactions", counts: hidden)
        )
        .foregroundStyle(.secondary)
        .lineLimit(1)
        Spacer(minLength: 8)
        Button(t("transactions.showEarlier")) { showEarlier() }
          .buttonStyle(.link)
      }
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
    }
  }

  /// A few more months, cut off the main thread from the listing already built.
  private func showEarlier() {
    guard let request = pages.showMore() else { return }
    Task { await cut(request) }
  }

  /// Cuts a page off the main thread and shows it — unless the listing or the months asked
  /// for changed while it was cut (`TransactionPages`).
  private func cut(_ request: TransactionPages.Request) async {
    guard let page = try? await compute.compute({ request.listing.latestMonths(request.months) }),
      pages.land(page, for: request)
    else { return }
    actions.keep(only: page.visibleIds)
  }

  /// The filters and the search found nothing. «Reset» brings back this month with nothing
  /// chosen; when there is nothing to reset — an empty month — the whole history is offered.
  private var nothingFound: some View {
    ContentUnavailableView {
      Label {
        Text(verbatim: t("filters.nothingFound"))
      } icon: {
        Image(systemName: "line.3.horizontal.decrease.circle")
      }
    } description: {
      Text(verbatim: t("filters.empty"))
    } actions: {
      if filters.canReset {
        Button(t("filters.reset")) { filters.reset() }
      } else if filters.period != .allTime {
        Button(t("filters.allTime")) { filters.period = .allTime }
      }
    }
  }

  // MARK: The selection bar

  /// The bar keeps its distance from the bottom of the table, and never grows wider than
  /// the entry line of the main window.
  /// The narrowest window that holds the filters, the table and the inspector at once: the
  /// sidebar's minimum, the minimums of the visible columns and the inspector's minimum. In a
  /// window any narrower the three columns cannot all be satisfied, and the layout runs away.
  static let widthWithInspector: CGFloat = 1100

  /// Who gives way when the three columns do not fit: the sidebar, never the window.
  ///
  /// Asking the window to be 1100 pt wide while the inspector was open did make the layout
  /// converge, but AppKit never shrinks a window back — so one double click left this window
  /// at least 1100 pt wide for good, and on a screen that could not give 1100 SwiftUI folded
  /// the inspector away again the moment it opened. Collapsing the sidebar instead costs a
  /// panel of filters while an operation is being edited, and nothing else.
  private func makeRoomForTheInspector() {
    // The first pass knows nothing about the window; deciding then would write twice.
    guard width > 0 else { return }
    let needsRoom = editor != nil && width < Self.widthWithInspector
    // Only the two transitions are written, and only the collapse this view made is undone.
    if needsRoom, !collapsedForTheInspector {
      collapsedForTheInspector = true
      sidebar = .detailOnly
    } else if !needsRoom, collapsedForTheInspector {
      collapsedForTheInspector = false
      sidebar = .all
    }
  }

  private static let barGap: CGFloat = 18
  private static let barMaxWidth: CGFloat = 720

  /// A selection, or a large write landing with nothing selected (`SelectionBar.Form`).
  private var showsBar: Bool {
    SelectionBar.form(selection: actions.selection, writing: store.isWritingInBackground)
      != .hidden
  }

  // MARK: Filtering

  /// Filters the whole history and builds the rows off the main thread. The first filtering
  /// after the data arrives goes at once; later ones wait 150 ms, so typing in the search box
  /// filters once.
  private func refilter() async {
    guard let ledger = compute.snapshot?.ledger else { return }
    if pages.listing != nil {
      try? await Task.sleep(for: ComputeStore.debounce)
      guard !Task.isCancelled else { return }
    }
    let (filter, months) = (filters.entryFilter(today: environment.today), pages.monthsShown)
    guard
      let result = try? await compute.compute({
        let found = TransactionListing.build(matching: filter, in: ledger)
        return (found: found, page: found.latestMonths(months))
      }),
      // A newer filter or newer data replaced this one while it ran: its result is stale.
      !Task.isCancelled
    else { return }
    let again = pages.land(found: result.found, page: result.page, cutFor: months)
    // Whatever the filters hide, the months not shown, and what a change takes away are no
    // longer selected.
    actions.keep(only: result.page.visibleIds)
    // «Show more» was pressed while this ran: the new listing is cut again for it.
    if let again { await cut(again) }
  }

  /// The dictionaries of the data the table shows, and the operation in the inspector kept
  /// in step with it.
  private func followData() {
    guard let snapshot = compute.snapshot else { return }
    choices = FilterChoices(snapshot.dataset, locale: environment.language.locale)
    // A value archived since it was chosen is no longer offered: it stops filtering.
    var kept = filters
    kept.keep(within: choices)
    if kept != filters { filters = kept }
    actions.reloadDictionaries(from: snapshot.dataset)
    guard let editor else { return }
    // Deleted meanwhile — from the menu, or by ⌘Z of its creation — or changed elsewhere — a
    // bulk change, a part written off: with nothing typed here the inspector closes, or shows
    // the operation as it is now, so a save cannot bring the old version back. With changes
    // typed it keeps them, and says so when the operation is gone.
    switch editor.follow(store.entry(id: editor.id)) {
    case .stay:
      break
    case .close:
      closeOnPurpose()
    case .reopen(let fresh):
      self.editor = TransactionEditorModel(
        entry: fresh, environment: environment, tree: snapshot.ledger.tree)
    }
  }

  // MARK: The inspector

  /// Writing `false` here is SwiftUI saying the inspector is gone — the owner closed it, or
  /// it was folded away. Either way the answer is yes: `editor` is cleared, so the binding
  /// reads `false` the next time it is asked.
  ///
  /// It used to answer «no» to a fold-away with an unsaved edit: it armed the question but
  /// left `editor` in place, so the binding went on reading `true` and SwiftUI put the
  /// inspector straight back up — and if the reason for folding had not gone, that repeated.
  /// An unsaved edit is not thrown away with it: it waits in the question.
  private var inspectorShown: Binding<Bool> {
    Binding(
      get: { editor != nil },
      set: { isShown in
        guard !isShown else { return }
        if let editing = editor, editing.hasChanges { dialog = .closing(editing) }
        editor = nil
      })
  }

  private var isAskingAboutClosing: Binding<Bool> {
    Binding(
      get: { closingEdited != nil },
      set: { isShown in
        if !isShown { dialog = .none }
      })
  }

  /// «Save» in the question asked when the inspector was folded away. The edit being saved is
  /// the one the question is holding, not whatever is in the inspector now — there is nothing
  /// in the inspector now. When it cannot be saved — a reason, or «Это было до сверки?» to
  /// answer first — the inspector comes back with the edit, and says it or asks it there.
  private func saveAndClose(_ parked: TransactionEditorModel) {
    guard parked.save(store: store, environment: environment, balances: balances) else {
      editor = parked
      return
    }
    dialog = .none
  }

  /// The accounts' balances as the data on screen has them: a save that lands an operation
  /// on the day of a count, after it, asks first.
  private var balances: AccountBalances {
    compute.snapshot?.planning.accounts.balances ?? .empty
  }

  /// The window closing the inspector itself: «Cancel», a save, an operation that is gone.
  /// Nothing to ask about — the decision has been made here.
  private func closeOnPurpose() {
    editor = nil
  }

  /// A double click or «Edit»: the operation goes into the inspector — after asking, when the
  /// one there has unsaved changes.
  private func request(_ entry: TransactionEntry) {
    if let editor, editor.id != entry.id, editor.hasChanges {
      dialog = .switching(entry)
      return
    }
    guard editor?.id != entry.id else { return }
    open(entry)
  }

  private func open(_ entry: TransactionEntry) {
    editor = TransactionEditorModel(
      entry: entry, environment: environment, tree: compute.snapshot?.ledger.tree ?? CategoryTree())
  }

  /// «Save» in the question: the changes are saved first; if they cannot be, the inspector
  /// keeps them and says why, and the other operation waits.
  private func saveAndSwitch(to next: TransactionEntry) {
    guard let editor, editor.save(store: store, environment: environment, balances: balances)
    else { return }
    dialog = .none
    open(next)
  }

  private var isAskingToSwitch: Binding<Bool> {
    Binding(
      get: { switchingTo != nil },
      set: { isShown in
        if !isShown { dialog = .none }
      })
  }

  // MARK: Search and the subtitle

  /// ⌘F from any window sets the flag and opens this one; whichever of `onAppear` and
  /// `onChange` comes first takes it, so the very first ⌘F with the window closed focuses
  /// the field too. The field of the toolbar may not be there yet when the window appears:
  /// the focus is asked for again a moment later.
  /// The days a reconciliation asked to look through for missing operations.
  private func takeRange() {
    guard let range = environment.pendingTransactionsRange else { return }
    environment.pendingTransactionsRange = nil
    filters.customStart = range.start
    filters.customEnd = range.end
    filters.period = .custom
  }

  private func takeSearchFocus() {
    guard environment.pendingSearchFocus else { return }
    environment.pendingSearchFocus = false
    searchFocused = true
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(150))
      searchFocused = true
    }
  }

  /// Empty, unless a reload of the data failed while older data stays in the table.
  private var subtitle: String {
    guard compute.states.reloadFailed, let readAt = compute.states.readAt else { return "" }
    return "⊘ "
      + environment.language.format(
        "transactions.dataStale", table: "Transactions",
        RecomputeText.readMoment(readAt, environment))
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Transactions") }
}

/// What the filtering of the window depends on.
private struct FilterKey: Hashable {
  let filter: EntryFilter
  let generation: Int
}

/// The sidebar of filters: a grouped form, every choice with its label.
struct TransactionFiltersForm: View {
  @Dependency(\.environment) private var environment
  @Binding var filters: TransactionFilters
  let choices: FilterChoices

  var body: some View {
    Form {
      Section {
        Picker(selection: $filters.period) {
          ForEach(TransactionFilters.PeriodChoice.allCases, id: \.self) { item in
            Text(verbatim: t(item.titleKey)).tag(item)
          }
        } label: {
          EmptyView()
        }
        .labelsHidden()
        .pickerStyle(.inline)
        if filters.period == .custom {
          // Dates in the language of the app: the window's locale is set at its root.
          DatePicker(selection: day(\.customStart), displayedComponents: .date) {
            Text(verbatim: t("filters.from"))
          }
          DatePicker(selection: day(\.customEnd), displayedComponents: .date) {
            Text(verbatim: t("filters.to"))
          }
        }
      } header: {
        Text(verbatim: t("filters.period"))
      }

      Section {
        OptionalPicker(
          title: t("filters.type"), any: any, selection: kind,
          options: TransactionKind.allCases.map {
            ($0, environment.language("kind.\($0.rawValue)"))
          })
        OptionalPicker(
          title: entry("entry.category"), any: any, selection: category,
          options: choices.topLevel(for: filters.kind).map { ($0.id, $0.name) })
        OptionalPicker(
          title: entry("entry.subcategory"), any: any, selection: $filters.subcategoryId,
          options: choices.subcategories(of: filters.categoryId).map { ($0.id, $0.name) }
        )
        .disabled(choices.subcategories(of: filters.categoryId).isEmpty)
        OptionalPicker(
          title: entry("entry.quality"), any: any, selection: $filters.quality,
          options: Quality.allCases.map { ($0, environment.language(Palette.qualityKey($0))) })
        OptionalPicker(
          title: entry("entry.forWhom"), any: any, selection: $filters.forWhom,
          options: ForWhom.allCases.map { ($0, environment.label(for: $0)) })
        OptionalPicker(
          title: t("filters.person"), any: any, selection: $filters.personId,
          options: choices.people.map { ($0.id, $0.name) })
        OptionalPicker(
          title: entry("entry.place"), any: any, selection: $filters.placeId,
          options: choices.places.map { ($0.id, $0.name) })
        OptionalPicker(
          title: entry("entry.event"), any: any, selection: $filters.eventId,
          options: choices.events.map { ($0.id, $0.name) })
        OptionalPicker(
          title: entry("entry.paymentMethod"), any: any, selection: $filters.paymentMethodId,
          options: choices.paymentMethods.map { ($0.id, $0.name) })
        OptionalPicker(
          title: t("filters.status"), any: any, selection: $filters.status,
          options: ReimbursementStatus.allCases.map {
            ($0, environment.language(Palette.reimbursementKey($0)))
          })
      } header: {
        Text(verbatim: t("filters.title"))
      }

      Section {
        // Filters and search alike; inactive when there is nothing to reset.
        Button(t("filters.reset")) { filters.reset() }
          .disabled(!filters.canReset)
      }
    }
    .formStyle(.grouped)
  }

  /// The type narrows the categories to its kind and drops one of the other kind.
  private var kind: Binding<TransactionKind?> {
    Binding(
      get: { filters.kind },
      set: { filters.setKind($0, tree: choices.categories) })
  }

  /// Another category drops the subcategory.
  private var category: Binding<UUID?> {
    Binding(
      get: { filters.categoryId },
      set: { filters.setCategory($0) })
  }

  /// A day of the custom range as a date picker edits it: the start of the day in the app's
  /// calendar.
  private func day(_ path: WritableKeyPath<TransactionFilters, DateOnly>) -> Binding<Date> {
    let calendar = environment.calendar
    return Binding(
      get: { calendar.startOfDay(filters[keyPath: path]) },
      set: { filters[keyPath: path] = calendar.day(of: $0) })
  }

  private var any: String { t("filters.any") }
  private func t(_ key: String) -> String { environment.language(key, table: "Transactions") }
  private func entry(_ key: String) -> String { environment.language(key, table: "Entry") }
}

/// A picker of one value or «Any».
private struct OptionalPicker<Value: Hashable>: View {
  let title: String
  let any: String
  @Binding var selection: Value?
  let options: [(Value, String)]

  var body: some View {
    Picker(selection: $selection) {
      Text(verbatim: any).tag(Value?.none)
      ForEach(options.indices, id: \.self) { index in
        Text(verbatim: options[index].1).tag(Value?.some(options[index].0))
      }
    } label: {
      Text(verbatim: title)
    }
  }
}

extension Notification.Name {
  /// Carries the section number of ⌘1 / ⌘2 / ⌘3.
  static let selectSection = Notification.Name("io.github.EvgenyBaulin.itogo.selectSection")
}

/// The content of the inspector. SwiftUI lays an inspector out in a host of its own, and on
/// macOS 27 without the window's environment — the crash of 19.09. So it takes
/// the dependencies in its initializer and hands them to the editor itself: a window cannot
/// show it without them, and a test lays it out the way the window does.
struct TransactionInspector: View {
  let deps: AppDependencies
  let editor: TransactionEditorModel
  let close: () -> Void

  var body: some View {
    TransactionEditor(editor: editor, style: .inspector, close: close)
      // The column's own ideal (`inspectorColumnWidth`), said again by the content: without
      // it the editor asks for what its widest row would like — 418 pt in English, 552 in
      // Russian — and the column grows to its maximum, leaving the table too little for the
      // selection bar in a window of the default width; the split then never settles (23.09,
      // `testADoubleClickThatAlsoSelectsTheRowSettlesInRussian`). The editor lays itself out
      // in 360 pt without loss: its rows wrap and its pickers shrink.
      .frame(idealWidth: TransactionInspector.idealWidth)
      .appDependencies(deps)
  }

  /// The same number `inspectorColumnWidth(ideal:)` is given in `TransactionsRootView`.
  static let idealWidth: CGFloat = 360
}
