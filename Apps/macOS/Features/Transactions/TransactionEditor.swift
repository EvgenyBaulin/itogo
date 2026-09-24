import AppCore
import Observation
import SwiftUI

/// One saved operation being edited: the ↓ panel's model bound to it, what it was when the
/// editing began, and what the editor has to say — an error, a deletion waiting for the
/// owner's word. The edit sheet of the main window and the inspector of the Transactions
/// window hold one each.
@MainActor
@Observable
final class TransactionEditorModel {
  /// The operation as it was when the editing began.
  let entry: TransactionEntry
  /// What names it in the table: the head of the inspector.
  let title: RowTitle
  let draft: EntryDraftModel
  /// The draft as the panel first showed it: anything else is an unsaved change.
  private let baseline: TransactionDraft
  var errorKey: String?
  /// Deleting asks first, the same question the list asks.
  var confirmation: BulkConfirmation?

  /// The operation being edited.
  var id: UUID { entry.id }

  /// `tree` names the operation by its category when it has no description.
  init(entry: TransactionEntry, environment: AppEnvironment, tree: CategoryTree = CategoryTree()) {
    self.entry = entry
    self.title = RowTitle.of(entry, tree: tree)
    let draft = EntryDraftModel(environment: environment, editsSavedOperation: true)
    draft.reload()
    draft.draft = TransactionDraft(entry: entry)
    self.draft = draft
    self.baseline = draft.draft
  }

  /// Something was changed and not saved yet: switching to another operation asks first.
  var hasChanges: Bool { draft.draft != baseline }

  /// What becomes of the editor when the data under it changes.
  enum Follow: Equatable {
    /// It stays as it is.
    case stay
    /// The operation is gone and nothing was typed: nothing is left to edit.
    case close
    /// Changed elsewhere while nothing was typed: an editor of the operation as it is now
    /// takes this one's place, so a save cannot bring the old version back.
    case reopen(TransactionEntry)
  }

  /// Follows the operation as the data has it now — `nil` once it is gone. An edit typed and
  /// not saved is never thrown away here: an operation deleted meanwhile (⌘Z of its creation,
  /// a bulk deletion) leaves the edit in place with the reason it cannot be saved, and the
  /// reason goes again when the operation comes back (⌘Z of the deletion). «Save» lays the
  /// edit over the operation as it is then (`TransactionsStore.saveEdit`).
  func follow(_ fresh: TransactionEntry?) -> Follow {
    guard hasChanges else {
      guard let fresh else { return .close }
      return fresh == entry ? .stay : .reopen(fresh)
    }
    if fresh == nil {
      errorKey = Self.goneKey
    } else if errorKey == Self.goneKey {
      errorKey = nil
    }
    return .stay
  }

  /// «The operation has been deleted, so the changes were not saved».
  private static let goneKey = "entry.error.gone"

  /// Whether «Save» can be pressed: the draft keeps the rules of the panel
  /// (`EntryDraftModel.saveRefusalKey`), and no large write is landing — it may be deleting
  /// this very operation, and a save queued in front of it would leave a step of ⌘Z above the
  /// deletion that brings the operation back («Delete…» waits for it too).
  func canSave(in store: TransactionsStore) -> Bool {
    draft.canSave && !store.isWritingInBackground
  }

  /// Saves the edit. The editor stays open when the change did not land: closing it would
  /// look exactly like saving, and the edit would be gone.
  ///
  /// Every way to save goes through here — the button, and «Save» in the question asked
  /// when another operation is opened — so the rule of the button is checked here as well.
  /// The edit is laid over the operation as it is now (`TransactionsStore.saveEdit`).
  func save(store: TransactionsStore, environment: AppEnvironment) -> Bool {
    if let refusal = draft.saveRefusalKey {
      errorKey = refusal
      return false
    }
    guard !store.isWritingInBackground else {
      errorKey = "entry.error.notSaved"
      return false
    }
    environment.applyRate(to: &draft.draft)
    let updated: TransactionEntry
    do {
      updated = try Self.edited(
        entry, with: draft.draft, rublesConverter: environment.rublesConverter(for: draft.draft))
    } catch MoneyConversionError.rateMissing {
      errorKey = "entry.error.rateMissing"
      return false
    } catch {
      errorKey = "entry.error.notSaved"
      return false
    }
    switch store.saveEdit(updated, calendar: environment.calendar) {
    case .saved:
      errorKey = nil
      CategoryLearning.saved(
        updated, replacing: entry, choice: categoryChoice(), environment: environment)
      return true
    case .gone:
      // Deleted elsewhere meanwhile: the edit stays, with the reason, until «Cancel» — in
      // the sheet and in the inspector alike (`follow`).
      errorKey = Self.goneKey
      return false
    case .failed:
      errorKey = "entry.error.notSaved"
      return false
    case .declined(let refusal):
      errorKey = Self.errorKey(of: refusal)
      return false
    case .refused:
      errorKey = "entry.error.noDependencies"
      return false
    }
  }

