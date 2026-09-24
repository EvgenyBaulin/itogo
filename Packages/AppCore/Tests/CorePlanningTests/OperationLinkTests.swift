import CoreAccounting
import CoreKit
import Foundation
import Testing

@Suite struct OperationLinkTests {
  @Test func everyKindReadsBackWhatItWrites() throws {
    let payment = UUID()
    let reconciliation = UUID()
    let links: [OperationLink] = [
      .surplus(reimbursement: "129"), .shortfall(reimbursement: "129", part: "1151"),
      .scheduled(paymentId: payment, due: DateOnly(year: 2026, month: 9, day: 30)),
      .reconciliation(reconciliation),
    ]
    for link in links {
      #expect(OperationLink(externalId: link.externalId) == link)
    }
    #expect(
      links[2].externalId == "sched:\(payment.uuidString.lowercased()):2026-09-30")
  }

  @Test func otherIdsAreNotLinks() {
    #expect(OperationLink(externalId: nil) == nil)
    #expect(OperationLink(externalId: "import:42") == nil)
    #expect(OperationLink(externalId: "sched:not-a-uuid:2026-09-30") == nil)
  }

  /// A charge the app wrote for a scheduled payment is the owner's real spending — it is only
  /// counted elsewhere. Everything else the app writes for its own books is not spending at
  /// all: the surplus and the shortfall of a reimbursement, and the difference of a
  /// reconciliation.
  @Test func everythingTheAppWritesForItsBooksIsBookkeeping() {
    #expect(OperationLink.surplus(reimbursement: "1").isBookkeeping)
    #expect(OperationLink.shortfall(reimbursement: "1", part: "2").isBookkeeping)
    #expect(OperationLink.reconciliation(UUID()).isBookkeeping)
    #expect(
      !OperationLink.scheduled(paymentId: UUID(), due: DateOnly(year: 2026, month: 9, day: 1))
        .isBookkeeping)
  }
}
