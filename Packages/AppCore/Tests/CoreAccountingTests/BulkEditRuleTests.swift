import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Changing many operations at once")
struct BulkEditRuleTests {
  let categories = StartingCategories()

  private func plan(
    _ edit: BulkEdit, _ entries: [TransactionEntry],
    history: ManualQualityHistory = .empty
  ) -> BulkEditPlan {
    BulkEditRule.plan(edit, entries: entries, tree: categories.tree, history: history)
  }

  private func groceries(_ n: Int, amount: Int = 100) -> TransactionEntry {
    entry(
      id(n), parts: [part(id(n * 10 + 1), amount: money(amount), category: categories.groceries)])
  }

  // MARK: Category

  /// A change of the parts reaches every part of a split, and the plan counts the split so
  /// the confirmation can say so.
  @Test func aCategoryReachesEveryPartOfASplit() {
    var receipt = entry(
      id(1),
      parts: [
        part(id(11), amount: money(600), category: categories.groceries),
        part(id(12), amount: money(400), category: categories.fuel),
      ])
    receipt.transaction.importBatchId = id(90)
    receipt.transaction.externalId = "bank:1"
    let single = groceries(2)

    let result = plan(.category(categories.education), [receipt, single])

    #expect(result.changedIds == [id(1), id(2)])
    #expect(result.splitCount == 1)
    #expect(result.touchesSplit)
    #expect(result.skipped.isEmpty)
    let changed = result.changed[0]
    #expect(changed.parts.map(\.categoryId) == [categories.education, categories.education])
    #expect(changed.parts.map(\.categorySource) == [.manual, .manual])
    #expect(changed.parts.map(\.quality) == [.good, .good])
    #expect(changed.parts.map(\.qualitySource) == [.category, .category])
    // Only the change itself: when and where it came from stays.
    #expect(changed.transaction.createdAt == receipt.transaction.createdAt)
    #expect(changed.transaction.importBatchId == id(90))
    #expect(changed.transaction.externalId == "bank:1")
    #expect(changed.parts.map(\.amountE4) == receipt.parts.map(\.amountE4))
  }

  @Test func aRatingIGaveByHandSurvivesACategoryChange() {
    let rated = entry(
      id(1),
      parts: [
        part(
          id(11), amount: money(100), category: categories.groceries, quality: .bad,
          qualitySource: .manual)
      ])
    let changed = plan(.category(categories.education), [rated]).changed[0]
    #expect(changed.parts[0].quality == .bad)
    #expect(changed.parts[0].qualitySource == .manual)
  }

  /// Rule 2 before rule 3: a description I rated by hand keeps my rating in its new
  /// category; without that history the category decides.
  @Test func aRatingFromMyHistoryIsKeptAfterACategoryChange() {
    let taxi = entry(
      id(1), note: "Taxi home",
      parts: [
        part(
          id(11), amount: money(100), category: categories.groceries, quality: .bad,
          qualitySource: .history)
      ])
    let history = ManualQualityHistory(latest: ["taxi home": .bad])

    let remembered = plan(.category(categories.education), [taxi], history: history).changed[0]
    #expect(remembered.parts[0].quality == .bad)
    #expect(remembered.parts[0].qualitySource == .history)

    let forgotten = plan(.category(categories.education), [taxi]).changed[0]
    #expect(forgotten.parts[0].quality == .good)
    #expect(forgotten.parts[0].qualitySource == .category)
  }

  /// Income only takes income categories and has no quality; a refund goes back into
  /// spending categories like the expense it takes back.
  @Test func theCategoryHasToBeOfTheOperationsKind() {
    let salary = entry(
      id(1), kind: .income,
      parts: [part(id(11), amount: money(5000), category: categories.salary)])
    let refund = entry(
      id(2), kind: .refund,
      parts: [part(id(21), amount: money(50), category: categories.groceries)])
    let spending = groceries(3)

    let toBonus = plan(.category(categories.bonus), [salary, refund, spending])
    #expect(toBonus.changedIds == [id(1)])
    #expect(toBonus.changed[0].parts[0].quality == nil)
    #expect(toBonus.changed[0].parts[0].qualitySource == nil)
    #expect(Set(toBonus.skipped.map(\.transactionId)) == [id(2), id(3)])
    #expect(toBonus.skipped.allSatisfy { $0.reason == .otherKind && !$0.isPartial })

    let toFuel = plan(.category(categories.fuel), [salary, refund, spending])
    #expect(toFuel.changedIds == [id(2), id(3)])
    #expect(toFuel.skipped == [BulkSkip(transactionId: id(1), reason: .otherKind)])
  }

