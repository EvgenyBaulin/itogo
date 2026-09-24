import CoreKit
import Foundation

/// What an operation the app wrote by itself points back at, through
/// `transactions.external_id`:
///
/// * `reimb:<reimbursement>:surplus` — the surplus of a reimbursement, an income in
///   Surcharges;
/// * `reimb:<reimbursement>:shortfall:<part>` — a shortfall, my expense;
/// * `sched:<payment>:<due date>` — «Mark as paid» of a scheduled payment for that due date;
/// * `reconcile:<reconciliation>` — the difference a reconciliation recorded, in the
///   category the app keeps for it, «Сверка».
///
/// Ids are kept as they are written (lowercased UUIDs in the app, short numbers in the
/// golden fixture), so a reimbursement is compared by text.
public enum OperationLink: Hashable, Sendable {
  case surplus(reimbursement: String)
  case shortfall(reimbursement: String, part: String)
  case scheduled(paymentId: UUID, due: DateOnly)
  case reconciliation(UUID)

  public init?(externalId: String?) {
    guard let externalId else { return nil }
    let fields = externalId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    switch fields.first {
    case "reimb" where fields.count == 3 && fields[2] == "surplus":
      self = .surplus(reimbursement: fields[1])
    case "reimb" where fields.count == 4 && fields[2] == "shortfall":
      self = .shortfall(reimbursement: fields[1], part: fields[3])
    case "sched" where fields.count == 3:
      guard let id = UUID(uuidString: fields[1]), let due = DateOnly(iso: fields[2]) else {
        return nil
      }
      self = .scheduled(paymentId: id, due: due)
    case "reconcile" where fields.count == 2:
      guard let id = UUID(uuidString: fields[1]) else { return nil }
      self = .reconciliation(id)
    default:
      return nil
    }
  }

  public var externalId: String {
    switch self {
    case .surplus(let reimbursement): "reimb:\(reimbursement):surplus"
    case .shortfall(let reimbursement, let part): "reimb:\(reimbursement):shortfall:\(part)"
    case .scheduled(let paymentId, let due): "sched:\(paymentId.uuidString.lowercased()):\(due.iso)"
    case .reconciliation(let id): "reconcile:\(id.uuidString.lowercased())"
    }
  }

  /// A record the app wrote to keep the books right, not a movement of money: the surplus is
  /// inside the money returned, the shortfall left my pocket at the purchase.
  public var isBookkeeping: Bool {
    switch self {
    // The surplus and the shortfall of a reimbursement, and the difference a reconciliation
    // records: money that moved on paper, to make the books agree with what is really there.
    // None of it is spending of the owner's, so none of it goes into the forecast, into the
    // anomalies or into the daily average.
    //
    // The difference used to be excluded by its category — it went to «Не помню», which is
    // a system one — and when it moved to «Сверка», an ordinary category, that exclusion went
    // with it. It is named here now, where it belongs.
    case .surplus, .shortfall, .reconciliation: true
    // A charge «Mark as paid» wrote is real spending; it is only counted as planned rather
    // than as variable.
    case .scheduled: false
    }
  }
}
