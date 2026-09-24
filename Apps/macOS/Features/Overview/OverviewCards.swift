import AppCore
import SwiftUI

/// The cards of Overview, in the order of the grid: each a block of the pipeline with
/// its own title, bound to the state of the step it comes from — the data step for the
/// month, the categories, the qualities and the reconciliation; «owed to me» for its card;
/// the forecast for the forecast. A failed step turns only its own cards into a message with
/// «Повторить»; the rest keep their numbers.
enum OverviewCard: CaseIterable, Hashable {
  case monthToDate
  case topCategories
  case qualities
  case canSave
  case forecast
  case limits
  case upcoming
  case expected
  case owed
  case event
  case reconciliation
  case anomalies

  /// Three columns from about 840 pt of list, two from about 560, one below that.
  static func columns(forWidth width: CGFloat) -> Int {
    width >= 840 ? 3 : width >= 560 ? 2 : 1
  }

  /// The cards in rows of `columns`, in order.
  static func rows(columns: Int) -> [[OverviewCard]] {
    let size = max(1, columns)
    return stride(from: 0, to: allCases.count, by: size).map {
      Array(allCases[$0..<min($0 + size, allCases.count)])
    }
  }
}

struct OverviewCardView: View {
  let card: OverviewCard
  let actions: OperationActions

  var body: some View {
    switch card {
    case .monthToDate: MonthToDateCard()
    case .topCategories: TopCategoriesCard()
    case .qualities: QualitiesCard()
    case .canSave: CanSaveCard()
    case .forecast: ForecastCard()
    case .limits: LimitsCard()
    case .upcoming: UpcomingPaymentsCard()
    case .expected: ExpectedIncomeCard()
    case .owed: OwedCard(actions: actions)
    case .event: EventCard()
    case .reconciliation: ReconciliationCard()
    case .anomalies: AnomaliesCard()
    }
  }
}

// MARK: - The cards

/// Spending, income and their difference from the 1st to today, each of the first two
/// against the same span of the previous month.
private struct MonthToDateCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: environment.language("overview.monthToDate", table: "Overview"),
      state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let summary = snapshot.summary
      VStack(alignment: .leading, spacing: 4) {
        FigureLine(
          label: environment.language("overview.expenses", table: "Overview"),
          amount: summary.expenses.current)
        ComparisonLine(change: summary.expenses, span: summary.previousSpan)
          .padding(.bottom, 4)
        FigureLine(
          label: environment.language("overview.income", table: "Overview"),
          amount: summary.income.current)
        ComparisonLine(change: summary.income, span: summary.previousSpan)
          .padding(.bottom, 4)
        FigureLine(label: environment.language("common.net"), amount: summary.net)
      }
    }
  }
}

/// Where my money went this month: the five largest top-level categories, each with its
/// share of all my spending and a thin bar as long as that share.
private struct TopCategoriesCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: environment.language("overview.topCategories", table: "Overview"),
      state: compute.states.data.flatMap { snapshot, at in
        snapshot.summary.topCategories.isEmpty ? .notEnoughData : .ready(snapshot, at: at)
      },
      fillsHeight: true,
      emptyReason: environment.language("overview.noSpendingYet", table: "Overview"),
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      VStack(alignment: .leading, spacing: 8) {
        ForEach(snapshot.summary.topCategories, id: \.key) { node in
          VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(
                verbatim: OverviewText.name(of: node.key, tree: snapshot.ledger.tree, environment)
              )
              .lineLimit(1)
              .truncationMode(.tail)
              Spacer(minLength: 8)
              Text(verbatim: environment.money.rounded(node.amount))
                .monospacedDigit()
              ShareText(basisPoints: node.share)
            }
            .font(.callout)
            ShareBar(basisPoints: node.share)
          }
          .accessibilityElement(children: .combine)
        }
      }
    }
  }
}

