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
