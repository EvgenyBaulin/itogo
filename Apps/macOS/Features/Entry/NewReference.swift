import AppCore
import Foundation

/// A new row of a dictionary as every screen that adds one makes it: the tabs of Settings and
/// the sheet that «Add…» of a picker opens in the ↓ panel. What a new row starts with — the
/// quality of a new category, which payment method is the default, the days of an event — is
/// decided here once, so the two ways of adding cannot drift apart.
enum NewReference {
  /// A category of `kind`, a subcategory when `parent` is given, placed after every category
  /// there is. A new top-level expense category starts neutral, as every category the owner
  /// has not rated yet; a subcategory has no quality of its own and takes its parent's, and
  /// income is never rated. Nil when `parent` cannot take a category of `kind`.
  static func category(
    named name: String, kind: CategoryKind, parent: UUID?, among all: [CoreKit.Category]
  ) -> CoreKit.Category? {
    guard acceptsParent(parent, for: kind, in: all) else { return nil }
    return CoreKit.Category(
      parentId: parent, kind: kind, name: name, sort: all.count,
      quality: parent == nil && kind == .expense ? .neutral : nil)
  }

  /// Whether a new category of `kind` may be filed under `parent`: under nothing, or under a
  /// live top-level category of the same kind. The dictionary is two levels deep, and the
  /// schema ties nothing to the parent's kind, so this is the check: an income category filed
  /// under an expense root would be listed there with a quality picker, reported by the tree
  /// as an expense and offered by no form.
  static func acceptsParent(
    _ parent: UUID?, for kind: CategoryKind, in categories: [CoreKit.Category]
  ) -> Bool {
    guard let parent else { return true }
    guard let root = categories.first(where: { $0.id == parent }) else { return false }
    return root.parentId == nil && root.kind == kind && !root.archived
  }

  /// A payment method of `kind`. The first one in the book is the default: the entry line puts
  /// the default method on every operation that names none, and a book with methods but no
  /// default would leave them all empty.
  static func paymentMethod(
    named name: String, kind: PaymentMethodKind = .card, among live: [PaymentMethod]
  ) -> PaymentMethod {
    PaymentMethod(name: name, kind: kind, isDefault: live.isEmpty)
  }

  /// An event from `start` to `end`. It ends on or after the day it starts, or it would cover
  /// no day at all: an end before the start is the start itself.
  static func event(named name: String, from start: DateOnly, to end: DateOnly) -> Event {
    Event(name: name, startDate: start, endDate: max(start, end))
  }
}
