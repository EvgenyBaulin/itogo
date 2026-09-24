import AppCore
import SwiftUI

// The blocks of the Planning section below the payments. Content, never glass; states in
// words and symbols, never colour alone.

/// One-off and recurring income I expect: received of all, parts, what is left and when.
struct ExpectedIncomeBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Binding var sheet: PlanningSheet?

  var body: some View {
    ComputedBlock(
      title: t("expected.title"), state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      VStack(alignment: .leading, spacing: 8) {
        let statuses = snapshot.planning.expected
        if statuses.isEmpty {
          Text(verbatim: t("expected.none")).foregroundStyle(.secondary)
        }
        ForEach(statuses) { status in
          VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
              Text(verbatim: status.income.name).lineLimit(1)
              if status.isOverdue {
                Image(systemName: "exclamationmark.circle")
                  .accessibilityLabel(Text(verbatim: t("planning.overdue")))
              }
              Spacer(minLength: 6)
              // A regular income shows this month's term, not everything since it began.
              let term = shownTerm(status)
              Text(
                verbatim: String(
                  format: t("planning.spentOf"), locale: environment.language.locale,
                  environment.money.rounded(term.received, currency: status.currency),
                  environment.money.rounded(term.total, currency: status.currency))
              )
              .monospacedDigit()
            }
            Text(verbatim: detail(status))
              .font(.caption)
              .foregroundStyle(.secondary)
            HStack(spacing: 8) {
              Button(t("expected.link")) { sheet = .linkIncome(status) }
              Button(t("expected.edit")) { sheet = .expected(status.income) }
            }
            .buttonStyle(.link)
            .font(.caption)
          }
        }
        Button(t("expected.add")) { sheet = .expected(nil) }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
    }
  }

  /// A one-off income as a whole; a regular one by the term of this month, or its latest.
  private func shownTerm(
    _ status: ExpectedIncomeStatus
  )
    -> (received: AmountE4, total: AmountE4, remaining: AmountE4, parts: Int)
  {
    guard status.income.kind == .recurring else {
      return (
        status.received, status.received + status.remaining, status.remaining, status.partsReceived
      )
    }
    let term = Self.shownOccurrence(status.occurrences, today: environment.today)
    guard let term else { return (.zero, status.income.totalE4, status.income.totalE4, 0) }
    return (term.received, term.total, term.remaining, term.partsReceived)
  }

  /// The term of a recurring income the row stands for: the latest of this month that has
  /// come — a weekly one has later weeks still ahead — else the month's first, else the last
  /// known (third review, 19.09).
  static func shownOccurrence(
    _ occurrences: [ExpectedOccurrence], today: DateOnly
  ) -> ExpectedOccurrence? {
    let month = occurrences.filter { $0.due.monthKey == today.monthKey }
    return month.last { $0.due <= today } ?? month.first ?? occurrences.last
  }

  private func detail(_ status: ExpectedIncomeStatus) -> String {
    let term = shownTerm(status)
    let expectedParts =
      status.income.kind == .recurring ? status.income.partsExpected : status.partsExpected
    var pieces = [
      environment.language.format(
        "expected.parts", table: "Planning", term.parts, expectedParts)
    ]
    if !term.remaining.isZero {
      pieces.append(
        environment.format(
          "expected.left", table: "Planning",
          environment.money.rounded(term.remaining, currency: status.currency)))
    }
    let shownDue =
      status.income.kind == .recurring
      ? Self.shownOccurrence(status.occurrences, today: environment.today)?.due
      : status.current?.due
    if let due = shownDue ?? status.income.dueDate {
      pieces.append(environment.dates.dayAndMonth(due))
    }
    return pieces.joined(separator: " · ")
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// The limits of the month: a symbol and a word for the status, «spent / available», a thin
/// bar, the pace and the forecast; what is carried over from earlier months.
struct LimitsBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Binding var sheet: PlanningSheet?
  /// A limit asked to be deleted: the confirmation comes first.
  @State private var deleting: Budget?

  var body: some View {
    ComputedBlock(
      title: t("limits.title"), state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      VStack(alignment: .leading, spacing: 10) {
        let lines = snapshot.planning.limits
        if lines.isEmpty {
          Text(verbatim: t("limits.none")).foregroundStyle(.secondary)
        }
        ForEach(lines, id: \.budget.id) { line in
          VStack(alignment: .leading, spacing: 3) {
            LimitStatusLine(line: line, tree: snapshot.ledger.tree)
            LimitBar(line: line)
            Text(verbatim: detail(line))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .contextMenu {
            Button(environment.language("action.edit")) { sheet = .budget(line.budget) }
            Button(environment.language("action.delete")) { deleting = line.budget }
          }
        }
        Button(t("limits.add")) { sheet = .budget(nil) }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
    }
    .confirmationDialog(
      t("limits.deleteTitle"),
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible, presenting: deleting
    ) { budget in
      Button(environment.language("action.delete"), role: .destructive) {
        if let dependencies { PlanningActions(dependencies).delete(budget) }
      }
    }
  }

  private func detail(_ line: LimitLine) -> String {
    var pieces: [String] = []
    if let pace = line.paceBp {
      pieces.append(
        environment.format(
          "limits.pace", table: "Planning",
          environment.money.percent(basisPoints: pace, fractionDigits: 0)))
    }
    pieces.append(
      environment.format(
        "limits.forecast", table: "Planning", environment.money.rounded(line.forecast)))
    if !line.carry.isZero {
      pieces.append(
        environment.format(
          "limits.carry", table: "Planning", environment.money.rounded(line.carry)))
    }
    return pieces.joined(separator: " · ")
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// Spent against available: the part within the limit in the accent colour, what went over
/// it past the mark in the colour of the status — the status itself is said in words.
private struct LimitBar: View {
  let line: LimitLine

  var body: some View {
    let available = max(line.available.raw, 1)
    let within = min(max(line.spent.raw, 0), available)
    let over = max(line.spent.raw - available, 0)
    let whole = available + over
    Capsule()
      .fill(.quaternary)
      .overlay {
        ProportionalRow(weights: [
          Int(within * 1000 / whole), Int(over * 1000 / whole),
          Int((whole - within - over) * 1000 / whole),
        ]) {
          Capsule().fill(.tint)
          Capsule().fill(PlanningText.statusTint(line.status))
          Color.clear
        }
      }
      .frame(height: 4)
      .accessibilityHidden(true)
  }
}

/// Goals: progress, what is needed a month and whether it is realistic; «Contribute» and
/// «Withdraw».
struct GoalsBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Binding var sheet: PlanningSheet?

  var body: some View {
    ComputedBlock(
      title: t("goals.title"), state: compute.states.data, fillsHeight: true,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      VStack(alignment: .leading, spacing: 12) {
        let goals = snapshot.planning.goals
        if goals.isEmpty {
          Text(verbatim: t("goals.none")).foregroundStyle(.secondary)
        }
        ForEach(goals) { status in
          VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
              Text(verbatim: status.goal.name).lineLimit(1)
              Spacer(minLength: 6)
              Text(
                verbatim: environment.money.percent(
                  basisPoints: status.progressBp, fractionDigits: 0)
              )
              .monospacedDigit()
              .foregroundStyle(.secondary)
            }
            Capsule()
              .fill(.quaternary)
              .overlay {
                ProportionalRow(
                  weights: [
                    min(status.progressBp, Shares.whole),
                    Shares.whole - min(status.progressBp, Shares.whole),
                  ]
                ) {
                  Capsule().fill(.tint)
                  Color.clear
                }
              }
              .frame(height: 4)
              .accessibilityHidden(true)
            Text(
              verbatim: String(
                format: t("planning.spentOf"), locale: environment.language.locale,
                environment.money.rounded(status.saved),
                environment.money.rounded(status.goal.targetE4))
            )
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Text(verbatim: realism(status))
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
              Button(t("goals.contribute")) { sheet = .moveGoal(status, withdraw: false) }
                .buttonStyle(.bordered)
              Button(t("goals.withdraw")) { sheet = .moveGoal(status, withdraw: true) }
                .buttonStyle(.bordered)
                .disabled(status.saved.raw <= 0)
            }
            .controlSize(.small)
          }
          .contextMenu {
            Button(environment.language("action.edit")) { sheet = .goal(status.goal) }
            Button(t("goals.archive")) {
              if let dependencies { PlanningActions(dependencies).archive(status.goal) }
            }
          }
        }
        Button(t("goals.add")) { sheet = .goal(nil) }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
    }
  }

  /// «Нужно 18 300 ₽ в месяц · успеваете по плану», «при плане — к марту 2027».
  private func realism(_ status: GoalStatus) -> String {
    var pieces: [String] = []
    if let needed = status.neededMonthly {
      pieces.append(
        environment.format("goals.needed", table: "Planning", environment.money.rounded(needed)))
    }
    pieces.append(t("goals.realism.\(status.realism.rawValue)"))
    if status.realism == .behindPlan || status.realism == .noDate,
      let month = status.projectedCompletion
    {
      pieces.append(
        environment.format(
          "goals.projected", table: "Planning", environment.dates.monthTitle(month)))
    }
    return pieces.joined(separator: " · ")
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// Events with budgets: spent, left, by category; the upcoming ones with what they cost
/// last time and how much to put aside a month.
struct EventsBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    ComputedBlock(
      title: t("events.title"), state: compute.states.data,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let events = snapshot.planning.events
      let shown = unique(events.active + events.withBudget + events.upcoming)
      VStack(alignment: .leading, spacing: 10) {
        if shown.isEmpty {
          Text(verbatim: t("events.none")).foregroundStyle(.secondary)
        }
        ForEach(shown, id: \.event.id) { plan in
          VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
              Text(verbatim: plan.event.name)
              Text(verbatim: PlanningText.eventWhen(plan, environment))
                .font(.caption).foregroundStyle(.secondary)
              Spacer(minLength: 6)
              if let budget = plan.budget {
                Text(
                  verbatim: String(
                    format: t("planning.spentOf"), locale: environment.language.locale,
                    environment.money.rounded(plan.spent), environment.money.rounded(budget))
                )
                .monospacedDigit()
              }
            }
            if plan.overBudget || plan.pacing {
              Label {
                Text(verbatim: t(plan.overBudget ? "events.over" : "events.pacing"))
              } icon: {
                Image(systemName: "exclamationmark.triangle")
              }
              .font(.caption)
            }
            if !plan.byCategory.isEmpty {
              Text(
                verbatim: plan.byCategory.prefix(4).map {
                  "\(PlanningText.categoryPath($0.categoryId, tree: snapshot.ledger.tree) ?? "—") \(environment.money.rounded($0.amount))"
                }.joined(separator: " · ")
              )
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            }
            if !plan.isActive, let last = plan.lastTimeTotal {
              Text(
                verbatim: environment.format(
                  "events.lastTime", table: "Planning", environment.money.rounded(last))
                  + (plan.monthlySaving.map {
                    " · "
                      + environment.format(
                        "events.monthly", table: "Planning", environment.money.rounded($0))
                  } ?? "")
              )
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }

  private func unique(_ plans: [EventPlan]) -> [EventPlan] {
    var seen: Set<UUID> = []
    return plans.filter { seen.insert($0.event.id).inserted }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// Suggestions built by rules on my data, each with its formula and numbers, «Мало данных»
/// where there is too little, and the permanent line that this is not financial advice.
struct AdviceBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      // In every state of the block, even while it counts or failed («постоянная
      // пометка»).
      Label {
        Text(verbatim: t(AdviceBook.disclaimerKey))
      } icon: {
        Image(systemName: "info.circle")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      ComputedBlock(
        title: t("advice.title"), state: compute.states.advice,
        retry: { compute.retry(ComputeStep.advice) }
      ) { report in
        VStack(alignment: .leading, spacing: 12) {
          ForEach(report.items) { advice in
            AdviceRow(advice: advice)
          }
        }
      }
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

private struct AdviceRow: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  let advice: Advice

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(verbatim: AdviceText.title(advice, environment, tree: compute.snapshot?.ledger.tree))
        .font(.callout.weight(.medium))
      switch advice.status {
      case .ready:
        if let result = advice.result {
          Text(verbatim: AdviceText.line(result, environment, tree: compute.snapshot?.ledger.tree))
            .font(.callout.monospacedDigit())
        }
        ForEach(Array(advice.terms.enumerated()), id: \.offset) { _, term in
          Text(verbatim: AdviceText.line(term, environment, tree: compute.snapshot?.ledger.tree))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        ForEach(Array(advice.notes.enumerated()), id: \.offset) { _, note in
          Text(verbatim: AdviceText.line(note, environment, tree: compute.snapshot?.ledger.tree))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      case .notEnoughData(let reason):
        Label {
          Text(
            verbatim: environment.language("common.noData") + " — "
              + environment.language(reason, table: "Planning"))
        } icon: {
          Image(systemName: "hourglass")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
    .accessibilityElement(children: .combine)
  }
}
