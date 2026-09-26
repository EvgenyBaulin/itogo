import AppCore
import SwiftUI

// MARK: - Free money

/// The free sum: the money there is now on the accounts of the summary, and — in grey — what of
/// it is left once the planned payments, the debt payments, the goals and the budgets of the
/// events until a day D are taken away, with the daily guide counted from that grey line. D is
/// any day up to a year ahead, the end of the month unless the owner picks another.
///
/// Income still expected is shown and never added: money that has not come is not money
/// there is. With no count of any account there is nothing to show but «Мало данных» and the
/// way to the first count; the groups left out of the summary are shown apart with their own
/// totals, and get no free sum.
struct FreeMoneyBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @State private var until: Date?
  /// A write the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false

  var body: some View {
    ComputedBlock(
      title: t("free.title"), state: compute.states.data,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let free = snapshot.planning.freeMoney(
        until: Self.day(
          today: snapshot.today, picked: until.map { environment.calendar.day(of: $0) }),
        ledger: snapshot.ledger)
      VStack(alignment: .leading, spacing: 8) {
        ForEach(Self.parts(of: free), id: \.name) { part in
          view(of: part, free, snapshot)
        }
      }
    }
    .refusedWriteAlert($refused, environment)
  }

  // MARK: What the block shows

  /// One piece of the block, in the order the block shows them.
  enum Part: Hashable {
    /// Nothing counted yet, so there is no money to start from: «Мало данных: сделайте первую
    /// сверку», with the way to the first count.
    case firstCount
    /// The money now, with the day D beside it.
    case main(AmountE4)
    /// Currencies the main figure leaves out for want of a rate today.
    case mainWithoutRate([CurrencyCode])
    /// Balances of the summary never counted, with the way to count them.
    case unanchored([BalanceKey])
    /// The money of the goals inside the main figure, when the grey line takes it away.
    case goalSavingsInside(AmountE4)
    /// «Учитывая запланированные События и траты» and what it takes away.
    case grey(AmountE4, lines: [FreeToSpendLine])
    /// Currencies of planned amounts left out of the lines for want of a rate today.
    case planWithoutRate([CurrencyCode])
    /// «Можно тратить в день», from the grey line.
    case perDay(AmountE4, days: Int)
    /// What the expectations still wait for until D: shown, never added.
    case stillExpected(AmountE4)
    case stillExpectedWithoutRate
    /// The switch that keeps the goals' plans back.
    case reserveSwitch
    /// The groups left out of the summary, each with its own total and no free sum.
    case excluded([FreeMoney.ExcludedGroup])

    /// Which piece it is, whatever figure it holds: the identity of its view, so a new figure
    /// redraws the piece in place — the day picker beside the main figure stays as it is.
    var name: String {
      switch self {
      case .firstCount: "firstCount"
      case .main: "main"
      case .mainWithoutRate: "mainWithoutRate"
      case .unanchored: "unanchored"
      case .goalSavingsInside: "goalSavingsInside"
      case .grey: "grey"
      case .planWithoutRate: "planWithoutRate"
      case .perDay: "perDay"
      case .stillExpected: "stillExpected"
      case .stillExpectedWithoutRate: "stillExpectedWithoutRate"
      case .reserveSwitch: "reserveSwitch"
      case .excluded: "excluded"
      }
    }
  }

  /// What the block shows of `free`: with no count only the way to the first one; the groups
  /// left out of the summary apart, in either case.
  static func parts(of free: FreeMoney) -> [Part] {
    var parts: [Part] = []
    switch free.state {
    case .noReconciliation:
      parts.append(.firstCount)
    case .ready:
      parts.append(.main(free.main ?? .zero))
      if !free.mainWithoutRate.isEmpty { parts.append(.mainWithoutRate(free.mainWithoutRate)) }
      if !free.unanchored.isEmpty { parts.append(.unanchored(free.unanchored)) }
      if free.plan.subtractsGoalSavings, free.plan.goalSavings > .zero {
        parts.append(.goalSavingsInside(free.plan.goalSavings))
      }
      parts.append(.grey(free.grey ?? .zero, lines: free.lines))
      if !free.planWithoutRate.isEmpty { parts.append(.planWithoutRate(free.planWithoutRate)) }
      parts.append(.perDay(free.dailyGuide, days: free.days))
      for line in free.info where line.key == FreeMoney.Key.stillExpected {
        parts.append(.stillExpected(line.amount))
      }
      if !free.stillExpectedWithoutRate.isEmpty { parts.append(.stillExpectedWithoutRate) }
      parts.append(.reserveSwitch)
    }
    if !free.excluded.isEmpty { parts.append(.excluded(free.excluded)) }
    return parts
  }

  /// D: the day picked, kept inside [today, today + 12 months]; the end of the month when none
  /// was picked (`FreeMoney.window`).
  static func day(today: DateOnly, picked: DateOnly?) -> DateOnly {
    FreeMoney.window(today: today, until: picked).end
  }

  @ViewBuilder
  private func view(of part: Part, _ free: FreeMoney, _ snapshot: DataSnapshot) -> some View {
    switch part {
    case .firstCount:
      noReconciliation
    case .main(let main):
      mainLine(main, free, snapshot)
    case .mainWithoutRate(let currencies):
      caption(environment.format("free.mainWithoutRate", table: "Planning", codes(currencies)))
    case .unanchored(let keys):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        caption(
          environment.format("free.unanchored", table: "Planning", unanchored(keys, snapshot)))
        Spacer(minLength: 8)
        reconcileButton
      }
    case .goalSavingsInside(let saved):
      caption(
        environment.format(
          "free.goalSavingsInside", table: "Planning", environment.money.rounded(saved)))
    case .grey(let grey, let lines):
      Divider()
      greyLine(grey)
      FormulaLines(lines: lines.map { (key: $0.key, plus: $0.sign == .plus, amount: $0.amount) })
    case .planWithoutRate(let currencies):
      caption(environment.format("free.planWithoutRate", table: "Planning", codes(currencies)))
    case .perDay(let amount, let days):
      Text(
        verbatim: environment.language.format(
          "free.perDay", table: "Planning", environment.money.rounded(amount), days)
      )
      .font(.callout.monospacedDigit())
      .foregroundStyle(.secondary)
    case .stillExpected(let amount):
      caption(
        environment.format(
          "free.stillExpected", table: "Planning", dayText(free.until, snapshot),
          environment.money.rounded(amount)),
        tertiary: true)
    case .stillExpectedWithoutRate:
      caption(t("free.stillExpectedWithoutRate"), tertiary: true)
    case .reserveSwitch:
      reserveSwitch(snapshot)
    case .excluded(let groups):
      excluded(groups)
    }
  }

  // MARK: Pieces

  /// Nothing counted yet: said in words, with the way to the first count.
  private var noReconciliation: some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Label {
        Text(verbatim: t("free.noReconciliation"))
      } icon: {
        Image(systemName: "hourglass")
      }
      .foregroundStyle(.secondary)
      Spacer(minLength: 8)
      reconcileButton
    }
  }

  private func mainLine(
    _ main: AmountE4, _ free: FreeMoney, _ snapshot: DataSnapshot
  )
    -> some View
  {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: environment.money.rounded(main))
          .font(.title2.monospacedDigit())
        Text(verbatim: t("free.main"))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      DatePicker(
        selection: Binding(
          get: { until ?? environment.calendar.startOfDay(free.until) },
          set: { until = $0 }),
        in: environment.calendar.startOfDay(
          snapshot.today)...environment.calendar.startOfDay(latestDay(snapshot)),
        displayedComponents: .date
      ) {
        Text(verbatim: t("free.until"))
      }
      .fixedSize()
    }
  }

  /// «Учитывая запланированные События и траты» — in grey, as the owner asked, with a word
  /// and a symbol when it is below zero.
  private func greyLine(_ grey: AmountE4) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: t("free.grey"))
      if grey.isNegative {
        Label {
          Text(verbatim: t("free.overspent"))
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .font(.caption)
      }
      Spacer(minLength: 8)
      Text(verbatim: environment.money.rounded(grey))
        .monospacedDigit()
    }
    .foregroundStyle(.secondary)
    .accessibilityElement(children: .combine)
  }

  private func reserveSwitch(_ snapshot: DataSnapshot) -> some View {
    Toggle(
      isOn: Binding(
        get: { snapshot.planning.book.settings.reserveGoalPlan },
        set: { reserve in
          // A setting, not an action; the observation of the database recounts the block.
          if !environment.attempt(
            "settings.planning", on: environment.settings,
            { try $0.set(PlanningSettings.reserveGoalPlanKey, to: reserve ? "1" : "0") })
          {
            refused = true
          }
        })
    ) {
      Text(verbatim: environment.language("settings.planning.reserve", table: "Settings"))
    }
    .toggleStyle(.checkbox)
    .font(.caption)
  }

  /// Every group left out of the summary with its own total, and no free sum.
  @ViewBuilder
  private func excluded(_ groups: [FreeMoney.ExcludedGroup]) -> some View {
    Divider()
    Text(verbatim: t("free.excludedTitle"))
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
    ForEach(groups, id: \.group.id) { apart in
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Label {
          Text(verbatim: apart.group.name)
        } icon: {
          Image(systemName: "eye.slash")
        }
        Spacer(minLength: 8)
        Text(verbatim: apart.totalRub.map { "≈ " + environment.money.rounded($0) } ?? "—")
          .monospacedDigit()
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityElement(children: .combine)
      if !apart.withoutRate.isEmpty {
        caption(
          environment.format(
            "free.mainWithoutRate", table: "Planning", codes(apart.withoutRate)))
      }
    }
  }

  private var reconcileButton: some View {
    Button(environment.language("reconcile.open", table: "Planning")) {
      environment.showsReconciliation = true
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  private func caption(_ text: String, tertiary: Bool = false) -> some View {
    Text(verbatim: text)
      .font(.caption.monospacedDigit())
      .foregroundStyle(tertiary ? .tertiary : .secondary)
      .fixedSize(horizontal: false, vertical: true)
  }

  /// «30 сентября»; a day of another year says its year.
  private func dayText(_ day: DateOnly, _ snapshot: DataSnapshot) -> String {
    day.year == snapshot.today.year
      ? environment.dates.dayAndMonth(day) : environment.dates.longDay(day)
  }

  private func latestDay(_ snapshot: DataSnapshot) -> DateOnly {
    snapshot.today.adding(months: FreeMoney.horizonMonths)
  }

  private func codes(_ currencies: [CurrencyCode]) -> String {
    currencies.map(\.code).joined(separator: ", ")
  }

  /// «Kaspi KZT, Наличные USD»: the balances never counted, by account and currency.
  private func unanchored(_ keys: [BalanceKey], _ snapshot: DataSnapshot) -> String {
    keys.map { key in
      let name = snapshot.dataset.paymentMethods.first { $0.id == key.accountId }?.name ?? "—"
      return "\(name) \(key.currency.code)"
    }.joined(separator: ", ")
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
