import AppCore
import AppDatabase
import XCTest

@testable import Itogo

/// Transfers where the lists of days meet the rest of the app: the question before a deletion,
/// and the days of Overview.
@MainActor
final class TransferDeletionFlowTests: XCTestCase {
  private let sber = PaymentMethod(name: "Sber", currency: .rub, isDefault: true)
  private let kaspi = PaymentMethod(name: "Kaspi", currency: CurrencyCode("KZT"))
  private let today = DateOnly(year: 2026, month: 9, day: 18)

  private func moment(hour: Int) -> Date {
    CalendarContext.utc.startOfDay(today).addingTimeInterval(TimeInterval(hour * 3600))
  }

  private var moved: Transfer {
    Transfer(
      id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, occurredAt: moment(hour: 11),
      fromAccountId: sber.id, fromCurrency: .rub, fromAmountE4: AmountE4(whole: 1_000),
      toAccountId: kaspi.id, toCurrency: CurrencyCode("KZT"), toAmountE4: AmountE4(whole: 5_000),
      createdAt: moment(hour: 11), updatedAt: moment(hour: 11))
  }

  private func coffee() throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: moment(hour: 9), amount: AmountE4(whole: 300), note: "coffee",
      paymentMethodId: sber.id)
    draft.normalizeSinglePart()
    return try draft.materialize(now: moment(hour: 9))
  }

  func testATransferAloneIsAskedAboutAsATransfer() throws {
    let environment = AppEnvironment()
    // The choice is stored for the whole test host: it goes back to what it was.
    let before = environment.language.choice
    defer { environment.language.choice = before }
    environment.language.choice = .english
    let summary = TransferDeletion(count: 1, fees: AmountE4(whole: 15))
    let confirmation = try XCTUnwrap(
      BulkConfirmation.deletion(
        of: [], transfers: [moved.id], transferSummary: summary, debts: [:]))
    guard case .delete(let ids, _, _, _) = confirmation else {
      return XCTFail("a deletion was expected")
    }
    XCTAssertEqual(ids, [moved.id])
    XCTAssertEqual(
      BulkConfirmationText.title(confirmation, environment: environment), "Delete 1 transfer?")
    let message = BulkConfirmationText.message(confirmation, environment: environment)
    XCTAssertTrue(message.contains("15"), message)
  }

  func testOperationsAndATransferAreCountedApart() throws {
    let environment = AppEnvironment()
    // The choice is stored for the whole test host: it goes back to what it was.
    let before = environment.language.choice
    defer { environment.language.choice = before }
    environment.language.choice = .russian
    let entry = try coffee()
    let confirmation = try XCTUnwrap(
      BulkConfirmation.deletion(
        of: [entry], transfers: [moved.id], transferSummary: TransferDeletion(count: 1),
        debts: [:]))
    XCTAssertEqual(
      BulkConfirmationText.title(confirmation, environment: environment), "Удалить 1 операцию?")
    let message = BulkConfirmationText.message(confirmation, environment: environment)
    XCTAssertTrue(message.contains("И 1 перевод."), message)
  }

  func testTheDaysOfOverviewShowTransfersAndKeepThemSelectable() throws {
    let entry = try coffee()
    let snapshot = DataSnapshot.build(
      dataset: Dataset(entries: [entry], paymentMethods: [sber, kaspi], transfers: [moved]),
      calendar: .utc, today: today,
      context: SnapshotContext(rubPerUnit: [:], localeIdentifier: "en"),
      version: DataVersion(load: 1))
    XCTAssertEqual(snapshot.recentGroups.first?.transfers.map(\.id), [moved.id])
    XCTAssertTrue(snapshot.recentIds.contains(moved.id))
    XCTAssertTrue(snapshot.recentIds.contains(entry.id))
  }

  func testTheDaysOfOverviewCountARefundInItsPurchase() throws {
    var bought = TransactionDraft(
      occurredAt: moment(hour: 8), amount: AmountE4(whole: 3_000), note: "sneakers",
      paymentMethodId: sber.id)
    bought.normalizeSinglePart()
    let purchase = try bought.materialize(now: moment(hour: 8))
    let refund = try RefundRules.draft(
      refunding: purchase.parts[0], of: purchase, amount: AmountE4(whole: 1_000),
      occurredAt: moment(hour: 10), accountId: nil,
      index: RefundIndex(entries: [purchase], debts: [:]), tree: CategoryTree()
    ).materialize(now: moment(hour: 10))
    let snapshot = DataSnapshot.build(
      dataset: Dataset(entries: [purchase, refund], paymentMethods: [sber, kaspi]),
      calendar: .utc, today: today,
      context: SnapshotContext(rubPerUnit: [:], localeIdentifier: "en"),
      version: DataVersion(load: 1))
    // One day: the sneakers at 3 000 less the 1 000 that came back, the refund adding nothing.
    XCTAssertEqual(snapshot.recentGroups.first?.totals.myExpenses, AmountE4(whole: 2_000))
  }
}
