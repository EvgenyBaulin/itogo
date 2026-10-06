import AppCore
import SwiftUI

/// The tiles of Overview the owner may add to the twelve cards of 1.2: the forecasts of income
/// and of the balance, «Я должен», the last operation, the last count with the last operation,
/// and the free sum. Each reads what the data step and the forecast step already hold — the
/// planning snapshot, the plan of the accounts, the forecast's remainder — and counts nothing of
/// its own: a figure is the core's, only put into words.

// MARK: - Names

/// The names of the tiles, as the settings list them and the new tiles are titled, and the other
/// words of the new tiles — apart from the views, so a test reads them in both languages.
@MainActor
enum OverviewTileText {
  static let table = "Overview"

  static func nameKey(of tile: OverviewTile) -> String { "overview.tile.\(tile.rawValue)" }

  static func name(of tile: OverviewTile, _ environment: AppEnvironment) -> String {
    environment.language(nameKey(of: tile), table: table)
  }

  /// Every other key the new tiles read from the Overview catalog.
  static let keys = [
    "overview.incomeForecast.received", "overview.incomeForecast.expected",
    "overview.incomeForecast.fromExpectations", "overview.incomeForecast.fromMedian",
    "overview.incomeForecast.receivedOnly", "overview.incomeForecast.none",
    "overview.balanceForecast.none", "overview.balanceForecast.through",
    "overview.balanceForecast.notCounted", "overview.iOwe.none", "overview.iOwe.monthly",
    "overview.iOwe.next", "overview.lastRecord.none", "overview.lastCount.none",
  ]

  /// The newest operation the owner wrote — by the rule of «Последняя запись»: the latest
  /// `createdAt` of the live operations, the lines the app writes to keep the books right left
  /// out. A transfer is no operation: `nil` when the last thing written was one, or nothing was.
  static func lastOperation(in dataset: Dataset) -> TransactionEntry? {
    guard let moment = OverviewSummary.lastRecordedAt(dataset) else { return nil }
    return dataset.entries.last {
      !$0.transaction.isDeleted && $0.transaction.createdAt == moment
        && OperationLink(externalId: $0.transaction.externalId)?.isBookkeeping != true
    }
  }

  /// What the tile calls an operation: its note, else the category of its first part, else «—».
  static func title(of entry: TransactionEntry, tree: CategoryTree) -> String {
    if let note = entry.transaction.note?.trimmingCharacters(in: .whitespaces), !note.isEmpty {
      return note
    }
    return tree.category(entry.parts.first?.categoryId)?.name ?? "—"
  }

  /// The symbol of the kind of an operation, as every list shows it: never a colour alone.
  static func symbol(of kind: TransactionKind) -> String {
    switch kind {
    case .expense: "arrow.down.circle"
    case .income: "arrow.up.circle"
    case .refund: "arrow.uturn.left.circle"
    case .reimbursement: "person.crop.circle.badge.checkmark"
    }
  }
}

// MARK: - Forecast of the income

