import AppCore
import SwiftUI

/// Editing an operation in the main window: a double click in the list opens the shared
/// `TransactionEditor` — the same ↓ panel the entry line uses, bound to the saved operation
/// — in a sheet. Saving replaces it; ⌘Z brings the old version back. The Transactions window
/// shows the same editor in its inspector.
struct EditTransactionSheet: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dismiss) private var dismiss

  let entry: TransactionEntry
  @State private var editor: TransactionEditorModel?

  var body: some View {
    Group {
      if let editor {
        TransactionEditor(editor: editor, style: .sheet) { dismiss() }
      } else {
        ProgressView()
          .padding(20)
      }
    }
    .onAppear {
      if editor == nil { editor = TransactionEditorModel(entry: entry, environment: environment) }
    }
  }

  /// The saved operation after the edit; see `TransactionEditorModel.edited`.
  nonisolated static func edited(
    _ original: TransactionEntry, with draft: TransactionDraft,
    now: Date = Date(),
    rublesConverter: (AmountE4) throws -> AmountE4
  ) throws -> TransactionEntry {
    try TransactionEditorModel.edited(
      original, with: draft, now: now, rublesConverter: rublesConverter)
  }
}
