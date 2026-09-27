import CoreKit
import Foundation

/// A field the entry line could not fill, which the ↓ panel asks for before a new operation is
/// saved.
public enum EntryGap: String, Sendable, Hashable, CaseIterable {
  /// No category, or one of the other kind: the line did not say where the money goes.
  case category
  /// A category with subcategories that the model filled in, without saying which of them.
  case subcategory
}

/// Whether a new operation lacks a field the entry line should have told: by the time the line
/// is applied, the first part carries every source the app has — a goal or a debt the line
/// named, the operation most like it (history), the model when it is sure, a chip, a template or
/// the owner's own choice in the panel. What is still missing then is the owner's to choose.
public enum EntryCompleteness {
  /// The field a new operation still lacks, or nil. Rules, the first that applies wins:
  /// 1. a kind without a category field (money back) — nil;
  /// 2. a split — nil: the owner built it in the panel, with every part's pickers in view;
  /// 3. a payment on a debt — nil: Loans is filled when its payments are spending, and a
  ///    payment that only moves the debt is not spending and has no category by design;
  /// 4. a contribution to a goal — a goal, or a category under Goals — nil: the goal row
  ///    governs it;
  /// 5. a refund taken back from a purchase — nil: it has the purchase's category;
  /// 6. no category, or one of the other kind — `.category`;
  /// 7. a category the tree does not know, a subcategory, a category of the app (Goals, Loans,
  ///    «Не помню», «Доплаты»), or a top-level one without live children of its kind — nil;
  /// 8. a top-level category with live children: filled by the model — `.subcategory`; filled
  ///    by history, a chip, a template or the owner — nil, that is how the owner files it.
  public static func gap(of draft: TransactionDraft, tree: CategoryTree) -> EntryGap? {
    guard KindFields.fields(of: draft.kind).contains(.category) else { return nil }
    guard draft.parts.count == 1, let part = draft.parts.first else { return nil }
    guard draft.debtId == nil else { return nil }
    guard
      !QualityResolver.isGoalContribution(
        goalId: part.goalId, categoryId: part.categoryId, categories: tree)
    else { return nil }
    guard part.refundOfPartId == nil else { return nil }
    guard let categoryId = part.categoryId else { return .category }
    guard let category = tree[categoryId] else { return nil }
    guard category.kind == draft.kind.categoryKind else { return .category }
    guard category.parentId == nil, tree.systemRole(of: category.id) == nil else { return nil }
    let liveChildren = tree.children(of: category.id).filter {
      !$0.archived && $0.kind == category.kind
    }
    guard !liveChildren.isEmpty else { return nil }
    return part.categorySource == .model ? .subcategory : nil
  }
}
