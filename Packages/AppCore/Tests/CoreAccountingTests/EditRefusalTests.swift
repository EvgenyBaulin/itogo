import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// An edit that would pull the ground from under a refund or a partial money back is refused.
@Suite("Edits a refund or a partial money back leans on")
struct EditRefusalTests {
  let categories = StartingCategories()

  /// A purchase of a jacket (600) and a scarf (400); 200 of the jacket was refunded.
  func purchase() -> TransactionEntry {
    entry(
      id(1),
      parts: [
        part(id(11), amount: money(600), category: categories.groceries),
        part(id(12), amount: money(400), category: categories.groceries),
      ])
  }

  let refunded = EditFacts(refundedByPart: [id(11): money(200)])

  func refusal(
    _ before: TransactionEntry, _ after: TransactionEntry, _ facts: EditFacts
  )
    -> LinkedEditRefusal?
  {
    OperationEditRule.refusal(editing: before, into: after, facts: facts) as? LinkedEditRefusal
  }

  @Test func aRefundedPartCannotGo() {
    var after = purchase()
    after.parts.removeFirst()
    after.parts[0].amountE4 = money(1000)
    #expect(refusal(purchase(), after, refunded) == .refundedPartRemoved)
  }

  @Test func aRefundedPartCannotBeCheaperThanItsRefunds() {
    var after = purchase()
    after.parts[0].amountE4 = money(150)
    after.parts[1].amountE4 = money(850)
    #expect(refusal(purchase(), after, refunded) == .refundedPartReduced)
    after.parts[0].amountE4 = money(200)
    after.parts[1].amountE4 = money(800)
    #expect(refusal(purchase(), after, refunded) == nil)
  }

  @Test func whatARefundWasWorkedOutFromStays() {
    var dollars = purchase()
    dollars.transaction.currency = .usd
    #expect(refusal(purchase(), dollars, refunded) == .refundedPartChanged)
    var forFriend = purchase()
    forFriend.parts[0].reimbursable = true
    forFriend.parts[0].reimbursementStatus = .expected
    #expect(refusal(purchase(), forFriend, refunded) == .refundedPartChanged)
    var onCredit = purchase()
    onCredit.transaction.creditDebtId = id(201)
    #expect(refusal(purchase(), onCredit, refunded) == .refundedPartChanged)
    // Nothing refunded: all of it may change.
    #expect(refusal(purchase(), dollars, EditFacts()) == nil)
  }

  @Test func aPartSomeMoneyCameBackForKeepsItsMoney() {
    let dinner = entry(
      id(1),
      parts: [
        part(id(11), amount: money(1000)),
        part(id(12), amount: money(1500), reimbursable: true, debtor: id(40)),
      ])
    let facts = EditFacts(linkedRubByPart: [id(12): money(700)])
    var cheaper = dinner
    cheaper.parts[1].amountE4 = money(1400)
    cheaper.parts[0].amountE4 = money(1100)
    #expect(refusal(dinner, cheaper, facts) == .partlyReturnedPartChanged)
    var mine = dinner
    mine.parts[1].reimbursable = false
    mine.parts[1].reimbursementStatus = nil
    #expect(refusal(dinner, mine, facts) == .partlyReturnedPartChanged)
    var dollars = dinner
    dollars.transaction.currency = .usd
    #expect(refusal(dinner, dollars, facts) == .partlyReturnedPartChanged)
    var renamed = dinner
    renamed.transaction.note = "dinner"
    #expect(refusal(dinner, renamed, facts) == nil)
  }

  /// A part of 50 dollars at 90 (4 500 ₽) paid for a friend, 1 800 ₽ of it back already. A new
  /// rate that leaves the part at or below what came back would leave it waiting for nothing
  /// — neither owed, nor mine, nor closed; a rate that leaves something to wait for is fine.
  @Test func aNewRateCannotLeaveAPartBelowWhatCameBack() {
    var dinner = entry(
      id(1), parts: [part(id(12), amount: money(50), reimbursable: true, debtor: id(40))])
    dinner.transaction.currency = .usd
    dinner.transaction.rate = 90
    dinner.transaction.amountRubE4 = money(4500)
    dinner.parts[0].amountRubE4 = money(4500)
    let facts = EditFacts(linkedRubByPart: [id(12): money(1800)])
    func rated(_ rate: Decimal, rubles: Int) -> TransactionEntry {
      var edited = dinner
      edited.transaction.rate = rate
      edited.transaction.amountRubE4 = money(rubles)
      edited.parts[0].amountRubE4 = money(rubles)
      return edited
    }
    #expect(refusal(dinner, rated(30, rubles: 1500), facts) == .partlyReturnedPartChanged)
    #expect(refusal(dinner, rated(36, rubles: 1800), facts) == .partlyReturnedPartChanged)
    #expect(refusal(dinner, rated(92, rubles: 4600), facts) == nil)
  }

  @Test func aRefundGoesNoFurtherThanWhatIsLeftOfItsPurchase() {
    let refund = entry(
      id(2), kind: .refund,
      parts: [
        TransactionPart(
          id: id(21), transactionId: id(2), categoryId: categories.groceries,
          amountE4: money(200), refundOfPartId: id(11))
      ])
    let facts = EditFacts(
      refundOf: [id(11): RefundableRemainder(remaining: money(400), currency: .rub)])
    var more = refund
    more.transaction.amountE4 = money(400)
    more.parts[0].amountE4 = money(400)
    #expect(refusal(refund, more, facts) == nil)
    more.transaction.amountE4 = money(401)
    more.parts[0].amountE4 = money(401)
    #expect(refusal(refund, more, facts) == .linkedRefundChanged)
    var dollars = refund
    dollars.transaction.currency = .usd
    #expect(refusal(refund, dollars, facts) == .linkedRefundChanged)
    var expense = refund
    expense.transaction.kind = .expense
    #expect(refusal(refund, expense, facts) == .linkedRefundChanged)
  }

  /// What is left of a part written off was worked out from the money that came back: its money
  /// is not edited in place, as with a surplus or a shortfall.
  @Test func aRemainderWrittenOffIsNotEditedInPlace() {
    var writeOff = entry(id(3), parts: [part(id(31), amount: money(800))])
    writeOff.transaction.externalId = MoneyBack.writeOffKey(part: id(12), operation: id(3))
    var cheaper = writeOff
    cheaper.transaction.amountE4 = money(700)
    cheaper.parts[0].amountE4 = money(700)
    #expect(
      OperationEditRule.refusal(editing: writeOff, into: cheaper, facts: EditFacts())
        as? EditRefusal == .settledReimbursement)
  }
}
