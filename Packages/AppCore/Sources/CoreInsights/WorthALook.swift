import CoreAccounting
import CoreKit
import CorePlanning
import Foundation

/// An account in the archive that still holds money — the archive of 1.1 took accounts with
/// money, 1.2 no longer does —, with what it holds per currency.
public struct ArchivedMoneyHolder: Hashable, Sendable {
  public var account: PaymentMethod
  public var leftovers: [ArchivedLeftover]

  public init(account: PaymentMethod, leftovers: [ArchivedLeftover]) {
    self.account = account
    self.leftovers = leftovers
  }
}

/// A line of «Стоит посмотреть».
public enum WorthALookLine: Hashable, Sendable, Identifiable {
  /// «Потратили деньги цели?»: what the goals hold and the money of the summary.
  case goalsExceed(goals: AmountE4, money: AmountE4)
  /// «На «Наличные» в архиве 1,000 ₽ — перевести на другой счёт?»
  case archivedMoney(ArchivedMoneyHolder)
  case anomaly(Anomaly)
  /// «и ещё N».
  case more(Int)
  /// «За последний месяц ничего необычного».
  case nothingUnusual

  public var id: String {
    switch self {
    case .goalsExceed: "goalsExceed"
    case .archivedMoney(let line): "archivedMoney:\(line.account.id)"
    case .anomaly(let anomaly): "anomaly:\(anomaly.id)"
    case .more: "more"
    case .nothingUnusual: "nothingUnusual"
    }
  }
}

/// What the tile «Стоит посмотреть» lists, and the rule of it — the card and the breakdown of
/// the card read it, so they cannot tell two stories.
public enum WorthALook {
  /// The anomalies of the last month — from the same day a month ago — as the empty line «За
  /// последний месяц ничего необычного» says, newest first as the report has them, and a
  /// reimbursement still waiting, dated by the day the money was paid but a state that holds
  /// today. The rules run over the whole history; Analytics shows the rest.
  public static func recent(_ report: AnomalyReport, today: DateOnly) -> [Anomaly] {
    let start = today.adding(months: -1)
    return report.visible.filter { $0.day >= start || $0.rule == .slowReimbursement }
  }

  /// Every account in the archive whose balance is not zero in some currency it was counted in
  /// (`ArchivedMoney.balancesToMove`), in the order of the accounts. A currency never counted
  /// has no balance to move.
  public static func archivedMoney(
    accounts: [PaymentMethod], balances: AccountBalances
  ) -> [ArchivedMoneyHolder] {
    accounts.filter(\.archived).compactMap { account in
      let leftovers = ArchivedMoney.balancesToMove(of: account, balances: balances).leftovers
      return leftovers.isEmpty ? nil : ArchivedMoneyHolder(account: account, leftovers: leftovers)
    }
  }

  /// The lines, in order. First the goals holding more than the money on the accounts of the
  /// summary — goal money was spent without «Забрать» —, then each account in the archive that
  /// still holds money (`archived`), then at most `shown` anomalies of the last month (`recent`)
  /// and «и ещё N» for the rest. «Ничего необычного» only when there is none of them: with such
  /// a line on the card, there is something worth a look.
  public static func lines(
    _ report: AnomalyReport, today: DateOnly, free: FreeMoney?, shown: Int,
    archived: [ArchivedMoneyHolder] = []
  ) -> [WorthALookLine] {
    let all = recent(report, today: today)
    var lines: [WorthALookLine] = []
    if let free, free.goalsExceedMoney {
      lines.append(.goalsExceed(goals: free.goalSavings, money: free.moneyNow ?? .zero))
    }
    lines += archived.map { .archivedMoney($0) }
    lines += all.prefix(shown).map { .anomaly($0) }
    if all.count > shown { lines.append(.more(all.count - shown)) }
    return lines.isEmpty ? [.nothingUnusual] : lines
  }
}
