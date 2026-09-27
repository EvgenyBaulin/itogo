import AppCore
import AppDatabase
import Foundation

/// The limits of the Planning section: a limit checked against the others, saved or deleted
/// as one change, one step of ⌘Z.
extension PlanningActions {
  /// Why the limit cannot be saved, or nil. «Сверка» and what is under it take none, like the
  /// system categories.
  func issue(of budget: Budget) -> BudgetIssue? {
    guard let tree else { return nil }
    return LimitRules.validate(
      budget, tree: tree, existing: snapshot?.dataset.planning.budgets ?? [],
      limitless: LimitWrites.limitless(environment, snapshot))
  }

  /// The same check for a form, which has the pipeline but not the whole set of dependencies;
  /// with the environment the reconciliation categories are read from the database now.
  static func issue(
    of budget: Budget, compute: ComputeStore, environment: AppEnvironment? = nil
  ) -> BudgetIssue? {
    guard let snapshot = compute.snapshot else { return nil }
    let limitless =
      environment.map { LimitWrites.limitless($0, snapshot) }
      ?? snapshot.dataset.planning.settings.limitlessCategoryIds
    return LimitRules.validate(
      budget, tree: snapshot.ledger.tree, existing: snapshot.dataset.planning.budgets,
      limitless: limitless)
  }

  @discardableResult
  func save(_ budget: Budget) -> Bool {
    guard issue(of: budget) == nil else { return false }
    // The row as the database has it now: the screen may not have caught up with the last edit.
    let stored =
      (try? environment.planning?.budgets()) ?? snapshot?.dataset.planning.budgets ?? []
    var rows = PlanningRows.empty
    rows.budgets = [
      LimitRules.saving(
        budget, over: stored.first { $0.id == budget.id }, in: environment.today.monthKey)
    ]
    return apply(PlanningChange(upsert: rows))
  }

  @discardableResult
  func delete(_ budget: Budget) -> Bool {
    var ids = PlanningRowIDs.empty
    ids.budgets = [budget.id]
    return apply(PlanningChange(delete: ids))
  }
}
