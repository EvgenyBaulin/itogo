import AppCore
import XCTest

@testable import Itogo

/// The mark a row in the list carries for its parts paid for somebody else. It follows what
/// became of the money, so a returned part no longer reads as one still waiting.
@MainActor
final class TransactionRowTests: XCTestCase {
  private func part(_ status: ReimbursementStatus?) -> TransactionPart {
    TransactionPart(
      transactionId: UUID(), amountE4: AmountE4(whole: 100), reimbursable: status != nil,
      reimbursementStatus: status)
  }

  private func status(
    _ statuses: ReimbursementStatus?..., kind: TransactionKind = .expense
  ) -> ReimbursementStatus? {
    let id = UUID()
    return TransactionListing.owedMark(
      of: TransactionEntry(
        transaction: Transaction(
          id: id, kind: kind, occurredAt: Date(), amountE4: AmountE4(whole: 100)),
        parts: statuses.map(part)))
  }

  func testAPartStillWaitingMarksTheWholeRowAsWaiting() {
    XCTAssertEqual(status(.returned, .expected), .expected)
    XCTAssertEqual(status(.writtenOff, .expected, nil), .expected)
  }

  /// Money that came back, or was given up on, is no longer waited for.
  func testAReturnedOrWrittenOffRowNoLongerSaysWaiting() {
    XCTAssertEqual(status(nil, .returned), .returned)
    XCTAssertEqual(status(.writtenOff, .returned), .returned)
    XCTAssertEqual(status(.writtenOff), .writtenOff)
  }

  func testARowWithNothingPaidForOthersHasNoMark() {
    XCTAssertNil(status(nil))
    XCTAssertNil(status())
  }

  /// Only a purchase is waited for: a friend's ticket taken back in a refund keeps the
  /// status its part was written with, and must not read «waiting».
  func testARefundOfAPartForSomebodyElseCarriesNoMark() {
    XCTAssertNil(status(.expected, kind: .refund))
    XCTAssertEqual(status(.expected, kind: .expense), .expected)
  }

  /// A row of the list of days shows the quality the table of Transactions shows: the rules'
  /// quality of each part — the category's own when the part stores none — and «several»
  /// when the parts of a split disagree. It used to show the first part's stored quality.
  func testTheListOfDaysShowsTheQualityOfEveryPartAsTheTableDoes() {
    let treats = CoreKit.Category(kind: .expense, name: "Treats", quality: .bad)
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .good)
    let splitId = UUID()
    let split = TransactionEntry(
      transaction: Transaction(
        id: splitId, kind: .expense, occurredAt: Date(), amountE4: AmountE4(whole: 300)),
      parts: [
        TransactionPart(
          transactionId: splitId, categoryId: groceries.id, quality: .good,
          qualitySource: .category, amountE4: AmountE4(whole: 200)),
        TransactionPart(
          transactionId: splitId, categoryId: treats.id, quality: .bad,
          qualitySource: .category, amountE4: AmountE4(whole: 100)),
      ])
    let unratedId = UUID()
    let unrated = TransactionEntry(
      transaction: Transaction(
        id: unratedId, kind: .expense, occurredAt: Date(), amountE4: AmountE4(whole: 100)),
      parts: [
        TransactionPart(
          transactionId: unratedId, categoryId: treats.id, amountE4: AmountE4(whole: 100))
      ])
    let ledger = Ledger(
      dataset: Dataset(entries: [split, unrated], categories: [treats, groceries]),
      calendar: .utc)

    XCTAssertEqual(TransactionListing.quality(of: split, ledger: ledger), .several)
    XCTAssertEqual(TransactionListing.quality(of: unrated, ledger: ledger), .one(.bad))
    // Before the data has come: what the parts store, compared the same way.
    XCTAssertEqual(TransactionListing.quality(of: split, ledger: nil), .several)
  }

  /// Each status has its own symbol, so the three can be told apart without colour.
  func testEveryStatusHasASymbolOfItsOwn() {
    let symbols = Set(ReimbursementStatus.allCases.map(Palette.reimbursementSymbol))
    XCTAssertEqual(symbols.count, ReimbursementStatus.allCases.count)
  }
}