/// «Прогноз дохода до конца месяца»: what the month is expected to bring, how much of it came,
/// what the expectations still wait for, and what the estimate rests on.
struct IncomeForecastCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .incomeForecast, environment),
      state: compute.states.data.flatMap { snapshot, at in
        snapshot.planning.income.value == nil
          ? .notEnoughData : .ready(snapshot.planning.income, at: at)
      },
      fillsHeight: true, emptyReason: t("overview.incomeForecast.none"),
      retry: { compute.retry(ComputeStep.data) }
    ) { income in
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: "≈ \(environment.money.rounded(income.value ?? .zero))")
          .font(.title2.monospacedDigit())
        PlanningFigure(label: t("overview.incomeForecast.received"), amount: income.received)
        if income.expectedRemaining.raw > 0 {
          PlanningFigure(
            label: t("overview.incomeForecast.expected"), amount: income.expectedRemaining)
        }
        Text(verbatim: t(Self.sourceKey(income.source)))
          .font(.caption)
          .foregroundStyle(.secondary)
        if income.lowData {
          Label {
            Text(verbatim: environment.language("common.noData"))
          } icon: {
            Image(systemName: "hourglass")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  static func sourceKey(_ source: MonthIncomeEstimate.Source) -> String {
    switch source {
    case .expectations: "overview.incomeForecast.fromExpectations"
    case .median: "overview.incomeForecast.fromMedian"
    case .receivedOnly: "overview.incomeForecast.receivedOnly"
    }
  }

  private func t(_ key: String) -> String {
    environment.language(key, table: OverviewTileText.table)
  }
}

// MARK: - Forecast of the balance

/// What the accounts of the summary come to at the end of the month, currency by currency: the
/// middle of each counted balance's forecast (`AccountForecast`), added up within its currency —
/// never across currencies.
struct BalanceForecastModel: Hashable, Sendable {
  struct Total: Hashable, Sendable {
    var currency: CurrencyCode
    var middle: AmountE4
    var accounts: Int
  }

  /// The currencies in the order they were first met, the accounts in their order.
  var totals: [Total]
  /// Some balance of the summary was never counted or has no rate: it is not in the totals.
  var leftOut: Bool
  var lowData: Bool
  var through: DateOnly

  init(forecast: AccountForecast, accountIds: [UUID]) {
    var totals: [Total] = []
    var leftOut = false
    for id in accountIds {
      for line in forecast.lines(of: id) {
        guard line.status == .ready, let balance = line.balance else {
          if line.flows.isHeld { leftOut = true }
          continue
        }
        let currency = line.key.currency
        if let index = totals.firstIndex(where: { $0.currency == currency }) {
          totals[index].middle += balance.middle
          totals[index].accounts += 1
        } else {
          totals.append(Total(currency: currency, middle: balance.middle, accounts: 1))
        }
      }
    }
    self.totals = totals
    self.leftOut = leftOut
    self.lowData = forecast.lowData
    self.through = forecast.through
  }
}

/// «Прогноз остатка до конца месяца» of the accounts in the summary.
struct BalanceForecastCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .balanceForecast, environment),
      state: state, fillsHeight: true, emptyReason: t("overview.balanceForecast.none"),
      retry: { compute.retry(ComputeStep.forecast) }
    ) { model in
      VStack(alignment: .leading, spacing: 4) {
        ForEach(model.totals, id: \.currency) { total in
          Text(
            verbatim: "≈ \(environment.money.rounded(total.middle, currency: total.currency))"
          )
          .font(model.totals.count == 1 ? .title2.monospacedDigit() : .title3.monospacedDigit())
        }
        Text(
          verbatim: environment.format(
            "overview.balanceForecast.through", table: OverviewTileText.table,
            environment.dates.dayAndMonth(model.through))
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        if model.leftOut {
          Label {
            Text(verbatim: t("overview.balanceForecast.notCounted"))
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "exclamationmark.circle")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        if model.lowData {
          Label {
            Text(verbatim: environment.language("common.noData"))
          } icon: {
            Image(systemName: "hourglass")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  /// The forecast step's remainder laid over the plan of the current data, for the accounts of
  /// the summary. No counted balance among them: nothing to forecast from.
  private var state: BlockState<BalanceForecastModel> {
    compute.states.forecast.flatMap { remainder, at in
      guard let snapshot = compute.snapshot else { return .calculating }
      let ids = snapshot.planning.accounts.ordered(locale: environment.language.locale).sections
        .filter(\.inSummary).flatMap { $0.accounts.map(\.account.id) }
      let model = BalanceForecastModel(
        forecast: snapshot.accountPlan.forecast(remainder: remainder), accountIds: ids)
      return model.totals.isEmpty ? .notEnoughData : .ready(model, at: at)
    }
  }

  private func t(_ key: String) -> String {
    environment.language(key, table: OverviewTileText.table)
  }
}

// MARK: - I owe

/// «Я должен»: the open debts I owe — what is left of them in all, what they take a month, and
/// the nearest ones with their next payment. Chosen by the owner, never there by default: the
/// figures of the month above it do not count any debt.
struct IOweCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  /// How many debts fit on a tile.
  private static let shown = 3

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .iOwe, environment), state: compute.states.data,
      fillsHeight: true, retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let debts = snapshot.planning.debts
      if debts.iOwe.isEmpty {
        Text(verbatim: t("overview.iOwe.none")).foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 5) {
          Text(verbatim: environment.money.rounded(debts.totalIOweRub))
            .font(.title2.monospacedDigit())
          if debts.monthlyPaymentsRub.raw > 0 {
            PlanningFigure(label: t("overview.iOwe.monthly"), amount: debts.monthlyPaymentsRub)
          }
          ForEach(debts.iOwe.prefix(Self.shown)) { line in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(verbatim: line.debt.name).lineLimit(1)
              Spacer(minLength: 6)
              Text(
                verbatim: environment.money.rounded(line.balance, currency: line.debt.currency)
              )
              .monospacedDigit()
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
            if let next = line.nextPayment {
              Text(
                verbatim: environment.format(
                  "overview.iOwe.next", table: OverviewTileText.table,
                  environment.dates.dayAndMonth(next))
              )
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            }
          }
          if debts.iOwe.count > Self.shown {
            Text(
              verbatim: environment.language.format(
                "overview.anomaliesMore", table: OverviewTileText.table,
                counts: debts.iOwe.count - Self.shown)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func t(_ key: String) -> String {
    environment.language(key, table: OverviewTileText.table)
  }
}

// MARK: - The last operation and the last count

/// The newest operation the owner wrote: when, what and how much.
private struct LastOperationLines: View {
  @Dependency(\.environment) private var environment
  let snapshot: DataSnapshot

  var body: some View {
    if let moment = OverviewSummary.lastRecordedAt(snapshot.dataset) {
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: OverviewText.lastRecord(moment, environment))
          .font(.callout)
        if let entry = OverviewTileText.lastOperation(in: snapshot.dataset) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: OverviewTileText.symbol(of: entry.transaction.kind))
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            Text(verbatim: OverviewTileText.title(of: entry, tree: snapshot.ledger.tree))
              .lineLimit(1)
            Spacer(minLength: 6)
            Text(
              verbatim: environment.money.exact(
                entry.transaction.amountE4, currency: entry.transaction.currency)
            )
            .monospacedDigit()
          }
          .font(.callout)
          .accessibilityElement(children: .combine)
        }
      }
    } else {
      Text(
        verbatim: environment.language("overview.lastRecord.none", table: OverviewTileText.table)
      )
      .foregroundStyle(.secondary)
    }
  }
}

/// «Последняя операция».
struct LastRecordCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .lastRecord, environment), state: compute.states.data,
      fillsHeight: true, retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      LastOperationLines(snapshot: snapshot)
    }
  }
}

