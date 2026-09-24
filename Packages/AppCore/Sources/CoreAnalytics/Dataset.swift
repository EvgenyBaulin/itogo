import CoreKit
import Foundation

/// Settings the calculations read. They live in the `settings` table; the app passes them in.
public struct AnalyticsSettings: Hashable, Sendable, Codable {
  /// The key `cashbackCategoryId` is stored under in the `settings` table; its value is the
  /// id of the category as text. Part of the data, so the Windows port reads the same key.
  public static let cashbackCategoryKey = "analytics.cashbackCategoryId"

  /// The key the sensitivity of the anomaly rules is stored under. One setting for all
  /// seven rules.
  public static let anomalySensitivityKey = "analytics.anomalySensitivity"

  /// The income category whose money is cashback (`analytics.cashbackCategoryId`). Its
  /// subcategories count too.
  public var cashbackCategoryId: UUID?
  public var anomalySensitivity: AnomalySensitivity

  public init(
    cashbackCategoryId: UUID? = nil, anomalySensitivity: AnomalySensitivity = .standard
  ) {
    self.cashbackCategoryId = cashbackCategoryId
    self.anomalySensitivity = anomalySensitivity
  }
}

/// One consistent snapshot of everything the numbers are made of.
///
/// Reference books come **with** their archived rows and debts **with** the closed ones:
/// closing a loan must not drop its payments out of past months, and archiving a category
/// must not tear its subcategories off their parent. Archived values are only hidden in
/// pickers and filters; reports show them marked «(archive)».
///
/// Deleted operations may be present — the calculations skip them — so the app can lay
/// its own writes over the snapshot (`upserting`, `removing`) without a reload.
public struct Dataset: Sendable {
  public var entries: [TransactionEntry]
  public var links: [ReimbursementLink]
  public var categories: [CoreKit.Category]
  public var people: [Person]
  public var places: [Place]
  public var events: [Event]
  public var paymentMethods: [PaymentMethod]
  public var debts: [Debt]
  public var goals: [Goal]
  /// Scheduled payments, expected income, limits, reconciliations and debt journals.
  public var planning: PlanningBook
  /// «Это нормально» on an anomaly (`anomaly_dismissals`).
  public var dismissals: [AnomalyDismissal]
  /// The owner's choices of a category against what the model offered (`category_feedback`),
  /// oldest first.
  public var feedback: [CategoryFeedback]
  public var settings: AnalyticsSettings
  /// Grows with every change, so a result cached for one version is never shown for another.
  public var version: Int

  public init(
    entries: [TransactionEntry] = [],
    links: [ReimbursementLink] = [],
    categories: [CoreKit.Category] = [],
    people: [Person] = [],
    places: [Place] = [],
    events: [Event] = [],
    paymentMethods: [PaymentMethod] = [],
    debts: [Debt] = [],
    goals: [Goal] = [],
    planning: PlanningBook = .empty,
    dismissals: [AnomalyDismissal] = [],
    feedback: [CategoryFeedback] = [],
    settings: AnalyticsSettings = AnalyticsSettings(),
    version: Int = 0
  ) {
    self.entries = entries
    self.links = links
    self.categories = categories
    self.people = people
    self.places = places
    self.events = events
    self.paymentMethods = paymentMethods
    self.debts = debts
    self.goals = goals
    self.planning = planning
    self.dismissals = dismissals
    self.feedback = feedback
    self.settings = settings
    self.version = version
  }

  public static let empty = Dataset()

  /// The snapshot with these operations written over it: an operation with the same id is
  /// replaced, a new one is added. The version moves on.
  public func upserting(_ written: [TransactionEntry]) -> Dataset {
    guard !written.isEmpty else { return self }
    var copy = self
    var index: [UUID: Int] = [:]
    for (position, entry) in copy.entries.enumerated() { index[entry.id] = position }
    for entry in written {
      if let position = index[entry.id] {
        copy.entries[position] = entry
      } else {
        index[entry.id] = copy.entries.count
        copy.entries.append(entry)
      }
    }
    copy.version &+= 1
    return copy
  }

  /// The snapshot without these operations. Their reimbursement links stay: a link counts
  /// only while both of its operations are alive, so it simply stops counting.
  public func removing(_ ids: some Sequence<UUID>) -> Dataset {
    let gone = Set(ids)
    guard !gone.isEmpty else { return self }
    var copy = self
    copy.entries.removeAll { gone.contains($0.id) }
    copy.version &+= 1
    return copy
  }

  public var debtsById: [UUID: Debt] {
    Dictionary(debts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }
}
