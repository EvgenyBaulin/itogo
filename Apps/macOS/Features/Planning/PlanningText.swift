import AppCore
import SwiftUI

/// The words and symbols of planning, apart from the views so a test reads them in both
/// languages. The core gives keys and numbers; these give them words.
@MainActor
enum PlanningText {
  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: "Planning")
  }

  // MARK: Limits

  /// A status is never told by colour alone.
  static func statusSymbol(_ status: LimitStatus) -> String {
    switch status {
    case .ok: "checkmark.circle"
    case .warning: "exclamationmark.triangle"
    case .over: "xmark.octagon"
    }
  }

  static func statusTint(_ status: LimitStatus) -> Color {
    switch status {
    case .ok: .secondary
    case .warning: .orange
    case .over: .red
    }
  }

  static func statusWord(_ status: LimitStatus, _ environment: AppEnvironment) -> String {
    t("limit.status.\(status.rawValue)", environment)
  }

  /// What a limit is on: a category as the dictionary holds it now («Еда вне дома ›
  /// Кофейни» for a subcategory), bad spending, or a «for whom» value with its caption.
  static func limitName(
    _ budget: Budget, tree: CategoryTree, _ environment: AppEnvironment
  )
    -> String
  {
    switch budget.scope {
    case .badTotal:
      return t("limit.badTotal", environment)
    case .forWhom:
      return budget.forWhom.map { environment.label(for: $0) } ?? "—"
    case .category:
      return categoryPath(budget.categoryId, tree: tree) ?? t("limit.noCategory", environment)
    }
  }

  static func categoryPath(_ id: UUID?, tree: CategoryTree) -> String? {
    guard let id, let category = tree.category(id) else { return nil }
    if let parentId = category.parentId, let parent = tree.category(parentId) {
      return "\(parent.name) › \(category.name)"
    }
    return category.name
  }

  // MARK: Events

  /// «идёт до 18.10», «через 12 дн. · 12–18.10».
  static func eventWhen(_ plan: EventPlan, _ environment: AppEnvironment) -> String {
    let span = environment.dates.span(DayRange(plan.event.startDate, plan.event.endDate))
    if plan.isActive {
      return environment.language.format(
        "planning.eventUntil", table: "Planning", environment.dates.dayAndMonth(plan.event.endDate))
    }
    return environment.language.format(
      "planning.eventIn", table: "Planning", counts: plan.daysUntilStart) + " · " + span
  }

  // MARK: Formulas

  /// A line of a formula: «+ доход месяца 120 000 ₽».
  static func sign(_ plus: Bool) -> String { plus ? "+" : "−" }
}
