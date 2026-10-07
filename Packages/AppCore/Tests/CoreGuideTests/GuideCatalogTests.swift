import CoreKit
import Foundation
import Testing

@testable import CoreGuide

@Suite("Every scenario of the guide is complete in both languages")
struct GuideCatalogTests {
  private var allCards: [GuideCard] { GuideCatalog.scenarios.flatMap(\.cards) }
  private var allTasks: [GuideTask] { GuideCatalog.scenarios.flatMap(\.tasks) }

  @Test func everyTextHasBothLanguages() {
    for card in allCards {
      #expect(card.title.isComplete && card.body.isComplete, "\(card.id)")
    }
    for task in allTasks {
      #expect(task.title.isComplete, "\(task.id)")
      for hint in task.hints {
        #expect(hint.text.isComplete, "\(task.id)")
        #expect(hint.gesture?.isComplete ?? true, "\(task.id)")
      }
    }
  }

  @Test func everyTaskSaysWhereToPress() {
    for task in allTasks {
      #expect(!task.hints.isEmpty, "\(task.id)")
      #expect(task.hints.allSatisfy { !$0.target.isEmpty }, "\(task.id)")
    }
  }

  @Test func idsAreUnique() {
    let ids = allCards.map(\.id) + allTasks.map(\.id)
    #expect(Set(ids).count == ids.count)
    #expect(Set(GuideCatalog.scenarios.map(\.id)).count == GuideCatalog.scenarios.count)
  }

  @Test func theFirstLaunchIsFiveToSevenShortCards() {
    let cards = GuideCatalog.firstLaunch.cards
    #expect((5...7).contains(cards.count))
    #expect(cards.allSatisfy { (10...15).contains($0.seconds) && !$0.symbol.isEmpty })
  }

  /// Every version from 1.4 on has at least one card of «Что нового».
  @Test func everyVersionFromOnePointFourHasWhatsNew() {
    let versions = GuideCatalog.whatsNew.compactMap { scenario -> GuideVersion? in
      if case .whatsNew(let version) = scenario.kind { return version }
      return nil
    }
    #expect(versions.contains(GuideVersion(major: 1, minor: 4)))
    #expect(GuideCatalog.whatsNew.allSatisfy { !$0.cards.isEmpty })
  }

  @Test func theTutorialHasTheTasksOfTheRelease() {
    let ids = Set(GuideCatalog.tutorial.tasks.map(\.id))
    for id in [
      "task.coffee", "task.category", "task.search", "task.subscription", "task.count",
      "task.free", "task.transfer", "task.forSomebody", "task.spending", "task.currencyChart",
    ] {
      #expect(ids.contains(id), "\(id)")
    }
  }

  /// No task is done on empty facts — nothing was done yet.
  @Test func noTaskIsDoneOnNothing() {
    for task in allTasks {
      #expect(!task.done.isMet(by: GuideFacts()), "\(task.id)")
    }
  }

  /// Every task is found done by the facts its own action leaves.
  @Test func everyTaskIsFoundDoneByItsAction() {
    let facts = GuideFacts(
      events: GuideEvent.all,
      operations: [
        GuideOperation(text: "Кофе у дома", amountE4: 3_000_000),
        GuideOperation(text: "ужин", amountE4: 12_000_000, forSomebodyElse: true),
      ],
      scheduledPaymentsAdded: 1, countsMade: 1, transfersAdded: 1)
    for task in allTasks {
      #expect(task.done.isMet(by: facts), "\(task.id)")
    }
  }
}

@Suite("Conditions look at what happened, not at a «Done» button")
struct GuideConditionTests {
  @Test func coffeeNeedsTheWordsAndTheAmountInRubles() {
    let coffee = GuideCondition.operation(words: "кофе", amountE4: 3_000_000)
    #expect(coffee.isMet(by: GuideFacts(operations: [.init(text: "КОФЕ", amountE4: 3_000_000)])))
    #expect(!coffee.isMet(by: GuideFacts(operations: [.init(text: "кофе", amountE4: 2_500_000)])))
    #expect(!coffee.isMet(by: GuideFacts(operations: [.init(text: "чай", amountE4: 3_000_000)])))
    #expect(
      !coffee.isMet(
        by: GuideFacts(operations: [.init(text: "кофе", amountE4: 3_000_000, currency: .usd)])))
    #expect(
      !coffee.isMet(
        by: GuideFacts(operations: [.init(text: "кофе", amountE4: 3_000_000, kind: .income)])))
  }

  @Test func yoIsReadAsYe() {
    let condition = GuideCondition.operation(words: "ёлка", amountE4: nil)
    #expect(condition.isMet(by: GuideFacts(operations: [.init(text: "елка", amountE4: 1)])))
  }
}