  @Test func whatTheCategoryChangeLeavesAloneAndWhy() {
    let moneyBack = entry(
      id(1), kind: .reimbursement, parts: [part(id(11), amount: money(300))])
    let loanPayment = entry(
      id(2), debtId: id(200),
      parts: [part(id(21), amount: money(7000), category: categories.loansCar)])
    let contribution = entry(
      id(3), parts: [part(id(31), amount: money(1000), category: categories.goalsTrip)])
    let byGoal = entry(
      id(4),
      parts: [part(id(41), amount: money(1000), category: categories.groceries, goal: id(70))]
    )
    let forgotten = entry(
      id(5), parts: [part(id(51), amount: money(80), category: categories.unknown)])

    let result = plan(
      .category(categories.fuel), [moneyBack, loanPayment, contribution, byGoal, forgotten])

    #expect(result.changed.isEmpty)
    #expect(
      result.skipped == [
        BulkSkip(transactionId: id(1), reason: .moneyReturned),
        BulkSkip(transactionId: id(2), reason: .debtPayment),
        BulkSkip(transactionId: id(3), reason: .goalContribution),
        BulkSkip(transactionId: id(4), reason: .goalContribution),
        BulkSkip(transactionId: id(5), reason: .systemCategory),
      ])
  }

  /// A split where one part is a goal contribution: the rest changes, that part stays, and
  /// the plan says the operation changed only in part.
  @Test func aGoalPartOfASplitStaysWhileTheRestChanges() {
    let mixed = entry(
      id(1),
      parts: [
        part(id(11), amount: money(600), category: categories.groceries),
        part(id(12), amount: money(400), category: categories.goalsTrip),
      ])
    let result = plan(.category(categories.fuel), [mixed])

    #expect(result.changed[0].parts.map(\.categoryId) == [categories.fuel, categories.goalsTrip])
    #expect(
      result.skipped == [BulkSkip(transactionId: id(1), reason: .goalContribution, isPartial: true)]
    )
    #expect(result.partlySkipped.count == 1)
    #expect(result.fullySkipped.isEmpty)
  }

  /// System categories are never a target: the list does not offer them, and the rule
  /// refuses them anyway.
  @Test func nothingIsMovedIntoASystemCategory() {
    let result = plan(.category(categories.loansCar), [groceries(1)])
    #expect(result.changed.isEmpty)
    #expect(result.skipped == [BulkSkip(transactionId: id(1), reason: .systemCategory)])
  }

  /// Only a live category is a target. One archived since the popover opened, one under an
  /// archived parent, or one the dictionary does not know at all is refused — with a
  /// reason of its own, not as «the other kind».
  @Test func aRetiredOrUnknownCategoryIsNeverATarget() {
    let cafe = id(130)
    let lunches = id(131)
    let tree = CategoryTree([
      CoreKit.Category(
        id: categories.groceries, kind: .expense, name: "Groceries", quality: .neutral),
      CoreKit.Category(id: cafe, kind: .expense, name: "Cafe", archived: true, quality: .neutral),
      CoreKit.Category(id: lunches, parentId: cafe, kind: .expense, name: "Lunches"),
    ])

    for target in [cafe, lunches, id(999)] {
      let result = BulkEditRule.plan(.category(target), entries: [groceries(1)], tree: tree)
      #expect(result.changed.isEmpty)
      #expect(result.skipped == [BulkSkip(transactionId: id(1), reason: .retiredCategory)])
    }
  }

  /// Re-filing — what deleting a used category does — moves only the parts filed under the
  /// categories named. The other parts of a split keep their category and its source, an
  /// operation with none of them is left alone, and a split is counted only when every part
  /// of it moved.
  @Test func aRefilingMovesOnlyThePartsInTheCategoriesNamed() {
    var receipt = entry(
      id(1),
      parts: [
        part(id(11), amount: money(300), category: categories.groceries),
        part(id(12), amount: money(700), category: categories.fuel),
      ])
    receipt.parts[1].categorySource = .model
    let whole = entry(
      id(2),
      parts: [
        part(id(21), amount: money(100), category: categories.groceries),
        part(id(22), amount: money(200), category: categories.groceries),
      ])
    let elsewhere = entry(
      id(3), parts: [part(id(31), amount: money(50), category: categories.fuel)])

    let result = plan(
      .refile(from: [categories.groceries], to: categories.education),
      [receipt, whole, elsewhere])

    #expect(result.changedIds == [id(1), id(2)])
    #expect(result.skipped.isEmpty)
    #expect(result.splitCount == 1)
    let moved = result.changed[0]
    #expect(moved.parts.map(\.categoryId) == [categories.education, categories.fuel])
    #expect(moved.parts.map(\.categorySource) == [.manual, .model])
    #expect(moved.parts[1] == receipt.parts[1])
    #expect(
      result.changed[1].parts.map(\.categoryId) == [categories.education, categories.education])
  }

  @Test func anOperationAlreadyThereIsNeitherChangedNorSkipped() {
    var there = groceries(1)
    there.parts[0].categorySource = .manual
    there.parts[0].quality = .neutral
    there.parts[0].qualitySource = .category
    let result = plan(.category(categories.groceries), [there])
    #expect(result.changed.isEmpty)
    #expect(result.skipped.isEmpty)
  }

  // MARK: Quality

  @Test func aQualityBecomesMineExceptOnGoalsIncomeAndMoneyBack() {
    let mixed = entry(
      id(1),
      parts: [
        part(id(11), amount: money(600), category: categories.groceries, quality: .neutral),
        part(id(12), amount: money(400), category: categories.goalsTrip, quality: .good),
      ])
    let salary = entry(
      id(2), kind: .income, parts: [part(id(21), amount: money(5000), category: categories.salary)])
    let moneyBack = entry(id(3), kind: .reimbursement, parts: [part(id(31), amount: money(300))])
    let refund = entry(
      id(4), kind: .refund, parts: [part(id(41), amount: money(50), category: categories.groceries)]
    )

    let result = plan(.quality(.bad), [mixed, salary, moneyBack, refund])

    #expect(result.changedIds == [id(1), id(4)])
    #expect(result.changed[0].parts.map(\.quality) == [.bad, .good])
    #expect(result.changed[0].parts.map(\.qualitySource) == [.manual, nil])
    #expect(result.changed[1].parts[0].qualitySource == .manual)
    #expect(
      result.skipped == [
        BulkSkip(transactionId: id(1), reason: .goalContribution, isPartial: true),
        BulkSkip(transactionId: id(2), reason: .noQuality),
        BulkSkip(transactionId: id(3), reason: .noQuality),
      ])
  }

  // MARK: For whom

  @Test func aGroupDropsThePersonAndAPersonTurnsMeIntoOther() {
    var withPerson = groceries(1)
    withPerson.parts[0].forWhom = .friends
    withPerson.parts[0].forPersonId = id(60)
    let mine = groceries(2)
    var partner = groceries(3)
    partner.parts[0].forWhom = .partner

    let toFamily = plan(.forWhom(.family), [withPerson, mine])
    #expect(toFamily.changed.map { $0.parts[0].forWhom } == [.family, .family])
    #expect(toFamily.changed.map { $0.parts[0].forPersonId } == [nil, nil])

    let toPerson = plan(.forPerson(id(61)), [mine, partner])
    #expect(toPerson.changed.map { $0.parts[0].forPersonId } == [id(61), id(61)])
    // «Me» cannot be somebody else; a group that was already named stays.
    #expect(toPerson.changed.map { $0.parts[0].forWhom } == [.other, .partner])
  }

  /// A part paid for somebody else already names who owes it; money given back has no
  /// «для кого» at all.
  @Test func forWhomLeavesPartsPaidForOthersAndMoneyBackAlone() {
    let dinner = entry(
      id(1),
      parts: [
        part(id(11), amount: money(200), category: categories.groceries),
        part(
          id(12), amount: money(400), category: categories.groceries, forWhom: .friends,
          reimbursable: true, debtor: id(50)),
      ])
    let theirs = entry(
      id(2),
      parts: [
        part(
          id(21), amount: money(400), category: categories.groceries, reimbursable: true,
          debtor: id(50))
      ])
    let moneyBack = entry(id(3), kind: .reimbursement, parts: [part(id(31), amount: money(300))])

    let result = plan(.forWhom(.partner), [dinner, theirs, moneyBack])

    #expect(result.changedIds == [id(1)])
    #expect(result.changed[0].parts.map(\.forWhom) == [.partner, .friends])
    #expect(
      result.skipped == [
        BulkSkip(transactionId: id(1), reason: .paidForSomebodyElse, isPartial: true),
        BulkSkip(transactionId: id(2), reason: .paidForSomebodyElse),
        BulkSkip(transactionId: id(3), reason: .moneyReturned),
      ])
    #expect(plan(.forPerson(id(61)), [moneyBack]).skipped.map(\.reason) == [.moneyReturned])
  }

  // MARK: Event, place, payment method

  @Test func anEventGoesOnEveryKindAndCanBeTakenAway() {
    let salary = entry(
      id(1), kind: .income, parts: [part(id(11), amount: money(5000), category: categories.salary)])
    let moneyBack = entry(id(2), kind: .reimbursement, parts: [part(id(21), amount: money(300))])
    let split = entry(
      id(3),
      parts: [
        part(id(31), amount: money(600), category: categories.groceries),
        part(id(32), amount: money(400), category: categories.goalsTrip),
      ])

    let result = plan(.event(id(80)), [salary, moneyBack, split])
    #expect(result.changedIds == [id(1), id(2), id(3)])
    #expect(result.changed[2].parts.map(\.eventId) == [id(80), id(80)])
    #expect(result.skipped.isEmpty)
    #expect(result.splitCount == 1)

    let cleared = plan(.event(nil), result.changed)
    #expect(cleared.changed.allSatisfy { $0.parts.allSatisfy { $0.eventId == nil } })
  }

  /// Place and payment method are fields of the operation: a split changes once, and the
  /// confirmation has no parts to warn about.
  @Test func placeAndPaymentMethodAreFieldsOfTheOperation() {
    let split = entry(
      id(1),
      parts: [
        part(id(11), amount: money(600), category: categories.groceries),
        part(id(12), amount: money(400), category: categories.fuel),
      ])
    let salary = entry(
      id(2), kind: .income, parts: [part(id(21), amount: money(5000), category: categories.salary)])

    let place = plan(.place(id(81)), [split, salary])
    #expect(place.changed.map(\.transaction.placeId) == [id(81)])
    #expect(place.splitCount == 0)
    #expect(place.skipped == [BulkSkip(transactionId: id(2), reason: .incomeHasNoPlace)])

    let card = plan(.paymentMethod(id(82)), [split, salary])
    #expect(card.changed.map(\.transaction.paymentMethodId) == [id(82), id(82)])
    #expect(card.skipped.isEmpty)
  }

  // MARK: Deleting and undoing

  @Test func aPurchaseOnCreditIsNotDeletedFromTheList() {
    let laptop = entry(
      id(1), creditDebtId: id(201),
      parts: [part(id(11), amount: money(90000), category: categories.groceries)])
    let loanPayment = entry(
      id(2), debtId: id(200),
      parts: [part(id(21), amount: money(7000), category: categories.loansCar)])
    let result = BulkEditRule.deletion(of: [laptop, loanPayment, groceries(3)])
    #expect(result.changedIds == [id(2), id(3)])
    #expect(result.skipped == [BulkSkip(transactionId: id(1), reason: .creditPurchase)])
  }

  /// A purchase a reimbursement closed a part of stays while that reimbursement is there:
  /// gone, it would leave the reimbursement closing nothing and its shortfall counted as my
  /// spending on nothing. A part still waiting, or written off, stops nothing.
  @Test func aPurchaseAReimbursementClosedAPartOfIsNotDeletedFromUnderIt() {
    func dinner(_ number: Int, _ status: ReimbursementStatus) -> TransactionEntry {
      entry(
        id(number),
        parts: [
          part(id(number * 10), amount: money(600), category: categories.groceries),
          part(
            id(number * 10 + 1), amount: money(400), category: categories.groceries,
            reimbursable: true, status: status, debtor: id(50)),
        ])
    }
    let result = BulkEditRule.deletion(
      of: [dinner(1, .returned), dinner(2, .expected), dinner(3, .writtenOff)])
    #expect(result.changedIds == [id(2), id(3)])
    #expect(result.skipped == [BulkSkip(transactionId: id(1), reason: .closedByReimbursement)])
  }

  /// Undo takes back my change, not what happened since: a part written off after the
  /// change stays written off, and a refined amount in rubles stays refined.
  @Test func revertingPutsBackOnlyWhatTheChangeTouched() {
    var before = entry(
      id(1),
      parts: [
        part(
          id(11), amount: money(600), category: categories.groceries, quality: .neutral,
          qualitySource: .category),
        part(
          id(12), amount: money(400), category: categories.fuel, reimbursable: true,
          debtor: id(50)),
      ])
    before.transaction.placeId = id(81)
    let changed = plan(.category(categories.education), [before]).changed[0]
    var now = changed
    now.parts[1].reimbursementStatus = .writtenOff
    now.parts[0].amountRubE4 = money(612)
    now.transaction.placeId = id(99)

    let reverted = BulkEditRule.revert(now, to: before)

    #expect(reverted.parts.map(\.categoryId) == [categories.groceries, categories.fuel])
    #expect(reverted.parts[0].quality == .neutral)
    #expect(reverted.parts[0].qualitySource == .category)
    #expect(reverted.parts[1].reimbursementStatus == .writtenOff)
    #expect(reverted.parts[0].amountRubE4 == money(612))
    #expect(reverted.transaction.placeId == id(81))
  }

  @Test func theReasonsAreListedOnceInAFixedOrder() {
    let skips = [
      BulkSkip(transactionId: id(1), reason: .systemCategory),
      BulkSkip(transactionId: id(2), reason: .otherKind),
      BulkSkip(transactionId: id(3), reason: .systemCategory),
    ]
    #expect(BulkEditPlan.reasons(of: skips) == [.otherKind, .systemCategory])
  }
}
