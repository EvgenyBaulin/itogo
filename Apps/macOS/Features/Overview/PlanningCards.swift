import AppCore
import SwiftUI

/// The planning cards of Overview, which took the place of the line «Появится позже». They
/// read the planning snapshot the data step builds with the ledger, so a new operation moves
/// them at once, like the other cards of the data.

/// «Можно отложить в этом месяце»: the middle with its range, what is already put aside and
/// what can still be. The remainder of the month comes from the forecast step and is laid
/// over the current data, like the forecast card does.
struct CanSaveCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: t("overview.canSave"), state: state, fillsHeight: true,
      emptyReason: t("advice.reason.noIncome"), retry: { compute.retry(ComputeStep.forecast) }
    ) { canSave in
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: "≈ \(environment.money.rounded(canSave.p50 ?? .zero))")
          .font(.title2.monospacedDigit())
        if let low = canSave.low, let high = canSave.high, low != high {
          Text(
            verbatim: String(
              format: t("overview.canSaveRange"), locale: environment.language.locale,
              environment.money.rounded(low), environment.money.rounded(high))
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        }
        PlanningFigure(label: t("overview.alreadySaved"), amount: canSave.alreadySaved)
        PlanningFigure(label: t("overview.canSaveMore"), amount: canSave.canSaveMore ?? .zero)
        if canSave.lowData {
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

  private var state: BlockState<CanSave> {
    compute.states.forecast.flatMap { remainder, at in
      guard let snapshot = compute.snapshot else { return .calculating }
      let canSave = snapshot.planning.canSave(remainder: remainder)
      if case .notEnoughData = canSave.status { return .notEnoughData }
      return .ready(canSave, at: at)
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// The limits of the month: the ones over and the ones close to it first, each with its
/// symbol and word, then how many are within.
struct LimitsCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: t("overview.limits"), state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let lines = snapshot.planning.limits
      if lines.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text(verbatim: t("overview.limitsNone"))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          Button(t("overview.limitsOpen")) {
            NotificationCenter.default.post(name: .selectSection, object: 2)
          }
          .buttonStyle(.link)
        }
      } else {
        let attention = lines.filter { $0.status != .ok }
          .sorted { ($0.paceBp ?? 0) > ($1.paceBp ?? 0) }
        VStack(alignment: .leading, spacing: 6) {
          ForEach(attention.prefix(4), id: \.budget.id) { line in
            LimitStatusLine(line: line, tree: snapshot.ledger.tree)
          }
          let within = lines.count - attention.count
          if within > 0 {
            Label {
              Text(
                verbatim: environment.language.format(
                  "overview.limitsWithin", table: "Planning", within))
            } icon: {
              Image(systemName: PlanningText.statusSymbol(.ok))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// Scheduled payments and debt payments due within seven days, overdue ones first.
struct UpcomingPaymentsCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: environment.language("overview.upcoming", table: "Planning"),
      state: compute.states.data, fillsHeight: true, retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let upcoming = snapshot.planning.upcoming
      if upcoming.isEmpty {
        Text(verbatim: environment.language("overview.upcomingNone", table: "Planning"))
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 5) {
          ForEach(upcoming.prefix(5), id: \.self) { payment in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              if payment.isOverdue {
                Image(systemName: "exclamationmark.circle")
                  .accessibilityLabel(
                    Text(verbatim: environment.language("planning.overdue", table: "Planning")))
              }
              Text(verbatim: environment.dates.dayAndMonth(payment.due))
                .monospacedDigit()
                .foregroundStyle(.secondary)
              Text(verbatim: payment.name)
                .lineLimit(1)
              Spacer(minLength: 6)
              Text(verbatim: environment.money.rounded(payment.amount, currency: payment.currency))
                .monospacedDigit()
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
          }
        }
      }
    }
  }
}

/// What is still expected this month, and the nearest expectations.
struct ExpectedIncomeCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: t("overview.expected"), state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let open = snapshot.planning.expected.filter { !$0.isFulfilled }
      if open.isEmpty {
        Text(verbatim: t("overview.expectedNone")).foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 5) {
          PlanningFigure(
            label: t("overview.expectedThisMonth"),
            amount: snapshot.planning.income.expectedRemaining)
          ForEach(open.prefix(3), id: \.income.id) { status in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
              Text(verbatim: status.income.name).lineLimit(1)
              Spacer(minLength: 6)
              Text(
                verbatim: environment.money.rounded(
                  status.remaining, currency: status.income.currency)
              )
              .monospacedDigit()
            }
            .font(.callout)
          }
        }
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// The event going on — spent against its budget — or else the next one with what it cost
/// last time.
struct EventCard: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: t("overview.event"), state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let events = snapshot.planning.events
      if let plan = events.active.first ?? events.upcoming.first {
        VStack(alignment: .leading, spacing: 4) {
          Text(verbatim: plan.event.name).font(.headline).lineLimit(1)
          Text(verbatim: PlanningText.eventWhen(plan, environment))
            .font(.caption).foregroundStyle(.secondary)
          if let budget = plan.budget {
            Text(
              verbatim: String(
                format: t("planning.spentOf"), locale: environment.language.locale,
                environment.money.rounded(plan.spent), environment.money.rounded(budget))
            )
            .monospacedDigit()
          } else if plan.isActive {
            PlanningFigure(label: t("planning.spent"), amount: plan.spent)
          } else if let last = plan.lastTimeTotal {
            PlanningFigure(label: t("planning.lastTime"), amount: last)
          }
        }
      } else {
        Text(verbatim: t("overview.eventNone")).foregroundStyle(.secondary)
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

// MARK: - Pieces

/// A figure of a planning card: words on the left, whole rubles on the right.
struct PlanningFigure: View {
  @Dependency(\.environment) private var environment
  let label: String
  let amount: AmountE4

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(verbatim: label).font(.callout)
      Spacer(minLength: 8)
      Text(verbatim: environment.money.rounded(amount)).monospacedDigit()
    }
    .accessibilityElement(children: .combine)
  }
}

/// One limit: its status as a symbol and a word — never colour alone — its name and
/// «spent / available».
struct LimitStatusLine: View {
  @Dependency(\.environment) private var environment
  let line: LimitLine
  let tree: CategoryTree

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: PlanningText.statusSymbol(line.status))
        .foregroundStyle(PlanningText.statusTint(line.status))
        .accessibilityHidden(true)
      // The status in words too, never by colour and symbol alone.
      Text(
        verbatim: "\(PlanningText.statusWord(line.status, environment)): "
          + PlanningText.limitName(line.budget, tree: tree, environment)
      )
      .lineLimit(1)
      Spacer(minLength: 6)
      Text(
        verbatim:
          "\(environment.money.rounded(line.spent)) / \(environment.money.rounded(line.available))"
      )
      .monospacedDigit()
    }
    .font(.callout)
    .accessibilityElement(children: .combine)
  }
}