/// «Последняя сверка и операция»: the day of the last count and how long ago, the newest
/// operation under it, and «Сверить…» — the two answers to «are the figures up to date» on one
/// tile.
struct LastCountAndRecordCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .lastCountAndRecord, environment),
      state: compute.states.data, fillsHeight: true, retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      VStack(alignment: .leading, spacing: 6) {
        if let last = snapshot.planning.lastReconciliation {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "checkmark.seal")
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            Text(verbatim: environment.dates.longDay(last.date))
            Text(
              verbatim: environment.language.format(
                "overview.reconciliationAgo", table: "Planning",
                counts: max(0, last.date.days(to: snapshot.today)))
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
          .font(.callout)
          .accessibilityElement(children: .combine)
        } else {
          Text(
            verbatim: environment.language("overview.lastCount.none", table: OverviewTileText.table)
          )
          .foregroundStyle(.secondary)
        }
        Divider()
        LastOperationLines(snapshot: snapshot)
        // Content, not a floating control: a plain small button, never glass.
        Button(environment.language("reconcile.open", table: "Planning")) {
          environment.showsReconciliation = true
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
  }
}

// MARK: - The free sum

/// «Свободные средства»: what can be spent now, what is left of it once the plans until the end
/// of the month are taken away, and how much a day — the figures of the free sum of Planning,
/// for the end of the month. The day D and the switches stay in Planning.
struct FreeMoneyCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: OverviewTileText.name(of: .freeMoney, environment),
      state: compute.states.data.flatMap { snapshot, at in
        snapshot.planning.freeMoney.state == .noReconciliation
          ? .notEnoughData : .ready(snapshot.planning.freeMoney, at: at)
      },
      fillsHeight: true, emptyReason: t("free.noReconciliation"),
      retry: { compute.retry(ComputeStep.data) }
    ) { free in
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: environment.money.rounded(free.main ?? .zero))
          .font(.title2.monospacedDigit())
        Text(verbatim: t(free.goalSavings > .zero ? "free.mainSpendable" : "free.main"))
          .font(.caption)
          .foregroundStyle(.secondary)
        let grey = free.grey ?? .zero
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(verbatim: t("free.grey"))
            .fixedSize(horizontal: false, vertical: true)
          if grey.isNegative {
            Image(systemName: "exclamationmark.triangle")
              .accessibilityLabel(Text(verbatim: t("free.overspent")))
          }
          Spacer(minLength: 8)
          Text(verbatim: environment.money.rounded(grey))
            .monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        Text(
          verbatim: environment.language.format(
            "free.perDay", table: "Planning", environment.money.rounded(free.dailyGuide),
            free.days)
        )
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
