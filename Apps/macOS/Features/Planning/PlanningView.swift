import AppCore
import SwiftUI

/// The Planning section of the main window, ⌘2: free to spend, scheduled payments and
/// subscriptions with their funding, expected income, limits, goals, events and suggestions —
/// blocks of content, without glass, over the planning snapshot the data step builds. Every
/// form hangs on the root of the section, and every action is one write and one step of ⌘Z.
struct PlanningView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @State private var sheet: PlanningSheet?

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          FreeMoneyBlock()
          ScheduledBlock(sheet: $sheet)
          grid(columns: OverviewCard.columns(forWidth: proxy.size.width - 40))
          EventsBlock()
          AdviceBlock()
        }
        .padding(20)
      }
    }
    .navigationTitle(environment.language("section.planning"))
    .sheet(item: $sheet) { sheet in
      PlanningSheetView(sheet: sheet)
        .handingOver(dependencies)
    }
  }

  /// Expected income, limits and goals side by side, like the cards of Overview.
  @ViewBuilder
  private func grid(columns: Int) -> some View {
    let blocks: [AnyView] = [
      AnyView(ExpectedIncomeBlock(sheet: $sheet)), AnyView(LimitsBlock(sheet: $sheet)),
      AnyView(GoalsBlock(sheet: $sheet)),
    ]
    Grid(alignment: .topLeading, horizontalSpacing: 16, verticalSpacing: 16) {
      ForEach(Array(stride(from: 0, to: blocks.count, by: max(1, columns))), id: \.self) { start in
        GridRow {
          ForEach(start..<min(start + max(1, columns), blocks.count), id: \.self) { index in
            blocks[index]
          }
        }
      }
    }
  }
}

/// Which form the section shows.
enum PlanningSheet: Identifiable {
  /// A payment to edit, or nil for an empty new one.
  case payment(ScheduledPayment?)
  /// A new payment the form starts filled in — from a subscription candidate. It carries an
  /// id but is not in the database: nothing is edited, no price of it has changed.
  case newPayment(ScheduledPayment)
  case markAsPaid(ScheduledStatus)
  case budget(Budget?)
  case goal(Goal?)
  case moveGoal(GoalStatus, withdraw: Bool)
  case expected(ExpectedIncome?)
  case linkIncome(ExpectedIncomeStatus)

  /// «Завести» from a subscription candidate: the form filled in with what the purchases
  /// suggest.
  static func subscription(from candidate: SubscriptionCandidate, name: String) -> PlanningSheet {
    .newPayment(
      ScheduledPayment(
        name: name, kind: .subscription, amountE4: candidate.typicalAmount,
        currency: candidate.currency, categoryId: candidate.categoryId, freq: candidate.freq))
  }

  /// The payment the form edits — saved over it, with a price edit when the amount changed —
  /// or nil when the form makes a new one.
  var editedPayment: ScheduledPayment? {
    guard case .payment(let payment) = self else { return nil }
    return payment
  }

  /// What the payment form starts with: the payment it edits, or the one a candidate
  /// suggests; nil for an empty form.
  var startingPayment: ScheduledPayment? {
    switch self {
    case .payment(let payment): payment
    case .newPayment(let payment): payment
    default: nil
    }
  }

  var id: String {
    switch self {
    case .payment(let payment): "payment-\(payment?.id.uuidString ?? "new")"
    case .newPayment(let payment): "payment-new-\(payment.id.uuidString)"
    case .markAsPaid(let status): "paid-\(status.id)"
    case .budget(let budget): "budget-\(budget?.id.uuidString ?? "new")"
    case .goal(let goal): "goal-\(goal?.id.uuidString ?? "new")"
    case .moveGoal(let status, let withdraw): "move-\(status.id)-\(withdraw)"
    case .expected(let income): "expected-\(income?.id.uuidString ?? "new")"
    case .linkIncome(let status): "link-\(status.id)"
    }
  }
}

/// «+ доход месяца 120 000 ₽ − потрачено 96 300 ₽ …»: every term of a formula on a line of
/// its own, sign first, so the formula reads fully («формула видна полностью»).
struct FormulaLines: View {
  @Dependency(\.environment) private var environment
  let lines: [(key: String, plus: Bool, amount: AmountE4)]
  var exact = false

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(verbatim: PlanningText.sign(line.plus))
            .frame(width: 10, alignment: .leading)
          Text(verbatim: environment.language(line.key, table: "Planning"))
          Spacer(minLength: 8)
          Text(
            verbatim: exact
              ? environment.money.exact(line.amount) : environment.money.rounded(line.amount)
          )
          .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }
}
