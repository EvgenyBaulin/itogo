import AppCore
import Foundation
import Observation

/// The guide's memory on this Mac (`GuideProgress`, `UserDefaults` — never the database, never
/// the archive) and what it is showing now: the cards of the first launch or of «Что нового», the
/// tutorial's tasks, «Показать, куда нажимать». Nothing leaves the device; the journal gets ids
/// and counts.
@MainActor @Observable
final class GuideStore {
  static let shared = GuideStore()

  /// The key of the memory. The Debug build has a domain of its own, so its guide is its own.
  static let progressKey = "guide.progress"
  /// What the tutorial's set held when it was made: the tasks count what came after.
  static let baselineKey = "guide.tutorial.baseline"
  /// «Начать заново» asks the next launch to make the tutorial's set anew.
  static let restartKey = "guide.tutorial.restart"

  @ObservationIgnored private let defaults: UserDefaults

  private(set) var progress: GuideProgress
  /// The cards on screen: the first launch's, a version's «Что нового», or none.
  var cards: GuideScenario?
  /// «Показать, куда нажимать» is on.
  var showsWhereToClick = false
  /// The task whose place is framed on the screen.
  var framedTask: String?

  init(defaults: UserDefaults = AppEnvironment.isTestHost ? GuideStore.testDefaults : .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.progressKey),
      let stored = try? JSONDecoder().decode(GuideProgress.self, from: data)
    {
      progress = stored
      hasMemory = true
    } else {
      progress = GuideProgress()
      hasMemory = false
    }
  }

  /// The test host never reads or writes the owner's guide.
  static let testDefaults = UserDefaults(suiteName: "itogo.tests.guide") ?? .standard

  /// Whether the memory was there when the app started: without it the start decides whether
  /// this Mac is new to the app (`begin(databaseInUse:)`).
  @ObservationIgnored private var hasMemory: Bool

  /// The tutorial is on: the app runs on its set.
  var isTutorial: Bool { AppPaths.dataSet == .learn }

  private func save() {
    guard let data = try? JSONEncoder().encode(progress) else { return }
    defaults.set(data, forKey: Self.progressKey)
  }

  // MARK: Cards

  /// At the start of the main window: the first launch's cards on a new database, else a
  /// version's «Что нового» once, else nothing. Never on a set of synthetic data — their windows
  /// say «SAMPLE» and are nobody's first launch — and never in the test host.
  func begin(
    databaseInUse: Bool, version: String, dataSet: AppPaths.DataSet?,
    isTestHost: Bool = AppEnvironment.isTestHost
  ) {
    guard !isTestHost, dataSet == nil, cards == nil else { return }
    if !hasMemory {
      progress = GuideProgress.starting(onADatabaseInUse: databaseInUse)
      hasMemory = true
      save()
    }
    if progress.firstLaunchDue() {
      cards = GuideCatalog.firstLaunch
      AppLog.info("guide.firstLaunchShown", .ui, "the cards of the first launch are shown")
      return
    }
    if let due = progress.whatsNewDue(current: version, catalog: GuideCatalog.whatsNew).last {
      cards = due
      AppLog.info(
        "guide.whatsNewShown", .ui, "the cards of what is new are shown",
        [LogPair("cards", .count(due.cards.count))])
    }
  }

  /// The cards were seen through or skipped: they do not come again for this version.
  func cardsDone(version: String, skipped: Bool) {
    guard let shown = cards else { return }
    if case .firstLaunch = shown.kind {
      progress.firstLaunchWasShown(in: version)
    } else {
      progress.whatsNewSeen = version
    }
    save()
    cards = nil
    AppLog.info(
      "guide.cardsClosed", .ui, "the cards of the guide were closed",
      [LogPair("skipped", .flag(skipped))])
  }

  /// «Справка → Знакомство с Итого» and «Справка → Что нового»: the cards again, on demand.
  func show(_ scenario: GuideScenario) {
    cards = scenario
  }

  // MARK: Tips

  var tipsOff: Bool {
    get { progress.tipsOff }
    set {
      progress.tipsOff = newValue
      save()
    }
  }

  // MARK: Tutorial

  /// What the app did, while the tutorial is on: kept with the progress and checked at once.
  func report(_ event: String) {
    guard isTutorial, GuideEvent.all.contains(event), !progress.events.contains(event) else {
      return
    }
    progress.events.insert(event)
    save()
    AppLog.info(
      "guide.event", .ui, "the tutorial heard of an action", [LogPair("event", .token(event))])
  }

  /// The tasks found done by what the set now holds.
  func check(_ dataset: Dataset) {
    guard isTutorial else { return }
    let baseline = baseline(of: dataset)
    let fresh = progress.record(
      GuideFactsReader.facts(of: dataset, since: baseline), tasks: GuideCatalog.tutorial.tasks)
    guard !fresh.isEmpty else { return }
    save()
    if framedTask.map(fresh.contains) == true { framedTask = nil }
    AppLog.info(
      "guide.tasksDone", .ui, "tasks of the tutorial were found done",
      [
        LogPair("done", .count(progress.progress(of: GuideCatalog.tutorial.tasks).done)),
        LogPair("fresh", .count(fresh.count)),
      ])
  }

  /// The tasks and how many are done: «3 из 10».
  var tutorial: (tasks: [GuideTask], done: Int) {
    let tasks = GuideCatalog.tutorial.tasks
    return (tasks, progress.progress(of: tasks).done)
  }

  func isDone(_ task: GuideTask) -> Bool { progress.tasksDone.contains(task.id) }

  /// What the set held when the tutorial began: the first time the set is checked after it was
  /// made, it is what the set holds then.
  private func baseline(of dataset: Dataset) -> GuideBaseline {
    if let data = defaults.data(forKey: Self.baselineKey),
      let stored = try? JSONDecoder().decode(GuideBaseline.self, from: data)
    {
      return stored
    }
    let made = GuideBaseline(of: dataset, at: Date())
    if let data = try? JSONEncoder().encode(made) { defaults.set(data, forKey: Self.baselineKey) }
    return made
  }

  /// «Начать заново»: the tasks forgotten and the set made anew at the next launch.
  func restartTutorial() {
    progress.restartTutorial()
    save()
    defaults.removeObject(forKey: Self.baselineKey)
    defaults.set(true, forKey: Self.restartKey)
    AppLog.info("guide.tutorialRestarted", .ui, "the tutorial is begun anew")
  }

  /// Whether the launch makes the tutorial's set anew; asked once.
  func takeRestart() -> Bool {
    let asked = defaults.bool(forKey: Self.restartKey)
    defaults.removeObject(forKey: Self.restartKey)
    return asked
  }

  /// A freshly made set starts the count of the tasks again.
  func setWasMade() {
    defaults.removeObject(forKey: Self.baselineKey)
  }
}

