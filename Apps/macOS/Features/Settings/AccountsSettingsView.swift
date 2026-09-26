import AppCore
import AppDatabase
import SwiftUI

/// Settings → Счета: every account and group, the archived ones too.
///
/// The accounts are listed the way every menu lists them — the main account first and marked,
/// then in the order the owner dragged them to, alphabetical until then — and can be dragged,
/// put back in alphabetical order, edited, made main, merged, archived and brought back, and
/// deleted while nothing points at them. The groups carry «Учитывать в общей сводке». Each
/// change is one step of ⌘Z, but a merge and a deletion, which are not undone.
struct AccountsSettingsView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies

  @State private var accounts: [PaymentMethod] = []
  @State private var groups: [AccountGroup] = []
  /// Accounts picked in the list, for «Удалить» of several unused ones at once.
  @State private var selection: Set<UUID> = []
  @State private var showsArchive = false
  @State private var sheet: Sheet?
  /// What the last action was refused for, said under the list.
  @State private var refusal: AccountRefusal?
  /// The deletion the owner asked for, waiting for the answer.
  @State private var deleting: Deletion?
  /// The group the owner asked to delete, waiting for the answer.
  @State private var deletingGroup: AccountGroup?
  /// A write the database refused; the alert says so.
  @State private var failed = false

  /// What the tab shows over itself.
  enum Sheet: Identifiable {
    case account(PaymentMethod?)
    case group(AccountGroup?)
    case merge(PaymentMethod, into: UUID?)
    case handOver(PaymentMethod, Hand, candidates: [PaymentMethod], preselected: UUID?)

    /// What the main account is leaving for: the archive, or a deletion of these accounts —
    /// the main one and any others picked with it.
    enum Hand {
      case archive
      case delete([UUID])
    }

    var id: String {
      switch self {
      case .account(let account): "account.\(account?.id.uuidString ?? "new")"
      case .group(let group): "group.\(group?.id.uuidString ?? "new")"
      case .merge(let account, _): "merge.\(account.id.uuidString)"
      case .handOver(let account, _, _, _): "handOver.\(account.id.uuidString)"
      }
    }
  }

  /// Accounts about to be deleted for good, asked first.
  struct Deletion: Identifiable {
    let ids: [UUID]
    let names: [String]
    var id: [UUID] { ids }
  }

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  private func t(_ key: String) -> String { environment.language(key, table: "Accounts") }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Toggle(isOn: $showsArchive) {
          Text(verbatim: t("accounts.showArchive"))
        }
        .toggleStyle(.checkbox)
        Spacer()
        Button(t("accounts.alphabetize")) { perform(actions.alphabetize()) }
          .disabled(!live.contains { $0.sort != 0 } || store.isWritingInBackground)
          .help(t("accounts.alphabetizeHint"))
        Button {
          sheet = .group(nil)
        } label: {
          Label {
            Text(verbatim: t("accounts.newGroup"))
          } icon: {
            Image(systemName: "folder.badge.plus")
          }
        }
        Button {
          sheet = .account(nil)
        } label: {
          Label {
            Text(verbatim: t("accounts.newAccount"))
          } icon: {
            Image(systemName: "plus")
          }
        }
        .accessibilityIdentifier("accounts.newAccount")
      }
      list
      // Under the list, not as footers of its sections: a footer of a list is one line and
      // cuts these off.
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: t("accounts.orderHint"))
        Text(verbatim: t("accounts.groupsHint"))
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      footer
    }
    .padding()
    .onAppear(perform: reload)
    // A change made elsewhere — the sidebar, the setup, ⌘Z — shows here at once.
    .onChange(of: compute.generation) { reload() }
    .sheet(item: $sheet) { sheet in
      sheetContent(sheet).handingOver(dependencies)
    }
    .confirmationDialog(
      deleting.map(deleteTitle) ?? "", isPresented: isAskingToDelete, titleVisibility: .visible,
      presenting: deleting
    ) { question in
      Button(environment.language("action.delete"), role: .destructive) { delete(question) }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: { question in
      Text(verbatim: deleteMessage(count: question.ids.count))
    }
    .refusedWriteAlert($failed, environment)
  }

  // MARK: The list

  private var list: some View {
    List(selection: $selection) {
      Section {
        ForEach(live, id: \.id) { account in
          accountRow(account)
            .tag(account.id)
            .moveDisabled(account.isDefault)
        }
        .onMove { source, destination in
          perform(actions.reorder(from: source, to: destination))
        }
      } header: {
        Text(verbatim: t("accounts.section.accounts"))
      }

      Section {
        if liveGroups.isEmpty {
          Text(verbatim: t("accounts.noGroups"))
            .foregroundStyle(.secondary)
        }
        ForEach(liveGroups, id: \.id) { group in
          groupRow(group)
            .selectionDisabled()
        }
      } header: {
        Text(verbatim: t("accounts.section.groups"))
      }

      if showsArchive {
        Section {
          if archived.isEmpty && archivedGroups.isEmpty {
            Text(verbatim: t("accounts.archiveEmpty"))
              .foregroundStyle(.secondary)
          }
          ForEach(archived, id: \.id) { account in
            archivedRow(account)
              .tag(account.id)
          }
          ForEach(archivedGroups, id: \.id) { group in
            archivedGroupRow(group)
              .selectionDisabled()
          }
        } header: {
          Text(verbatim: t("accounts.section.archive"))
        }
      }
    }
    .frame(minHeight: 280)
    .accessibilityIdentifier("accounts.list")
    // A group is deleted for good and the ⌘Z history with it: asked first, like an account.
    .confirmationDialog(
      deletingGroup.map {
        environment.format("accounts.deleteGroup.title", table: "Accounts", $0.name)
      } ?? "",
      isPresented: isAskingToDeleteGroup, titleVisibility: .visible, presenting: deletingGroup
    ) { group in
      Button(environment.language("action.delete"), role: .destructive) {
        deletingGroup = nil
        perform(actions.deleteGroup(group.id))
      }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: { _ in
      Text(verbatim: t("accounts.deleteGroup.message"))
    }
    // The menu of the rows picked and the double click — or Return — that opens the editor,
    // the way a list of the system does it; a gesture of the row's own would take the click
    // from the selection.
    .contextMenu(forSelectionType: UUID.self) { ids in
      if ids.count == 1, let account = accounts.first(where: { ids.contains($0.id) }) {
        if account.archived {
          archivedMenuItems(account)
        } else {
          accountMenuItems(account)
        }
      } else if ids.count > 1 {
        Button(t("accounts.deleteSelected"), role: .destructive) { askToDelete(Array(ids)) }
      }
    } primaryAction: { ids in
      guard ids.count == 1, let account = accounts.first(where: { ids.contains($0.id) }) else {
        return
      }
      sheet = .account(account)
    }
  }

  private func accountRow(_ account: PaymentMethod) -> some View {
    HStack(spacing: 8) {
      Image(systemName: AccountText.kindSymbol(account.kind))
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(verbatim: account.name)
          if account.isDefault {
            // The main account is told by a symbol and a word, never by colour alone.
            Label {
              Text(verbatim: t("accounts.main"))
            } icon: {
              Image(systemName: "star.fill")
            }
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
        Text(verbatim: caption(of: account))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      accountMenu(account)
    }
  }

  /// Its kind, currencies — the main one first — and group.
  private func caption(of account: PaymentMethod) -> String {
    var parts = [t(AccountText.kindKey(account.kind))]
    parts.append(account.currencies.map(\.code).joined(separator: ", "))
    if let id = account.groupId, let group = groups.first(where: { $0.id == id }) {
      parts.append(AccountText.groupTitle(group, environment))
    }
    return parts.joined(separator: " · ")
  }

  /// The visible «…» of a row, the same items as its context menu.
  private func accountMenu(_ account: PaymentMethod) -> some View {
    Menu {
      accountMenuItems(account)
    } label: {
      Image(systemName: "ellipsis.circle")
        .accessibilityLabel(Text(verbatim: t("accounts.rowMenu")))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
  }

  @ViewBuilder
  private func accountMenuItems(_ account: PaymentMethod) -> some View {
    Button(t("accounts.edit")) { sheet = .account(account) }
    if !account.isDefault {
      Button(t("accounts.makeMain")) { perform(actions.makeMain(account.id)) }
      // The order without a drag, for the keyboard and VoiceOver; nothing goes above the
      // main account.
      let index = live.firstIndex { $0.id == account.id }
      Button(t("accounts.moveUp")) { perform(actions.move(account.id, by: -1)) }
        .disabled(index.map { $0 == 0 || live[$0 - 1].isDefault } ?? true)
      Button(t("accounts.moveDown")) { perform(actions.move(account.id, by: 1)) }
        .disabled(index.map { $0 == live.count - 1 } ?? true)
    }
    if !actions.mergeTargets(for: account).isEmpty {
      Button(t("accounts.mergeWith")) { sheet = .merge(account, into: nil) }
    }
    Divider()
    Button(t("accounts.archive")) { archive(account) }
    Button(t("accounts.delete"), role: .destructive) { askToDelete([account.id]) }
  }

  private func groupRow(_ group: AccountGroup) -> some View {
    let holdsMain = accounts.contains { $0.isDefault && !$0.archived && $0.groupId == group.id }
    let count = accounts.filter { $0.groupId == group.id && !$0.archived }.count
    return HStack(spacing: 8) {
      Image(systemName: group.inSummary ? "folder" : "eye.slash")
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: group.name)
        // Why its switch cannot be moved, said in words beside the greyed switch.
        Text(
          verbatim: holdsMain
            ? environment.format(
              "accounts.group.countWithMain", table: "Accounts", counts: count)
            : environment.format("accounts.group.count", table: "Accounts", counts: count)
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Toggle(
        isOn: Binding(
          get: { group.inSummary },
          set: { perform(actions.setInSummary(group.id, $0)) })
      ) {
        Text(verbatim: t("account.group.inSummary"))
      }
      .toggleStyle(.switch)
      .controlSize(.small)
      .fixedSize()
      .disabled(holdsMain || store.isWritingInBackground)
      .help(holdsMain ? t("account.group.holdsMain") : t("account.group.inSummaryHint"))
      Menu {
        groupMenuItems(group)
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel(Text(verbatim: t("accounts.rowMenu")))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { sheet = .group(group) }
    .contextMenu { groupMenuItems(group) }
  }

  @ViewBuilder
  private func groupMenuItems(_ group: AccountGroup) -> some View {
    Button(t("accounts.edit")) { sheet = .group(group) }
    Divider()
    Button(t("accounts.archive")) { perform(actions.archiveGroup(group.id)) }
    Button(t("accounts.delete"), role: .destructive) { askToDelete(group) }
  }

  private func archivedRow(_ account: PaymentMethod) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "archivebox")
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: account.name)
        Text(verbatim: caption(of: account))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button(t("accounts.restore")) { perform(actions.restore(account.id)) }
      Menu {
        archivedMenuItems(account)
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel(Text(verbatim: t("accounts.rowMenu")))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
    }
  }

  @ViewBuilder
  private func archivedMenuItems(_ account: PaymentMethod) -> some View {
    Button(t("accounts.restore")) { perform(actions.restore(account.id)) }
    Button(t("accounts.edit")) { sheet = .account(account) }
    Divider()
    Button(t("accounts.delete"), role: .destructive) { askToDelete([account.id]) }
  }

  private func archivedGroupRow(_ group: AccountGroup) -> some View {
    HStack(spacing: 8) {
      Image(systemName: "archivebox")
        .foregroundStyle(.secondary)
        .frame(width: 18)
        .accessibilityHidden(true)
      Text(verbatim: environment.format("accounts.archivedGroup", table: "Accounts", group.name))
      Spacer()
      Button(t("accounts.restore")) { perform(actions.restoreGroup(group.id)) }
      Button(t("accounts.delete"), role: .destructive) { askToDelete(group) }
    }
  }

  @ViewBuilder
  private var footer: some View {
    if let refusal {
      // An account in use cannot be deleted: the note offers a merge and the archive instead,
      // while it is live.
      AccountRefusalNote(
        refusal: refusal, restore: { perform(actions.restore($0)) },
        merge: mergeInstead(of: refusal), archive: archiveInstead(of: refusal))
    }
    if selection.count > 1 {
      HStack {
        Text(
          verbatim: environment.format(
            "accounts.selected", table: "Accounts", counts: selection.count)
        )
        .foregroundStyle(.secondary)
        Spacer()
        Button(t("accounts.deleteSelected"), role: .destructive) {
          askToDelete(Array(selection))
        }
        .disabled(store.isWritingInBackground)
      }
    }
  }

  /// «Объединить с…» for a live account a deletion was refused for, when it has a target.
  private func mergeInstead(of refusal: AccountRefusal) -> ((UUID) -> Void)? {
    guard let account = live.first(where: { $0.id == refusal.accountInUse }),
      !actions.mergeTargets(for: account).isEmpty
    else { return nil }
    return { _ in sheet = .merge(account, into: nil) }
  }

  /// «В архив» for a live account a deletion was refused for.
  private func archiveInstead(of refusal: AccountRefusal) -> ((UUID) -> Void)? {
    guard let account = live.first(where: { $0.id == refusal.accountInUse }) else { return nil }
    return { _ in archive(account) }
  }

  // MARK: Sheets

  @ViewBuilder
  private func sheetContent(_ sheet: Sheet) -> some View {
    switch sheet {
    case .account(let account):
      AccountEditor(previous: account, defaultCurrency: environment.defaultCurrency) { saved in
        self.sheet = nil
        if saved != nil { refusal = nil }
        reload()
      }
    case .group(let group):
      AccountGroupEditor(previous: group) { saved in
        self.sheet = nil
        if saved != nil { refusal = nil }
        reload()
      }
    case .merge(let account, let target):
      AccountMergeSheet(
        source: account, targets: actions.mergeTargets(for: account), preselected: target
      ) { merged in
        self.sheet = nil
        if merged {
          refusal = nil
          selection = []
        }
        reload()
      }
    case .handOver(let account, let hand, let candidates, let preselected):
      switch hand {
      case .archive:
        MainHandOverSheet(
          leaving: account, candidates: candidates, preselected: preselected,
          confirmTitle: t("accounts.archive"),
          confirm: { next in
            self.sheet = nil
            archive(account, newMain: next)
          },
          cancel: { self.sheet = nil })
      case .delete(let ids):
        // The choice of the new main account is also the confirmation of the deletion, so
        // the sheet says it cannot be undone.
        MainHandOverSheet(
          leaving: account, candidates: candidates, preselected: preselected,
          confirmTitle: t("accounts.delete"), note: deleteMessage(count: ids.count),
          confirm: { next in
            self.sheet = nil
            if perform(actions.delete(ids, newMain: next)) { selection = [] }
          },
          cancel: { self.sheet = nil })
      }
    }
  }

  // MARK: Actions

  /// Into the archive; the main account first asks which one takes over. Money still on the
  /// account keeps it out, and the note under the list says so.
  private func archive(_ account: PaymentMethod, newMain: UUID? = nil) {
    Task {
      guard let books = await actions.books() else {
        failed = true
        return
      }
      if account.isDefault, newMain == nil {
        // Money on it is said before the question of who takes over.
        if let reason = actions.archiveRefusal(account, books: books) {
          refusal = reason
          return
        }
        let next = actions.successors(leaving: account.id, books: books)
        sheet = .handOver(account, .archive, candidates: next.all, preselected: next.preselected)
        return
      }
      perform(actions.archive(account.id, newMain: newMain, books: books))
    }
  }

  /// Deleting: only accounts nothing points at, asked first. When the main account is among
  /// them, the question of who takes over — which none of the others can — asks it.
  private func askToDelete(_ ids: [UUID]) {
    guard let repository = environment.accounts else { return }
    for id in ids {
      if let usage = try? repository.usage(of: id), usage.isUsed {
        refusal = .inUse(id, usage)
        return
      }
    }
    if let main = accounts.first(where: { ids.contains($0.id) && $0.isDefault && !$0.archived }) {
      Task {
        guard let books = await actions.books() else {
          failed = true
          return
        }
        let next = actions.successors(leaving: Set(ids), books: books)
        sheet = .handOver(
          main, .delete(ids), candidates: next.all, preselected: next.preselected)
      }
      return
    }
    let names = accounts.filter { ids.contains($0.id) }.map(\.name)
    deleting = Deletion(ids: ids, names: names)
  }

  private func delete(_ question: Deletion) {
    deleting = nil
    if perform(actions.delete(question.ids)) { selection = [] }
  }

  private var isAskingToDelete: Binding<Bool> {
    Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
  }

  /// A group is asked about only when it can go: filed accounts, archived ones too, keep it.
  private func askToDelete(_ group: AccountGroup) {
    guard !accounts.contains(where: { $0.groupId == group.id }) else {
      refusal = .groupInUse
      return
    }
    deletingGroup = group
  }

  private var isAskingToDeleteGroup: Binding<Bool> {
    Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } })
  }

  /// That nothing refers to the account — or to the accounts — and that a deletion is not
  /// undone.
  private func deleteMessage(count: Int) -> String {
    t(count == 1 ? "accounts.delete.message" : "accounts.delete.messageMany")
  }

  private func deleteTitle(_ question: Deletion) -> String {
    question.names.count == 1
      ? environment.format("accounts.delete.titleOne", table: "Accounts", question.names[0])
      : environment.format(
        "accounts.delete.titleMany", table: "Accounts", counts: question.names.count)
  }

  /// Says what came of an action and shows the lists as they are now. Returns whether it was
  /// done.
  @discardableResult
  private func perform(_ outcome: AccountActionOutcome) -> Bool {
    switch outcome {
    case .done: refusal = nil
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
    reload()
    return outcome == .done
  }

  // MARK: Data

  private var live: [PaymentMethod] { actions.ordered(accounts) }

  private var archived: [PaymentMethod] {
    accounts.filter(\.archived).sorted {
      $0.name.compare($1.name, options: [.caseInsensitive], locale: environment.language.locale)
        == .orderedAscending
    }
  }

  private var liveGroups: [AccountGroup] { groups.filter { !$0.archived } }
  private var archivedGroups: [AccountGroup] { groups.filter(\.archived) }

  private func reload() {
    accounts = actions.all
    groups = actions.groups
    selection = selection.filter { id in accounts.contains { $0.id == id } }
  }
}
