import AppCore
import AppDatabase
import SwiftUI

/// Categories, their subcategories and their quality. System categories (Goals, Loans,
/// Unknown, Surcharges) — and everything under them, a goal's subcategory and a debt's —
/// cannot be renamed, archived or deleted, and a goal contribution is always good: the
/// quality picker of Goals and of every goal's subcategory is disabled rather than silently
/// ignored. Among the income categories the owner also says which one is cashback.
///
/// A new quality counts for the operations to come at once; whether the past follows is a
/// question, asked when there is something to change.
///
/// Every way out of a category lives in one menu on its row: delete, archive, and — the one
/// that was missing — bring back from the archive. Until 21.09 archiving was a small button
/// that made the row disappear for good, because nothing in the app ever listed an archived
/// category again.
struct CategoriesSettingsView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  /// Handed to the question of a deletion: a sheet is laid out by a host of its own.
  @Environment(\.dependencies) private var dependencies
  @State private var categories: [CoreKit.Category] = []
  /// The operations a new quality would re-rate, waiting for the owner's answer.
  @State private var pastQuality: PastQualityQuestion?
  @State private var counting: Task<Void, Never>?
  @State private var newName = ""
  @State private var newParent: UUID?
  @State private var kind: CategoryKind = .expense
  @State private var cashbackId: UUID?
  /// The archive is a place, not a hole: the list shows it when asked.
  @State private var showsArchived = false
  /// The category the owner asked to delete, and what points at it.
  @State private var deleting: CategoryDeletion?
  /// Where the operations of a used category go when it is deleted.
  @State private var moveTo: UUID?
  /// Said out loud when a write was refused, instead of the row simply not moving.
  @State private var refusalKey: String?
  /// The row whose name is being typed; its name is saved when the focus leaves it.
  @FocusState private var editingName: UUID?
  /// A write the database itself refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false

  /// `asking` opens the tab with the question of a deletion already on screen: how a test
  /// lays out the sheet without a click on a row's menu.
  init(asking deletion: CategoryDeletion? = nil) {
    _deleting = State(initialValue: deletion)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Picker(selection: $kind) {
          Text(verbatim: environment.language("kind.expense")).tag(CategoryKind.expense)
          Text(verbatim: environment.language("kind.income")).tag(CategoryKind.income)
        } label: {
          EmptyView()
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        Toggle(isOn: $showsArchived) {
          Text(verbatim: environment.language("categories.showArchived", table: "Settings"))
        }
        .toggleStyle(.checkbox)
        .fixedSize()
        .onChange(of: showsArchived) { _, _ in reload() }
      }

      List {
        ForEach(roots, id: \.id) { parent in
          Section {
            ForEach(children(of: parent), id: \.id) { child in
              row(child, isChild: true)
            }
          } header: {
            row(parent, isChild: false)
          }
        }
        // A live subcategory whose parent is in the archive has no row to hang on while the
        // archive is hidden — and it is still the category of its own past operations. It
        // gets a section of its own rather than disappearing from the only screen that can
        // rename, archive or delete it.
        if !orphans.isEmpty {
          Section {
            ForEach(orphans, id: \.id) { child in
              row(child, isChild: true)
            }
          } header: {
            Text(verbatim: environment.language("categories.orphans", table: "Settings"))
          }
        }
      }
      .frame(minHeight: 220)

      HStack {
        TextField(text: $newName) {
          Text(verbatim: environment.language("references.name", table: "Settings"))
        }
        Picker(selection: $newParent) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(liveRoots, id: \.id) { parent in
            Text(verbatim: parent.name).tag(UUID?.some(parent.id))
          }
        } label: {
          EmptyView()
        }
        .labelsHidden()
        .frame(maxWidth: 180)
        Button(environment.language("references.add", table: "Settings"), action: add)
          .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
      }

      if let refusalKey {
        Text(verbatim: environment.language(refusalKey, table: "Settings"))
          .font(.caption)
          .foregroundStyle(.red)
          .onTapGesture { self.refusalKey = nil }
      }

      if kind == .income {
        cashbackPicker
      }
    }
    .padding()
    .onAppear(perform: reload)
    .onChange(of: editingName) { left, _ in
      if let left { commitName(of: left) }
    }
    .onDisappear {
      if let editingName { commitName(of: editingName) }
    }
    .refusedWriteAlert($refused, environment)
    .onChange(of: kind) { _, _ in
      // A root of one kind is never the parent of a category of the other.
      newParent = nil
      reload()
    }
    // A sheet, not a `confirmationDialog`: when the operations of a category have to move,
    // the owner has to choose where — and a dialog holds buttons, not a picker. On the root
    // of the tab, never on a row: the rows are rebuilt by every reload.
    .sheet(item: $deleting) { question in
      CategoryDeletionSheet(
        question: question, moveTo: $moveTo,
        options: moveOptions(excluding: question),
        title: deleteTitle, message: deleteMessage(question),
        archive: {
          setArchived(question.category, true)
          deleting = nil
        },
        delete: { delete(question) },
        cancel: { deleting = nil }
      )
      .handingOver(dependencies)
    }
    .confirmationDialog(
      CategoryQualityText.title(environment.language), isPresented: isAsking,
      titleVisibility: .visible, presenting: pastQuality
    ) { question in
      Button(CategoryQualityText.apply(environment.language)) {
        store.apply(question.change, to: question.ids)
      }
      .disabled(store.isWritingInBackground)
      Button(CategoryQualityText.keep(environment.language), role: .cancel) {}
    } message: { question in
      Text(verbatim: CategoryQualityText.message(question.ids.count, environment.language))
    }
  }

  /// What the owner asked to delete and what points at it.
  struct CategoryDeletion: Identifiable {
    let category: CoreKit.Category
    /// Subcategories that would go with it.
    let children: Int
    /// Operations in the book that point at it or at one of its children.
    let live: Int
    /// The same, among operations already in the bin. They still hold their parts, and the
    /// schema refuses to drop a category anything points at — so these block a deletion and
    /// nothing in the app can move them.
    let binned: Int

    var id: UUID { category.id }
    var blocked: Bool { binned > 0 }
  }

  private var deleteTitle: String {
    environment.language("categories.delete.title", table: "Settings")
  }

  private func deleteMessage(_ question: CategoryDeletion) -> String {
    CategoryDeletionText.message(question, environment.language)
  }

  /// Every live category of the same kind except the one going and its children, named
  /// «Родитель › Ребёнок» so two subcategories called «Прочее» are told apart.
  private func moveOptions(excluding deletion: CategoryDeletion) -> [(id: UUID, name: String)] {
    let tree = wholeTree()
    let inside = Set([deletion.category.id] + tree.children(of: deletion.category.id).map(\.id))
    return
      categories
      .filter { $0.kind == kind && !$0.archived && !inside.contains($0.id) }
      // Never a system category or anything under one: the rule that moves operations refuses
      // them (`BulkEditRule.refusal`), so offering one would move nothing, and the deletion
      // would then fail for a reason the owner never saw.
      .filter { tree.systemRole(of: $0.id) == nil }
      .map { (id: $0.id, name: name(of: $0, tree: tree)) }
  }

  private func name(of category: CoreKit.Category, tree: CategoryTree) -> String {
    guard let parent = category.parentId, let root = tree.category(parent) else {
      return category.name
    }
    return "\(root.name) › \(category.name)"
  }

  private var isAsking: Binding<Bool> {
    Binding(
      get: { pastQuality != nil },
      set: { isShown in
        if !isShown { pastQuality = nil }
      })
  }

  private func row(_ category: CoreKit.Category, isChild: Bool) -> some View {
    // Read once for the row: both the lock and the quality picker ask it.
    let tree = wholeTree()
    return HStack {
      // A system category cannot be renamed, archived or deleted — and neither can a
      // subcategory of one: the role is handed down by the tree, and a goal's subcategory
      // taken away would be made again by the next contribution.
      if tree.systemRole(of: category.id) != nil {
        Text(verbatim: category.name)
          .padding(.leading, isChild ? 14 : 0)
        Image(systemName: "lock")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        TextField(text: nameBinding(for: category)) { EmptyView() }
          .labelsHidden()
          .textFieldStyle(.plain)
          .focused($editingName, equals: category.id)
          .onSubmit { commitName(of: category.id) }
          .padding(.leading, isChild ? 14 : 0)
          .frame(maxWidth: 220, alignment: .leading)
        if category.archived {
          Text(verbatim: environment.language("categories.archived", table: "Settings"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Menu {
          Button(environment.language("references.delete", table: "Settings")) {
            askToDelete(category)
          }
          if category.archived {
            Button(environment.language("categories.unarchive", table: "Settings")) {
              setArchived(category, false)
            }
          } else {
            Button(environment.language("references.archive", table: "Settings")) {
              setArchived(category, true)
            }
          }
        } label: {
          Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("categories.row.menu")
      }
      Spacer()
      if kind == .expense {
        Picker(selection: qualityBinding(for: category)) {
          Text(verbatim: "—").tag(Quality?.none)
          ForEach(Quality.allCases, id: \.self) { quality in
            Text(verbatim: environment.language(Palette.qualityKey(quality)))
              .tag(Quality?.some(quality))
          }
        } label: {
          EmptyView()
        }
        .labelsHidden()
        .frame(width: 150)
        .disabled(Self.qualityIsFixed(category, in: tree))
      }
    }
  }

  /// Whether the quality of a category is not the owner's to choose: Goals and everything
  /// under it, because a contribution is always good whatever its subcategory says
  /// (`QualityResolver`). Loans, a debt's subcategory and «Не помню» keep a quality of their
  /// own — there it is only the default («оценка по умолчанию neutral»).
  static func qualityIsFixed(_ category: CoreKit.Category, in tree: CategoryTree) -> Bool {
    tree.isGoalCategory(category.id)
  }

  /// The income category whose money Analytics counts as cashback, subcategories included.
  private var cashbackPicker: some View {
    VStack(alignment: .leading, spacing: 4) {
      Picker(selection: cashbackBinding) {
        Text(verbatim: "—").tag(UUID?.none)
        ForEach(liveRoots, id: \.id) { parent in
          Text(verbatim: parent.name).tag(UUID?.some(parent.id))
          ForEach(children(of: parent).filter { !$0.archived }, id: \.id) { child in
            Text(verbatim: "\(parent.name) › \(child.name)").tag(UUID?.some(child.id))
          }
        }
      } label: {
        Text(verbatim: environment.language("categories.cashback", table: "Settings"))
      }
      Text(verbatim: environment.language("categories.cashbackHint", table: "Settings"))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  /// «—» is kept as an empty value, so the choice survives the next launch instead of being
  /// taken for a setting never made.
  private var cashbackBinding: Binding<UUID?> {
    Binding(
      get: { cashbackId },
      set: { newValue in
        guard
          environment.attempt(
            "settings.cashback", on: environment.settings,
            { try $0.set(AnalyticsSettings.cashbackCategoryKey, to: newValue?.uuidString ?? "") })
        else {
          refused = true
          return
        }
        cashbackId = newValue
        environment.scheduleBackup()
      })
  }

  private var roots: [CoreKit.Category] {
    categories.filter { $0.kind == kind && $0.parentId == nil }
  }

  /// What a picker may offer. `roots` carries archived rows once the toggle is on, and a new
  /// category filed under an archived parent is refused by every rule that reads the tree.
  /// Deliberately derived from `roots` and never from `orphans`: a subcategory must not
  /// become an offer to be somebody's parent.
  private var liveRoots: [CoreKit.Category] {
    roots.filter { !$0.archived }
  }

  /// Subcategories of this kind whose parent is not on screen.
  private var orphans: [CoreKit.Category] {
    let shown = Set(roots.map(\.id))
    return categories.filter { $0.kind == kind && $0.parentId.map { !shown.contains($0) } == true }
  }

  private func children(of parent: CoreKit.Category) -> [CoreKit.Category] {
    categories.filter { $0.parentId == parent.id }
  }

  /// The new quality is saved at once and counts for the operations to come. Whether the
  /// past follows is asked next, once the operations it would change have been counted.
  private func qualityBinding(for category: CoreKit.Category) -> Binding<Quality?> {
    Binding(
      get: { category.quality },
      set: { newValue in
        guard newValue != category.quality else { return }
        var updated = category
        updated.quality = newValue
        guard
          environment.attempt(
            "categories.save", on: environment.references, { try $0.save(updated) })
        else {
          refused = true
          return
        }
        reload()
        environment.scheduleBackup()
        askAboutThePast(CategoryQualityChange(categoryId: category.id))
      })
  }

  /// Counts, off the main thread and over the pipeline's ledger, the operations the new
  /// quality would re-rate, and asks about them — nothing is asked when there are none.
  /// The categories are read as they are now, the new quality with them: the ledger reads
  /// them again only a moment later. A newer change replaces a count still running.
  private func askAboutThePast(_ change: CategoryQualityChange) {
    counting?.cancel()
    guard let ledger = compute.snapshot?.ledger else { return }
    let tree = CategoryTree(store.categories())
    counting = Task {
      guard
        let ids = try? await compute.compute({ change.affected(ledger.entries, tree: tree) }),
        !Task.isCancelled, !ids.isEmpty
      else { return }
      pastQuality = PastQualityQuestion(change: change, ids: ids)
    }
  }

  /// What the owner types stays in the local copy, so typing does not fight with the
  /// database; it is saved once — on Return, when the field loses focus, when the list reloads
  /// or the tab goes away (`commitName`). Until 24.09 every keystroke was a write, a backup
  /// scheduled and a run of the pipeline.
  private func nameBinding(for category: CoreKit.Category) -> Binding<String> {
    Binding(
      get: {
        categories.first { $0.id == category.id }?.name ?? category.name
      },
      set: { newValue in
        guard let index = categories.firstIndex(where: { $0.id == category.id }) else { return }
        categories[index].name = newValue
      })
  }

  /// Saves the name typed into the row of `id`, trimmed. A name emptied, or typed back to what
  /// is stored, writes nothing, and the row shows the stored name again. A name the database
  /// refused stays typed in the row, and the alert says it was not saved
  /// (`AppEnvironment.attempt`).
  private func commitName(of id: UUID) {
    guard let index = categories.firstIndex(where: { $0.id == id }),
      let stored = try? environment.references?.categories(includeArchived: true)
        .first(where: { $0.id == id })
    else { return }
    guard let renamed = Self.renamed(stored, to: categories[index].name) else {
      categories[index].name = stored.name
      return
    }
    guard
      environment.attempt("categories.save", on: environment.references, { try $0.save(renamed) })
    else {
      refused = true
      return
    }
    categories[index].name = renamed.name
    environment.refreshVocabulary()
    environment.scheduleBackup()
  }

  /// The category to save for a name typed into its row, or nothing to save.
  static func renamed(_ stored: CoreKit.Category, to typed: String) -> CoreKit.Category? {
    let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name != stored.name else { return nil }
    var renamed = stored
    renamed.name = name
    return renamed
  }

  private func setArchived(_ category: CoreKit.Category, _ archived: Bool) {
    var updated = category
    updated.archived = archived
    if !environment.attempt(
      "categories.archive", on: environment.references, { try $0.save(updated) })
    {
      refused = true
    }
    // A category brought back has to be visible even with the archive hidden.
    reload()
    environment.scheduleBackup()
  }

  /// Categories the app owns: the four system roots and everything under them. `isSystem`
  /// alone is not enough — a goal's subcategory and a debt's carry no role of their own and
  /// take it from their parent through the tree.
  private func isOwnedByTheApp(_ category: CoreKit.Category) -> Bool {
    wholeTree().systemRole(of: category.id) != nil
  }

  /// Every category there is, archived included. The displayed list follows the toggle, but a
  /// decision — what is system, what hangs under what, what would go with what — must never
  /// be made on a part of the book: an archived subcategory invisible to a deletion is a
  /// deletion the schema then refuses.
  private func wholeTree() -> CategoryTree {
    CategoryTree((try? environment.references?.categories(includeArchived: true)) ?? categories)
  }

  /// What points at a category, counted before anything is written: whether it can simply go,
  /// or whether its operations have to move first.
  private func askToDelete(_ category: CoreKit.Category) {
    guard !isOwnedByTheApp(category) else { return }
    // Two levels deep is all this tree ever is (категория и подкатегория), and it is read
    // whole: an archived subcategory holds the same references as a live one.
    let inside = [category.id] + wholeTree().children(of: category.id).map(\.id)
    // Without the data nothing can be counted, and a delete offered on a guess would fail at
    // the schema and look like a bug. The pipeline fills this a moment after the app starts.
    guard let all = compute.snapshot?.dataset.entries else {
      refusalKey = "categories.delete.notReady"
      return
    }
    // A write of many is already on its way; counting now would count the book as it was.
    guard !store.isWritingInBackground else {
      refusalKey = "categories.delete.busy"
      return
    }
    let ids = Set(inside)
    // The pipeline's data is live-only by construction — it is read with `deleted_at IS NULL`
    // — so what sits in the bin has to be asked of the database itself. Those parts still
    // point at the category, and nothing in the app can re-file them.
    let live = all.filter { $0.parts.contains { $0.categoryId.map(ids.contains) == true } }.count
    let binned = (try? environment.transactions?.binnedOperations(inCategories: inside)) ?? 0
    moveTo = nil
    deleting = CategoryDeletion(
      category: category, children: inside.count - 1, live: live, binned: binned)
  }

  /// Deletes the category, having moved what points at it when there was anything to move.
  /// Two writes when operations had to move, and the dialog says so: one ⌘Z takes back the
  /// deletion, a second one the move.
  private func delete(_ deletion: CategoryDeletion) {
    defer { deleting = nil }
    let inside = [deletion.category.id] + wholeTree().children(of: deletion.category.id).map(\.id)
    let outcome = Self.delete(
      inside, live: deletion.live, moveTo: moveTo,
      entries: compute.snapshot?.dataset.entries ?? [], store: store)
    refusalKey = outcome.refusalKey
    // A move that landed is on screen whatever became of the deletion after it.
    guard outcome.refusalKey == nil || outcome.moved else { return }
    reload()
    environment.refreshVocabulary()
    environment.scheduleBackup()
  }

  /// What became of deleting: the key of what the owner is told (nil when the category went),
  /// and whether its operations were moved first.
  struct DeletionOutcome: Equatable {
    var refusalKey: String?
    var moved: Bool
  }

  /// The writes of deleting the categories `inside` (the one chosen and its children): first
  /// the `live` operations filed under them move to `target`, then the categories go.
  static func delete(
    _ inside: [UUID], live: Int, moveTo target: UUID?, entries: [TransactionEntry],
    store: TransactionsStore
  ) -> DeletionOutcome {
    var moved = false
    if live > 0 {
      guard let target,
        moveOperations(of: Set(inside), to: target, entries: entries, store: store)
      else {
        return DeletionOutcome(refusalKey: "categories.delete.failed", moved: false)
      }
      moved = true
      // A move of more than a thousand operations is written off the main thread and answers
      // «yes» before it has landed. Deleting on top of that would race the write, so the
      // category waits: the move is real, and one ⌘Z takes it back.
      if store.isWritingInBackground {
        return DeletionOutcome(refusalKey: "categories.delete.moving", moved: true)
      }
    }
    var rows = PlanningRowIDs.empty
    // Children first: a parent still referenced by its own child cannot go.
    rows.categories = inside.reversed()
    guard store.apply(PlanningChange(delete: rows)) else {
      // Something points at the category that was not there when the operations were
      // counted — one filed since, or put in the bin. The move is written by then, a step of
      // ⌘Z of its own, and the owner is told so.
      return DeletionOutcome(
        refusalKey: moved ? "categories.delete.failedAfterMove" : "categories.delete.failed",
        moved: moved)
    }
    return DeletionOutcome(refusalKey: nil, moved: moved)
  }

  /// The first write of deleting a used category: the live operations filed under one of
  /// `inside` move to `target`. Returns whether there was something to move and it moved.
  ///
  /// Only their parts in `inside` move. Each part of a split has a category of its own,
  /// and the question promises to move what lies in the category going; until 24.09
  /// this was the list's bulk change of category, which reaches every part of a split.
  static func moveOperations(
    of inside: Set<UUID>, to target: UUID, entries: [TransactionEntry],
    store: TransactionsStore
  ) -> Bool {
    let moving =
      entries
      .filter { $0.transaction.deletedAt == nil }
      .filter { $0.parts.contains { $0.categoryId.map(inside.contains) == true } }
      .map(\.id)
    guard !moving.isEmpty else { return false }
    return store.apply(.refile(from: inside, to: target), to: moving)
  }

  private func reload() {
    // A name still being typed is saved first: the read below would put the stored one back.
    if let editingName { commitName(of: editingName) }
    categories = (try? environment.references?.categories(includeArchived: showsArchived)) ?? []
    cashbackId = (try? environment.settings?.string(AnalyticsSettings.cashbackCategoryKey))
      .flatMap { $0 }.flatMap(UUID.init(uuidString:))
  }

  /// Whether a new category of `kind` may be filed under `parent`: under nothing, or under
  /// a live root of the same kind (two levels, `kind` expense or income).
  ///
  /// The picker offers only those, but its choice outlives what it offered: until 24.09 a
  /// root chosen under «Расходы» stayed chosen when the switch went to «Доходы», and an income
  /// category was saved under an expense root — listed there with a quality picker, reported
  /// by the tree as an expense, offered by no form. The schema ties nothing to the parent's
  /// kind, so this is the check.
  static func acceptsParent(
    _ parent: UUID?, for kind: CategoryKind, in categories: [CoreKit.Category]
  ) -> Bool {
    NewReference.acceptsParent(parent, for: kind, in: categories)
  }

  /// A new category is made the way «Add…» of the ↓ panel makes one (`NewReference`).
  private func add() {
    guard let references = environment.references else { return }
    let name = newName.trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return }
    let all = (try? references.categories(includeArchived: true)) ?? categories
    guard
      let category = NewReference.category(named: name, kind: kind, parent: newParent, among: all)
    else {
      newParent = nil
      refusalKey = "categories.add.parentRefused"
      return
    }
    guard environment.attempt("categories.add", on: references, { try $0.save(category) }) else {
      refused = true
      return
    }
    newName = ""
    reload()
    environment.scheduleBackup()
  }
}

/// A new quality of a category and the operations it would re-rate if the past follows.
struct PastQualityQuestion: Identifiable {
  let change: CategoryQualityChange
  let ids: [UUID]

  var id: UUID { change.categoryId }
}

/// The words of the question, kept apart from the dialog so a test can read them.
@MainActor
enum CategoryQualityText {
  static func title(_ language: AppLanguage) -> String {
    language("categories.pastQuality.title", table: table)
  }

  /// «Оценка изменится у N операций. Оценки, поставленные вручную, не меняются.»
  static func message(_ count: Int, _ language: AppLanguage) -> String {
    language.format("categories.pastQuality.message", table: table, count)
  }

  static func apply(_ language: AppLanguage) -> String {
    language("categories.pastQuality.apply", table: table)
  }

  static func keep(_ language: AppLanguage) -> String {
    language("categories.pastQuality.keep", table: table)
  }

  private static let table = "Settings"
}

/// The words of the question asked before a category goes, apart from the sheet so a test
/// reads them in both languages.
@MainActor
enum CategoryDeletionText {
  /// The count goes in as a plural of its own, verb included — «лежит 1 операция», «лежат
  /// 2 операции» — one argument per plural, as everywhere in the catalogs.
  static func message(
    _ question: CategoriesSettingsView.CategoryDeletion, _ language: AppLanguage
  ) -> String {
    let name = question.category.name
    func sentence(_ key: String, _ plural: String, _ count: Int) -> String {
      language.format(key, table: table, name, language.format(plural, table: table, count))
    }
    if question.blocked {
      return sentence(
        "categories.delete.blocked", "categories.delete.blocked.count", question.binned)
    }
    if question.live > 0 {
      return sentence("categories.delete.used", "categories.delete.used.count", question.live)
    }
    if question.children > 0 {
      return sentence(
        "categories.delete.withChildren", "categories.delete.withChildren.count",
        question.children)
    }
    return language.format("categories.delete.free", table: table, name)
  }

  private static let table = "Settings"
}

/// The question asked before a category goes: what points at it, where its operations move,
/// and the two ways out. A sheet rather than a dialog — a dialog cannot hold a picker.
private struct CategoryDeletionSheet: View {
  @Dependency(\.environment) private var environment
  let question: CategoriesSettingsView.CategoryDeletion
  @Binding var moveTo: UUID?
  let options: [(id: UUID, name: String)]
  let title: String
  let message: String
  let archive: () -> Void
  let delete: () -> Void
  let cancel: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(verbatim: title)
        .font(.headline)
      Text(verbatim: message)
        .fixedSize(horizontal: false, vertical: true)

      if question.live > 0, !question.blocked {
        Picker(selection: $moveTo) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(options, id: \.id) { option in
            Text(verbatim: option.name).tag(UUID?.some(option.id))
          }
        } label: {
          Text(verbatim: environment.language("categories.delete.moveTo", table: "Settings"))
        }
        .accessibilityIdentifier("categories.delete.moveTo")
      }

      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel, action: cancel)
          .keyboardShortcut(.cancelAction)
        if question.blocked {
          Button(environment.language("references.archive", table: "Settings"), action: archive)
            .buttonStyle(.borderedProminent)
        } else {
          Button(
            environment.language("references.delete", table: "Settings"), role: .destructive,
            action: delete
          )
          .buttonStyle(.borderedProminent)
          .disabled(question.live > 0 && moveTo == nil)
          .accessibilityIdentifier("categories.delete.confirm")
        }
      }
    }
    .padding(20)
    .frame(width: 460)
  }
}
