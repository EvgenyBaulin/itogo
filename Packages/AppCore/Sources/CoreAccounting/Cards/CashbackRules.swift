import CoreKit
import Foundation

/// What is wrong with a set of cashback rules about to be saved.
public enum CashbackRuleIssue: Hashable, Sendable {
  /// Two rules of one holder, month and category.
  case duplicate(CashbackRuleKey)
  /// A rule names a category that is not an expense category.
  case categoryNotExpense(UUID)
  /// A rule names «Цели» or a goal under it: a contribution moves no card money.
  case categoryIsGoal(UUID)
  /// A rule names the category of a reconciliation difference, which is bookkeeping.
  case categoryIsReconciliation(UUID)
  /// A rule of the account itself, while the account has live cards: rules live on the cards.
  case holderHasCards(UUID)
}

/// Editing the cashback rules: a sheet's save, «Запомнить» of the ↓ panel, the first card of an
/// account, «Как в прошлом месяце».
public enum CashbackRules {
  /// The rule to write for «Запомнить»: a rule already kept for the same holder, month and
  /// category gives its id, so the one row takes the new percent and ⌘Z brings the old one back.
  public static func upserting(_ rule: CashbackRule, into existing: [CashbackRule]) -> CashbackRule
  {
    guard let kept = existing.first(where: { $0.key == rule.key }) else { return rule }
    var result = rule
    result.id = kept.id
    return result
  }

  /// What a save of the rules sheet writes, by key — holder, month, category —, not by row: a
  /// key there before and after keeps its row and takes the new percent, a key gone is deleted,
  /// a new key is added as a row of its own — with the id it came with when that id is new, with
  /// a new id when its row held a rule of another key (the owner picked another category), since
  /// that rule is deleted in the same save. Two rows of the sheet swapped, a rule taken away and
  /// added again, or a row moved to another category then never meet the database's
  /// one-rule-per-key index halfway and never lose a rule. A key whose percent did not change
  /// writes nothing. `old` and `new` are the rules of the holders the sheet edits.
  public static func diff(
    old: [CashbackRule], new: [CashbackRule]
  ) -> (upserts: [CashbackRule], deletions: [UUID]) {
    var oldByKey: [CashbackRuleKey: CashbackRule] = [:]
    for rule in old where oldByKey[rule.key] == nil { oldByKey[rule.key] = rule }
    let oldIds = Set(old.map(\.id))
    var upserts: [CashbackRule] = []
    var kept: Set<CashbackRuleKey> = []
    for rule in new where kept.insert(rule.key).inserted {
      if let previous = oldByKey[rule.key] {
        guard previous.percent != rule.percent else { continue }
        var updated = previous
        updated.percent = rule.percent
        upserts.append(updated)
      } else {
        var added = rule
        // The row held a rule of a key that is gone: that rule is deleted below, or kept for
        // its own key, so the new key must not write over it.
        if oldIds.contains(added.id) { added.id = UUID() }
        upserts.append(added)
      }
    }
    let deletions = old.filter { !kept.contains($0.key) }.map(\.id)
    return (upserts, deletions)
  }

  /// What is wrong with the rules about to be saved. `cards` are every card, to tell an account
  /// with live cards; `reconcileCategoryIds` the categories of reconciliation differences.
  public static func issues(
    _ rules: [CashbackRule], tree: CategoryTree, cards: [PaymentCard],
    reconcileCategoryIds: Set<UUID> = []
  ) -> [CashbackRuleIssue] {
    var issues: [CashbackRuleIssue] = []
    var seen: Set<CashbackRuleKey> = []
    for rule in rules {
      if !seen.insert(rule.key).inserted { issues.append(.duplicate(rule.key)) }
      if rule.cardId == nil,
        cards.contains(where: { $0.accountId == rule.accountId && !$0.archived })
      {
        issues.append(.holderHasCards(rule.accountId))
      }
      guard let categoryId = rule.categoryId else { continue }
      if let category = tree.category(categoryId), category.kind != .expense {
        issues.append(.categoryNotExpense(categoryId))
      } else if tree.isGoalCategory(categoryId) {
        issues.append(.categoryIsGoal(categoryId))
      } else if isReconciliation(categoryId, tree: tree, reconcileCategoryIds) {
        issues.append(.categoryIsReconciliation(categoryId))
      }
    }
    return issues
  }

  /// The first live card of an account takes the account's own rules: the same rows, moved onto
  /// the card, so what the account earned it keeps earning with the card that now pays.
  public static func movedToFirstCard(_ card: PaymentCard, rules: [CashbackRule]) -> [CashbackRule]
  {
    rules.filter { $0.accountId == card.accountId && $0.cardId == nil }.map { rule in
      var moved = rule
      moved.cardId = card.id
      return moved
    }
  }

  /// «Как в прошлом месяце»: the month rules of `holder` in `from`, copied into `to` with new
  /// ids; a key `to` already has stays as it is.
  public static func copied(
    month from: MonthKey, to: MonthKey, holder: CashbackHolder, rules: [CashbackRule]
  ) -> [CashbackRule] {
    let taken = Set(rules.filter { $0.holder == holder && $0.month == to }.map(\.categoryId))
    return rules.filter {
      $0.holder == holder && $0.month == from && !taken.contains($0.categoryId)
    }
    .map { rule in
      CashbackRule(
        accountId: rule.accountId, cardId: rule.cardId, categoryId: rule.categoryId, month: to,
        percent: rule.percent)
    }
  }

  /// The categories a rule may name: live expense categories, system ones included — «Кредиты
  /// — 0 %» is how a loan payment is kept out —, without the tree of «Цели» and without the
  /// categories of reconciliation differences. Parents first, each followed by its children, in
  /// the order of the tree.
  public static func categoryChoices(
    tree: CategoryTree, categories: [CoreKit.Category], reconcileCategoryIds: Set<UUID>
  ) -> [CoreKit.Category] {
    func allowed(_ category: CoreKit.Category) -> Bool {
      category.kind == .expense && !category.archived && !tree.isGoalCategory(category.id)
        && !isReconciliation(category.id, tree: tree, reconcileCategoryIds)
    }
    func order(_ left: CoreKit.Category, _ right: CoreKit.Category) -> Bool {
      if left.sort != right.sort { return left.sort < right.sort }
      if left.name != right.name {
        return left.name.compare(right.name, options: [.caseInsensitive]) == .orderedAscending
      }
      return left.id.uuidString < right.id.uuidString
    }
    var result: [CoreKit.Category] = []
    for parent in categories.filter({ $0.parentId == nil && allowed($0) }).sorted(by: order) {
      result.append(parent)
      result.append(
        contentsOf: categories.filter { $0.parentId == parent.id && allowed($0) }.sorted(by: order))
    }
    return result
  }

  private static func isReconciliation(
    _ categoryId: UUID, tree: CategoryTree, _ reconcileCategoryIds: Set<UUID>
  ) -> Bool {
    reconcileCategoryIds.contains(categoryId)
      || tree.parent(of: categoryId).map { reconcileCategoryIds.contains($0.id) } == true
  }
}