/// What the tutorial's set held when the tutorial began.
struct GuideBaseline: Codable, Hashable {
  var startedAt: Date
  var scheduled: Int
  var counts: Int
  var transfers: Int

  init(of dataset: Dataset, at moment: Date) {
    startedAt = moment
    scheduled = dataset.planning.scheduled.count
    counts = dataset.planning.reconciliations.count
    transfers = dataset.transfers.count
  }
}

/// The facts the tasks are checked against, read from the set.
enum GuideFactsReader {
  static func facts(of dataset: Dataset, since baseline: GuideBaseline) -> GuideFacts {
    var facts = GuideFacts()
    for entry in dataset.entries
    where !entry.transaction.isDeleted && entry.transaction.externalId == nil {
      let transaction = entry.transaction
      if transaction.createdAt > baseline.startedAt {
        let words = ([transaction.note] + entry.parts.map(\.note)).compactMap { $0 }
          .joined(separator: " ")
        facts.operations.append(
          GuideOperation(
            text: words, amountE4: transaction.amountE4.raw, currency: transaction.currency,
            kind: transaction.kind,
            forSomebodyElse: entry.parts.contains { $0.reimbursable || $0.forPersonId != nil }
              || transaction.debtId != nil))
      } else if transaction.updatedAt > baseline.startedAt,
        entry.parts.contains(where: { $0.categorySource == .manual })
      {
        facts.events.insert(GuideEvent.categoryChanged)
      }
    }
    facts.scheduledPaymentsAdded = max(0, dataset.planning.scheduled.count - baseline.scheduled)
    facts.countsMade = max(0, dataset.planning.reconciliations.count - baseline.counts)
    facts.transfersAdded = max(0, dataset.transfers.count - baseline.transfers)
    return facts
  }
}
