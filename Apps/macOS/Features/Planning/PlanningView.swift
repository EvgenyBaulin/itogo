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
          FreeToSpendBlock()
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

// MARK: - Free to spend

/// How much is free until a day of this month, the terms it is made of, and the daily guide
/// («свободная сумма до даты с расшифровкой и дневным ориентиром»).
private struct FreeToSpendBlock: View {
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
      let planning = snapshot.planning
      let day = chosenDay(snapshot)
      let free = planning.freeToSpend(
        until: day, reserve: planning.book.settings.reserveGoalPlan, ledger: snapshot.ledger)
      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(verbatim: environment.money.rounded(free.free))
            .font(.title2.monospacedDigit())
          if free.free.isNegative {
            Label {
              Text(verbatim: t("free.overspent"))
            } icon: {
              Image(systemName: "exclamationmark.triangle")
            }
            .font(.caption)
          } else {
            Text(
              verbatim: environment.language.format(
                "free.daily", table: "Planning", environment.money.rounded(free.dailyGuide),
                free.days)
            )
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
          }
          Spacer(minLength: 8)
          DatePicker(
            selection: Binding(
              get: { until ?? environment.calendar.startOfDay(day) },
              set: { until = $0 }),
            in: environment.calendar.startOfDay(
              snapshot.today)...environment.calendar.startOfDay(
                snapshot.today.monthKey.lastDay),
            displayedComponents: .date
          ) {
            Text(verbatim: t("free.until"))
          }
          .fixedSize()
        }
        FormulaLines(
          lines: free.lines.map { (key: $0.key, plus: $0.sign == .plus, amount: $0.amount) })
        Toggle(
          isOn: Binding(
            get: { planning.book.settings.reserveGoalPlan },
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
        if free.free.isNegative, planning.income.source != .expectations {
          // Without expected income the block knows only money already received: a salary
          // due at the end of the month is not here until it is expected.
          Text(verbatim: t("free.noExpectations"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        ForEach(free.info, id: \.key) { line in
          Text(
            verbatim: "\(t(line.key)) \(environment.money.rounded(line.amount))"
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.tertiary)
        }
      }
    }
    .refusedWriteAlert($refused, environment)
  }

  private func chosenDay(_ snapshot: DataSnapshot) -> DateOnly {
    let end = snapshot.today.monthKey.lastDay
    guard let until else { return end }
    let day = environment.calendar.day(of: until)
    return min(max(day, snapshot.today), end)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
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

// MARK: - Scheduled payments

private struct ScheduledBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Binding var sheet: PlanningSheet?

  var body: some View {
    ComputedBlock(
      title: t("scheduled.title"), state: compute.states.data,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let planning = snapshot.planning
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Text(
            verbatim: environment.language.format(
              "scheduled.totals", table: "Planning",
              environment.money.rounded(planning.subscriptionsMonthly),
              environment.money.rounded(planning.subscriptionsYearly))
          )
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
          Spacer()
          Button(t("scheduled.add")) { sheet = .payment(nil) }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        if planning.scheduled.isEmpty {
          Text(verbatim: t("scheduled.none")).foregroundStyle(.secondary)
        }
        ForEach(planning.scheduled) { status in
          ScheduledRow(status: status, prices: planning.book.prices, sheet: $sheet)
          Divider()
        }
        if !planning.funding.isEmpty {
          FundingLines(lines: planning.funding, methods: snapshot.dataset.paymentMethods)
        }
        ForEach(planning.candidates.prefix(3)) { candidate in
          HStack(spacing: 6) {
            Image(systemName: "sparkle.magnifyingglass").accessibilityHidden(true)
            Text(
              verbatim: environment.language.format(
                "scheduled.candidate", table: "Planning", candidateName(candidate, snapshot),
                environment.money.rounded(candidate.typicalAmount, currency: candidate.currency))
            )
            Spacer()
            Button(t("scheduled.candidateCreate")) {
              sheet = .subscription(from: candidate, name: candidateName(candidate, snapshot))
            }
            .buttonStyle(.link)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  /// What a candidate is called: the place it was bought at, or the description of its
  /// latest purchase as the owner typed it — never the key it was grouped by.
  private func candidateName(_ candidate: SubscriptionCandidate, _ snapshot: DataSnapshot) -> String
  {
    if let placeId = candidate.placeId,
      let place = snapshot.dataset.places.first(where: { $0.id == placeId })
    {
      return place.name
    }
    let latest = snapshot.dataset.entries
      .filter {
        !$0.transaction.isDeleted
          && SubscriptionCandidates.normalized($0.transaction.note ?? "") == candidate.key
      }
      .max { $0.transaction.occurredAt < $1.transaction.occurredAt }
    return latest?.transaction.note ?? candidate.key
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// One payment: when, what, how much, how it is paid and for whom, with «Mark as paid» and
/// «Skip»; a subscription opens to its price per month and per year, its price history, the
/// end of its trial and the link to cancel it.
private struct ScheduledRow: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let status: ScheduledStatus
  let prices: [SubscriptionPrice]
  @Binding var sheet: PlanningSheet?
  @State private var expanded = false
  @State private var confirmsDeletion = false

  var body: some View {
    let payment = status.payment
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if status.isOverdue {
          Label {
            Text(verbatim: t("planning.overdue"))
          } icon: {
            Image(systemName: "exclamationmark.circle")
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        // A due date of another year says its year: «8 мая 2027», not «8 мая».
        Text(
          verbatim: status.nextDue.year == environment.today.year
            ? environment.dates.dayAndMonth(status.nextDue)
            : environment.dates.longDay(status.nextDue)
        )
        .monospacedDigit()
        .foregroundStyle(status.isOverdue ? .primary : .secondary)
        .frame(minWidth: 52, alignment: .leading)
        Text(verbatim: payment.name).lineLimit(1)
        if payment.kind == .subscription {
          Button {
            expanded.toggle()
          } label: {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
          }
          .buttonStyle(.borderless)
          .accessibilityLabel(Text(verbatim: t("scheduled.details")))
        }
        Spacer(minLength: 8)
        Text(verbatim: environment.money.exact(status.amountNext, currency: payment.currency))
          .monospacedDigit()
        Button(t("scheduled.markAsPaid")) { sheet = .markAsPaid(status) }
          .buttonStyle(.bordered)
          .controlSize(.small)
        Button(t("scheduled.skip")) {
          if let dependencies {
            PlanningActions(dependencies).skip(payment, due: status.nextDue)
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
      subtitle
      if expanded { details }
    }
    .contentShape(Rectangle())
    .contextMenu {
      Button(environment.language("action.edit")) { sheet = .payment(payment) }
      Button(environment.language("action.delete")) { confirmsDeletion = true }
    }
    .confirmationDialog(
      environment.format("scheduled.deleteTitle", table: "Planning", payment.name),
      isPresented: $confirmsDeletion, titleVisibility: .visible
    ) {
      Button(environment.language("action.delete"), role: .destructive) {
        if let dependencies { PlanningActions(dependencies).delete(payment) }
      }
    } message: {
      Text(verbatim: t("scheduled.deleteMessage"))
    }
  }

  @ViewBuilder
  private var subtitle: some View {
    let payment = status.payment
    let dataset = compute.snapshot?.dataset
    let method = dataset?.paymentMethods.first { $0.id == payment.paymentMethodId }?.name
    let debtor = dataset?.people.first { $0.id == (payment.debtorPersonId ?? payment.forPersonId) }?
      .name
    let pieces = [
      method,
      payment.reimbursable
        ? environment.language.format(
          "scheduled.forOther", table: "Planning", debtor ?? "—",
          environment.money.rounded(status.expectedReturnRubNext ?? .zero))
        : nil,
      payment.forWhom == .me ? nil : environment.label(for: payment.forWhom),
      status.chargedDifferently ? t("scheduled.chargedDifferently") : nil,
    ].compactMap { $0 }
    if !pieces.isEmpty {
      Text(verbatim: pieces.joined(separator: " · "))
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 60)
    }
  }

  private var details: some View {
    let payment = status.payment
    let history = prices.filter { $0.paymentId == payment.id }.sorted { $0.date > $1.date }
    return VStack(alignment: .leading, spacing: 3) {
      Text(
        verbatim: environment.language.format(
          "scheduled.perMonthYear", table: "Planning",
          environment.money.rounded(status.monthly, currency: payment.currency),
          environment.money.rounded(status.yearly, currency: payment.currency))
      )
      if let trial = payment.trialEnd {
        Text(
          verbatim: environment.format(
            "scheduled.trialEnds", table: "Planning",
            environment.dates.longDay(trial)))
      }
      ForEach(history, id: \.id) { price in
        Text(
          verbatim:
            "\(environment.dates.longDay(price.date)) — \(environment.money.exact(price.amountE4, currency: payment.currency))"
        )
        .monospacedDigit()
      }
      if let link = payment.cancelLink {
        Link(t("scheduled.cancelLink"), destination: link)
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.leading, 60)
  }

  private func t(_ key: String) -> String {
    key.hasPrefix("action.")
      ? environment.language(key) : environment.language(key, table: "Planning")
  }
}

/// «Карта ··1234 — 1 348 ₽, 12 $»: what each payment method needs this month, by currency,
/// without conversion.
private struct FundingLines: View {
  @Dependency(\.environment) private var environment
  let lines: [FundingLine]
  let methods: [PaymentMethod]

  var body: some View {
    let byMethod = Dictionary(grouping: lines, by: \.paymentMethodId)
    let order = byMethod.keys.sorted { name($0) < name($1) }
    VStack(alignment: .leading, spacing: 3) {
      Text(verbatim: environment.language("funding.title", table: "Planning"))
        .font(.caption.weight(.semibold))
      ForEach(order, id: \.self) { method in
        let amounts = (byMethod[method] ?? []).sorted { $0.currency.code < $1.currency.code }
        Text(
          verbatim: "\(name(method)) — "
            + amounts.map { environment.money.rounded($0.remaining, currency: $0.currency) }
            .joined(separator: ", ")
            + " · "
            + environment.language.format(
              "funding.paid", table: "Planning",
              amounts.map { environment.money.rounded($0.paid, currency: $0.currency) }
                .joined(separator: ", "))
        )
        .monospacedDigit()
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func name(_ id: UUID?) -> String {
    guard let id, let method = methods.first(where: { $0.id == id }) else {
      return environment.language("funding.noMethod", table: "Planning")
    }
    return method.name
  }
}

extension ScheduledPayment {
  /// The page «Отменить подписку» opens, from the address as the owner typed it: «netflix.com»
  /// is how an address is usually written, and a URL without a scheme opens nothing, so it
  /// gets «https://». Only a web page or a letter is opened — a file or another app's scheme,
  /// which an imported book could carry, is not a link.
  var cancelLink: URL? {
    guard let text = cancelURL?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
    else { return nil }
    let lowered = text.lowercased()
    if lowered.hasPrefix("mailto:") { return URL(string: text) }
    if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
      return URL(string: text).flatMap { $0.host?.isEmpty == false ? $0 : nil }
    }
    if text.contains("://") { return nil }
    return URL(string: "https://" + text).flatMap { $0.host?.isEmpty == false ? $0 : nil }
  }
}