@Suite("The guide remembers on the device, once per version")
struct GuideProgressTests {
  @Test func theFirstLaunchIsDueOnceOnAnEmptyDatabase() {
    var progress = GuideProgress.starting(onADatabaseInUse: false)
    #expect(progress.firstLaunchDue())
    progress.firstLaunchWasShown(in: "1.4.0")
    #expect(!progress.firstLaunchDue())
    #expect(progress.whatsNewDue(current: "1.4.0", catalog: GuideCatalog.whatsNew).isEmpty)
  }

  @Test func anOwnerOfOnePointThreeGetsWhatsNewOnce() {
    var progress = GuideProgress.starting(onADatabaseInUse: true)
    #expect(!progress.firstLaunchDue())
    let due = progress.whatsNewDue(current: "1.4.0", catalog: GuideCatalog.whatsNew)
    #expect(due.map(\.id) == ["whatsNew.1.4"])
    progress.whatsNewSeen = "1.4.0"
    #expect(progress.whatsNewDue(current: "1.4.0", catalog: GuideCatalog.whatsNew).isEmpty)
    #expect(progress.whatsNewDue(current: "1.4.3", catalog: GuideCatalog.whatsNew).isEmpty)
  }

  @Test func severalVersionsAreShownOldestFirst() {
    let later = GuideScenario(
      kind: .whatsNew(version: GuideVersion(major: 1, minor: 5)),
      cards: [GuideCard(id: "x", title: .init("а", "a"), body: .init("б", "b"), symbol: "star")])
    let progress = GuideProgress(firstLaunchShown: true, whatsNewSeen: "1.3.2")
    let due = progress.whatsNewDue(current: "1.5.0", catalog: [later] + GuideCatalog.whatsNew)
    #expect(due.map(\.id) == ["whatsNew.1.4", "whatsNew.1.5"])
    #expect(
      progress.whatsNewDue(current: "1.4.1", catalog: [later] + GuideCatalog.whatsNew).count == 1)
  }

  @Test func tasksStayDoneAndRestartForgetsThem() {
    var progress = GuideProgress()
    let tasks = GuideCatalog.tutorial.tasks
    progress.events.insert(GuideEvent.spendingOpened)
    let fresh = progress.record(
      GuideFacts(operations: [.init(text: "кофе", amountE4: 3_000_000)]), tasks: tasks)
    #expect(Set(fresh) == ["task.coffee", "task.spending"])
    #expect(progress.record(GuideFacts(), tasks: tasks).isEmpty, "done stays done, not twice")
    #expect(progress.progress(of: tasks) == (2, tasks.count))
    progress.restartTutorial()
    #expect(progress.progress(of: tasks).done == 0)
  }

  @Test func versionsAreRead() {
    #expect(GuideVersion("1.4.0") == GuideVersion(major: 1, minor: 4))
    #expect(GuideVersion("v1.10") == GuideVersion(major: 1, minor: 10))
    #expect(GuideVersion("1.10.0")! > GuideVersion("1.9.9")!)
    #expect(GuideVersion("1") == nil)
    #expect(GuideVersion("abc") == nil)
  }

  @Test func progressSurvivesCoding() throws {
    let progress = GuideProgress(
      firstLaunchShown: true, whatsNewSeen: "1.4.0", tasksDone: ["task.coffee"],
      events: [GuideEvent.searched], tipsOff: true)
    let data = try JSONEncoder().encode(progress)
    #expect(try JSONDecoder().decode(GuideProgress.self, from: data) == progress)
  }
}
