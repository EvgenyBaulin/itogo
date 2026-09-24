import AppCore
import AppDatabase
import SwiftUI

/// Chips under the entry line: operations I repeat often, plus the ones I pinned myself.
/// Tapping a chip fills the line, so the next step is still Enter.
struct TemplatesStrip: View {
  let model: TemplatesModel
  @Dependency(\.environment) private var environment
  let onPick: (Template) -> Void

  /// A pin the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false

  var body: some View {
    ScrollView(.horizontal) {
      HStack(spacing: 8) {
        ForEach(model.templates.prefix(8), id: \.id) { template in
          Button {
            onPick(template)
            model.use(template)
          } label: {
            HStack(spacing: 4) {
              if template.pinned {
                Image(systemName: "pin.fill").font(.caption2)
              }
              Text(verbatim: title(for: template))
            }
          }
          .buttonStyle(.glass)
          .controlSize(.small)
          .contextMenu {
            Button(
              environment.language(
                template.pinned ? "templates.unpin" : "templates.pin", table: "Entry")
            ) {
              if !model.togglePin(template) { refused = true }
            }
          }
        }
      }
      .padding(.horizontal, 2)
    }
    .scrollIndicators(.never)
    .frame(height: model.templates.isEmpty ? 0 : 34)
    .opacity(model.templates.isEmpty ? 0 : 1)
    .refusedWriteAlert($refused, environment)
  }

  private func title(for template: Template) -> String {
    guard let amount = template.amountE4 else { return template.text }
    return
      "\(template.text) \(environment.money.rounded(amount, currency: template.currency ?? .rub))"
  }
}

/// The chips the strip shows, and every write that changes them. The entry line saves through
/// the same model the strip reads, so a chip appears with the first save of its words and a
/// count or an amount moves with the next one — the strip used to read the templates only when
/// it appeared, and the line wrote them behind its back. `EntryBar` also reads them again after
/// every change of the data (a restore, an archive brought in).
@MainActor
@Observable
final class TemplatesModel {
  private(set) var templates: [Template] = []
  @ObservationIgnored private var references: ReferenceRepository?

  /// The dictionaries of the window, handed over when the entry line appears.
  func attach(_ references: ReferenceRepository?) {
    self.references = references
    reload()
  }

  func reload() {
    templates = (try? references?.templates()) ?? []
  }

  /// An operation the line saved: remembered as a chip when a chip can say it again, and the
  /// strip shows it at once.
  func remember(_ draft: TransactionDraft, categories: [CoreKit.Category]) {
    Templates.remember(draft, categories: categories, in: references)
    reload()
  }

  /// A chip picked counts as one more use. Bookkeeping the owner did not ask for: a refused
  /// count goes to the journal only.
  func use(_ template: Template) {
    var updated = template
    updated.useCount += 1
    AppEnvironment.attempt("templates.count", on: references) { try $0.save(updated) }
    reload()
  }

  /// Pins a chip or takes its pin off, and says whether the write landed: a refused pin is
  /// the owner's own choice lost, so the strip says so (`refusedWriteAlert`).
  @discardableResult
  func togglePin(_ template: Template) -> Bool {
    var updated = template
    updated.pinned.toggle()
    let written = AppEnvironment.attempt("templates.save", on: references) {
      try $0.save(updated)
    }
    reload()
    return written
  }
}

/// What a chip is made of and what it gives back. A chip puts a line into the entry line and
/// Enter saves what that line says, so the line says everything the template knows: «+» for an
/// income, the amount, the code of a currency other than the ruble. The templates table keeps
/// no kind, so an income is told by its category:
/// an operation filed under an income category is income, the panel keeps the two in step.
enum Templates {
  /// The line a chip puts into the entry line: «+ подарок 5000», «lunch 20.5 USD». The «+»
  /// stands apart — glued to the word it would stay in the description.
  static func line(for template: Template, categories: [CoreKit.Category]) -> String {
    var words: [String] = []
    if isIncome(template.categoryId, among: categories) { words.append("+") }
    words.append(template.text)
    if let amount = template.amountE4 { words.append("\(amount.decimal)") }
    if let currency = template.currency, currency != .rub { words.append(currency.code) }
    return words.joined(separator: " ")
  }

  /// Whether a chip can enter this operation again: only what its line can say. An expense,
  /// or an income filed under an income category — without a category an income would come
  /// back as an expense. A refund, money given back, a payment of a debt and a contribution to
  /// a goal need words the template does not keep (the kind, the debt, the goal), and their
  /// chip would enter a plain expense instead; they are not made chips.
  static func canRemember(_ draft: TransactionDraft, categories: [CoreKit.Category]) -> Bool {
    guard draft.debtId == nil, !draft.parts.contains(where: { $0.goalId != nil }) else {
      return false
    }
    switch draft.kind {
    case .expense: return true
    case .income: return isIncome(draft.parts.first?.categoryId, among: categories)
    case .refund, .reimbursement: return false
    }
  }

  /// Remembers what I enter, so the chips fill themselves from real usage. A template follows
  /// its last use: the amount, the currency, and the category unless the operation had none —
  /// but never a category of the other kind, which would turn the chip into an income (or out
  /// of one) the operation was not.
  static func remember(
    _ draft: TransactionDraft, categories: [CoreKit.Category], in references: ReferenceRepository?
  ) {
    guard let note = draft.note, !note.trimmingCharacters(in: .whitespaces).isEmpty,
      canRemember(draft, categories: categories)
    else { return }
    let categoryId = draft.parts.first?.categoryId
    // The operation itself is saved by then; a template refused goes to the journal only. A
    // list that could not be read writes nothing, rather than a second chip of the same text.
    AppEnvironment.attempt("templates.remember", on: references) { references in
      let existing = try references.templates()
      if var template = existing.first(where: {
        $0.text.caseInsensitiveCompare(note) == .orderedSame
      }) {
        let keepsItsCategory =
          isIncome(template.categoryId, among: categories) == (draft.kind == .income)
        template.useCount += 1
        template.amountE4 = draft.amount
        template.currency = draft.currency
        template.categoryId = categoryId ?? (keepsItsCategory ? template.categoryId : nil)
        try references.save(template)
      } else {
        try references.save(
          Template(
            text: note, categoryId: categoryId, amountE4: draft.amount, currency: draft.currency,
            useCount: 1))
      }
    }
  }

  private static func isIncome(_ categoryId: UUID?, among categories: [CoreKit.Category]) -> Bool {
    guard let categoryId else { return false }
    return categories.first { $0.id == categoryId }?.kind == .income
  }
}