/// Good, neutral and bad spending this month: symbol, words, amount and share for each, a
/// bar in the fixed order good → neutral → bad, and how bad spending moved against the same
/// span of last month.
private struct QualitiesCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: environment.language("overview.qualities", table: "Overview"),
      state: compute.states.data.flatMap { snapshot, at in
        // Shares need something positive to be shares of: before the first spending of the
        // month there is nothing to split.
        snapshot.summary.qualities.allSatisfy { $0.share == nil }
          ? .notEnoughData : .ready(snapshot.summary, at: at)
      },
      fillsHeight: true,
      emptyReason: environment.language("overview.noSpendingYet", table: "Overview"),
      retry: { compute.retry(ComputeStep.data) }
    ) { summary in
      VStack(alignment: .leading, spacing: 6) {
        ForEach(summary.qualities, id: \.key) { node in
          if case .quality(let quality) = node.key {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              QualityTag(
                quality: quality, title: environment.language(Palette.qualityKey(quality)),
                font: .callout)
              Spacer(minLength: 8)
              Text(verbatim: environment.money.rounded(node.amount))
                .monospacedDigit()
              ShareText(basisPoints: node.share)
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
          }
        }
        QualityBar(nodes: summary.qualities)
          .padding(.vertical, 2)
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Image(systemName: Palette.qualitySymbol(.bad))
            .foregroundStyle(Palette.quality(.bad))
            .accessibilityHidden(true)
          Text(verbatim: environment.language("overview.badChange", table: "Overview"))
          ComparisonLine(change: summary.bad, span: summary.previousSpan)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
      }
    }
  }
}