  /// The choice of a category made in this editing, if one was: a category left as it was
  /// saved is not chosen again by opening the operation.
  private func categoryChoice() -> CategoryFeedback? {
    guard let choice = draft.categoryChoice(),
      baseline.parts.first(where: { $0.id == choice.partId })?.categoryId
        != choice.chosenCategoryId
    else { return nil }
    return choice
  }

  /// What the editor says when the store declines the edit.
  nonisolated static func errorKey(of refusal: EditRefusal) -> String {
    switch refusal {
    case .debtCurrency: "entry.error.debtCurrency"
    case .settledReimbursement: "entry.error.reimbursementEdit"
    case .closedPartRemoved: "entry.error.closedPartRemoved"
    case .closedPartChanged: "entry.error.closedPartChanged"
    }
  }

  func requestDeletion(store: TransactionsStore) {
    confirmation = BulkConfirmation.deletion(of: [entry], debts: store.debts)
  }

  /// The saved operation after the edit. Only what the panel edits changes: when the
  /// operation was created, which import it came from and how far its parts paid for others
  /// have come back stay as they were (`TransactionEntry.rebased(onto:)`); otherwise an
  /// edited bank row would lose the key that stops it from being imported twice.
  nonisolated static func edited(
    _ original: TransactionEntry, with draft: TransactionDraft,
    now: Date = Date(),
    rublesConverter: (AmountE4) throws -> AmountE4
  ) throws -> TransactionEntry {
    try draft.materialize(updating: original, now: now, rublesConverter: rublesConverter)
  }
}

/// The editing of one saved operation: the same ↓ panel the entry line uses, bound to it,
/// with «Delete…» on the left and «Cancel» and «Save» on the right. The main window shows it
/// in a sheet, the Transactions window in its inspector; content is never glass.
struct TransactionEditor: View {
  enum Style {
    /// The sheet of the main window: wide, with a title of its own.
    case sheet
    /// The inspector of the Transactions window: narrow, headed by the operation itself.
    case inspector
  }

  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  @Bindable var editor: TransactionEditorModel
  let style: Style
  /// Called when the editing is over: saved, cancelled, or the operation deleted.
  let close: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: style == .sheet ? 16 : 12) {
      header
      ScrollView {
        DetailsPanel(model: editor.draft)
          .padding(.vertical, 2)
      }
      .frame(minWidth: style == .sheet ? 620 : nil, minHeight: style == .sheet ? 360 : nil)

      // Wraps in the width it is given, never fixed to its full height: the inspector is a
      // column of a split view, and a text fixed that way made the column's minimum the text
      // wrapped at a width of zero — a character a line, taller than the window — so a long
      // message («no rate yet», «deleted», a refusal) made the window loop until AppKit threw
      // (`testEveryMessageOfTheEditorLeavesTheInspectorSettled`).
      if let errorKey = editor.errorKey {
        Text(verbatim: environment.language(errorKey, table: "Entry"))
          .font(.caption)
          .foregroundStyle(.red)
      }

      // Named, not read by their captions: every confirmation of the Transactions window has
      // a «Cancel» of its own, and switching operations replaces the whole inspector
      // (`.id(ObjectIdentifier(editor))`), so two can stand there for one frame. A UI test
      // that asked for «Cancel» found several and refused to act (`make test-ui`, 21.09).
      HStack {
        Button(
          environment.language("selection.delete", table: "Transactions"), role: .destructive
        ) {
          editor.requestDeletion(store: store)
        }
        .disabled(store.isWritingInBackground)
        .accessibilityIdentifier("editor.delete")
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel, action: close)
          .accessibilityIdentifier("editor.cancel")
        Button(environment.language("action.save")) {
          if editor.save(store: store, environment: environment) { close() }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!editor.canSave(in: store))
        .accessibilityIdentifier("editor.save")
      }
    }
    .padding(style == .sheet ? 20 : 14)
    .bulkConfirmation($editor.confirmation) { landed in
      if landed {
        close()
      } else {
        editor.errorKey = "entry.error.notSaved"
      }
    }
  }

  @ViewBuilder
  private var header: some View {
    switch style {
    case .sheet:
      Text(verbatim: environment.language("action.edit"))
        .font(.headline)
    case .inspector:
      // The operation as it is named in the table, and when it happened.
      VStack(alignment: .leading, spacing: 2) {
        RowTitleText(title: editor.title)
          .font(.headline)
          .lineLimit(2)
        Text(verbatim: environment.dates.moment(editor.entry.transaction.occurredAt))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// The title of an operation in a list: its description, or — in the secondary style — its
/// category or kind.
struct RowTitleText: View {
  @Dependency(\.environment) private var environment
  let title: RowTitle

  var body: some View {
    switch title {
    case .note(let note):
      Text(verbatim: note)
    case .category(let path):
      Text(verbatim: CategoryPathText.text(path, language: environment.language))
        .foregroundStyle(.secondary)
    case .kind(let kind):
      Text(verbatim: environment.language("kind.\(kind.rawValue)"))
        .foregroundStyle(.secondary)
    }
  }
}

/// «Category › Subcategory», with «(archived)» after a retired one.
@MainActor
enum CategoryPathText {
  static func text(_ path: CategoryPath, language: AppLanguage) -> String {
    path.archived ? language.format("common.archivedName", path.text) : path.text
  }
}
