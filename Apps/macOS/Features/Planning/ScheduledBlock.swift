import AppCore
import SwiftUI

// MARK: - Scheduled payments

struct ScheduledBlock: View {
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