/// Parts I paid for somebody else that have not come back. When nobody owes anything the
/// card stays and says so — the grid does not rearrange itself — and offers no button, as
/// there is nothing to close.
private struct OwedCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let actions: OperationActions

  var body: some View {
    ComputedBlock(
      title: environment.language("owed.title", table: "Entry"), state: compute.states.owed,
      fillsHeight: true, retry: { compute.retry(ComputeStep.owed) }
    ) { owed in
      if owed.count > 0 {
        VStack(alignment: .leading, spacing: 8) {
          HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: environment.money.rounded(owed.amount))
              .font(.title2.monospacedDigit())
            Text(verbatim: environment.language.format("owed.count", table: "Entry", owed.count))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          // Content, not a floating control: a plain small button, never glass.
          Button(environment.language("reimbursement.title", table: "Entry")) {
            actions.recordingReimbursement = true
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      } else {
        Text(verbatim: environment.language("overview.owedNobody", table: "Overview"))
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// The spending of the whole month as it is likely to end: the remainder of the forecast
/// step laid over what is spent and planned in the data on screen, so the known part is
/// always fresh and P10 never falls below what is already spent.
private struct ForecastCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  /// What the card shows: the forecast, and when its model was computed.
  struct Model: Sendable {
    var forecast: MonthForecast
    /// Scheduled payments (my share), expense debts and goal plans still due.
    var planned: AmountE4
    var computedAt: Date
  }

  var body: some View {
    ComputedBlock(
      title: environment.language("overview.forecast", table: "Overview"),
      state: state, fillsHeight: true, retry: { compute.retry(ComputeStep.forecast) }
    ) { model in
      let forecast = model.forecast
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: "≈ \(environment.money.rounded(forecast.p50))")
          .font(.title2.monospacedDigit())
        // With no day left the interval is a point: the figure above says it all.
        if forecast.p10 != forecast.p90 {
          Text(
            verbatim: String(
              format: environment.language("overview.forecastRange", table: "Overview"),
              locale: environment.language.locale, environment.money.rounded(forecast.p10),
              environment.money.rounded(forecast.p90))
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        if forecast.lowData {
          Label {
            Text(verbatim: environment.language("common.noData"))
          } icon: {
            Image(systemName: "hourglass")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Text(
          verbatim: environment.format(
            "overview.forecastPlannedAmount", table: "Overview",
            environment.money.rounded(model.planned))
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        Text(verbatim: OverviewText.modelComputed(model.computedAt, environment))
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }

  /// The forecast step's state, its remainder added to the current data.
  private var state: BlockState<Model> {
    compute.states.forecast.flatMap { remainder, at in
      guard let snapshot = compute.snapshot else { return .calculating }
      return .ready(
        Model(
          forecast: MonthForecast(
            spent: snapshot.summary.expenses.current, planned: snapshot.planning.planned.total,
            remainder: remainder),
          planned: snapshot.planning.planned.total,
          computedAt: at),
        at: at)
    }
  }
}

/// The last reconciliation: its day, how long ago, the difference it found, and «Сверить…»,
/// which opens the reconciliation sheet of the main window.
private struct ReconciliationCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: environment.language("overview.reconciliation", table: "Overview"),
      state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      VStack(alignment: .leading, spacing: 6) {
        if let last = snapshot.planning.lastReconciliation {
          Text(verbatim: environment.dates.longDay(last.date))
            .font(.title3)
          Text(
            verbatim: environment.language.format(
              "overview.reconciliationAgo", table: "Planning",
              max(0, last.date.days(to: snapshot.today)))
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          if let difference = last.differenceE4 {
            Text(
              verbatim: environment.format(
                "overview.reconciliationDifference", table: "Planning",
                environment.money.signedRounded(difference))
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
          }
        } else {
          Text(verbatim: environment.language("overview.reconciliationNone", table: "Overview"))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
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

// MARK: - Pieces of the cards

/// A figure of a card: its name on the left, the amount in whole rubles on the right.
private struct FigureLine: View {
  @Dependency(\.environment) private var environment
  let label: String
  let amount: AmountE4

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: label)
        .font(.callout)
      Spacer(minLength: 8)
      Text(verbatim: environment.money.rounded(amount))
        .font(.title3.monospacedDigit())
    }
    .accessibilityElement(children: .combine)
  }
}

/// «↗ +3 400 ₽ · +8,3 % к 1–18 авг.»: the arrow and the sign say which way it went, never a
/// colour. With nothing to compare with, the percent gives way to «no data last month».
struct ComparisonLine: View {
  @Dependency(\.environment) private var environment
  let change: Change
  let span: DayRange

  var body: some View {
    let text = environment.money.change(change)
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Image(systemName: Palette.changeSymbol(text.direction))
        .accessibilityHidden(true)
      Text(verbatim: OverviewText.comparison(text, span: span, environment))
    }
    .font(.caption.monospacedDigit())
    .foregroundStyle(.secondary)
  }
}

/// A share of a card line, or a dash for a bucket that has none.
private struct ShareText: View {
  @Dependency(\.environment) private var environment
  let basisPoints: Int?

  var body: some View {
    Text(verbatim: basisPoints.map { environment.money.percent(basisPoints: $0) } ?? "—")
      .monospacedDigit()
      .foregroundStyle(.secondary)
      .frame(minWidth: 56, alignment: .trailing)
  }
}

/// The thin bar under a line of the top: as long as its share of all my spending.
private struct ShareBar: View {
  let basisPoints: Int?

  var body: some View {
    let share = min(max(basisPoints ?? 0, 0), Shares.whole)
    Capsule()
      .fill(.quaternary)
      .overlay {
        ProportionalRow(weights: [share, Shares.whole - share]) {
          Capsule().fill(.tint)
          Color.clear
        }
      }
      .frame(height: 3)
      .accessibilityHidden(true)
  }
}

/// Good, neutral and bad side by side, always in that order, 2 pt apart. A segment wide
/// enough for it carries the symbol of its quality, so the bar reads without colour; a
/// bucket without a share has no width. The lines above say the same in words, so the bar
/// is hidden from VoiceOver.
private struct QualityBar: View {
  let nodes: [BreakdownNode]

  var body: some View {
    ProportionalRow(weights: nodes.map { $0.share ?? 0 }, spacing: 2) {
      ForEach(nodes, id: \.key) { node in
        if case .quality(let quality) = node.key {
          RoundedRectangle(cornerRadius: 3)
            .fill(Palette.quality(quality))
            .overlay {
              ViewThatFits(in: .horizontal) {
                Image(systemName: Palette.qualitySymbol(quality))
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.background)
                  .padding(.horizontal, 3)
                Color.clear
              }
            }
            .clipped()
        }
      }
    }
    .frame(height: 16)
    .accessibilityHidden(true)
  }
}

// MARK: - Words

/// The words of the cards, apart from the views so a test can read them in both languages.
@MainActor
enum OverviewText {
  /// «+3 400 ₽ · +8,3 % к 1–18 авг.», or «+3 400 ₽ · в прошлом месяце данных нет» when the
  /// same span of last month had nothing to compare with.
  static func comparison(
    _ text: ChangeText, span: DayRange, _ environment: AppEnvironment
  ) -> String {
    guard let percent = text.percent else {
      return environment.format("overview.comparisonNoBase", table: "Overview", text.delta)
    }
    return String(
      format: environment.language("overview.comparison", table: "Overview"),
      locale: environment.language.locale, text.delta, percent, environment.dates.span(span))
  }

  /// The name of a line of the top: a category as the dictionary holds it now, with
  /// «(архив)» when it has been archived; money without a category as «Без категории».
  static func name(
    of key: ReportKey, tree: CategoryTree, _ environment: AppEnvironment
  ) -> String {
    switch key {
    case .category(let id):
      guard let category = tree.category(id) else { return "—" }
      return category.archived
        ? environment.format("common.archivedName", category.name) : category.name
    case .uncategorized:
      return environment.language("category.uncategorized")
    default:
      return "—"
    }
  }

  /// What «Стоит посмотреть» lists, newest first: the anomalies of the last month — from the
  /// same day a month ago — as its empty line «За последний месяц ничего необычного» says,
  /// and a reimbursement still waiting, dated by the day the money was paid but a state that
  /// holds today. The rules run over the whole history; Analytics shows the rest.
  static func recentAnomalies(_ report: AnomalyReport, today: DateOnly) -> [Anomaly] {
    let start = today.adding(months: -1)
    return report.visible.filter { $0.day >= start || $0.rule == .slowReimbursement }
  }

  /// When the model of the forecast was computed: the time today, the day and time before.
  static func modelComputed(_ instant: Date, _ environment: AppEnvironment) -> String {
    if environment.calendar.day(of: instant) == environment.today {
      return environment.format(
        "overview.forecastComputedAt", table: "Overview", environment.dates.time(instant))
    }
    return environment.format(
      "overview.forecastComputedOn", table: "Overview", environment.dates.moment(instant))
  }
}

/// «Аномалии» on Overview: the few most recent things worth a second look — those of the last
/// month (`OverviewText.recentAnomalies`) — rule and day, read-only. The whole list with
/// «Это нормально» is the «Аномалии» section of the Analytics window, opened from the toolbar
/// like any other. The card says «ничего необычного» when the rules ran and found nothing in
/// the month — that is an answer, not an absence of one.
private struct AnomaliesCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  /// How many fit on a card before «и ещё N».
  private static let shown = 3

  var body: some View {
    ComputedBlock(
      title: environment.language("overview.anomalies", table: "Overview"),
      state: compute.states.anomalies, fillsHeight: true,
      retry: { compute.retry(ComputeStep.anomalies) }
    ) { report in
      let all = OverviewText.recentAnomalies(
        report, today: compute.snapshot?.today ?? environment.today)
      let recent = Array(all.prefix(Self.shown))
      VStack(alignment: .leading, spacing: 6) {
        if recent.isEmpty {
          Text(verbatim: environment.language("overview.anomaliesNone", table: "Overview"))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          ForEach(recent, id: \.id) { anomaly in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(
                verbatim: environment.language(
                  "analytics.anomaly.\(anomaly.rule.rawValue)", table: "Analytics")
              )
              .font(.callout)
              Text(verbatim: environment.dates.dayAndMonth(anomaly.day))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          if all.count > recent.count {
            Text(
              verbatim: environment.language.format(
                "overview.anomaliesMore", table: "Overview", all.count - recent.count)
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }
    }
  }
}
