import AppCore
import SwiftUI

/// What to remind of when the app opens: payments due and overdue, trials ending, a new price
/// of a subscription, debt payments and a reconciliation that is due. Shown once a day, after
/// the first reminders of the day are counted. «Later» closes it until tomorrow; × on a line
/// puts that reminder off until it changes.
///
/// A line goes away once its action or × lands: acting twice on a row that stayed would pay
/// or skip the next due date (review of the app, 19.09). Paying a reminder pays its own due
/// date, never whatever the payment is due next.
struct RemindersSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  let reminders: [Reminder]
  /// Opens the section a reminder is about: Planning or Debts.
  var openSection: (MainWindow.Section) -> Void = { _ in }

  @State private var handled: Set<String> = []
  @State private var failed: [String: String] = [:]
  @State private var debtSheet: DebtSheet?
  /// The reminder whose debt sheet is open: it goes once the payment lands, and the payment
  /// is for its due.
  @State private var debtReminder: Reminder?

  private var shown: [Reminder] { reminders.filter { !handled.contains($0.id) } }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("reminders.title")).font(.headline)
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          if shown.isEmpty {
            Text(verbatim: t("reminders.allDone")).foregroundStyle(.secondary)
          }
          ForEach(shown) { reminder in
            row(reminder)
            Divider()
          }
        }
      }
      .frame(maxHeight: 360)
      HStack {
        Spacer()
        Button(t(shown.isEmpty ? "reminders.close" : "reminders.later")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 540)
    .sheet(item: $debtSheet) { sheet in
      DebtSheetView(
        sheet: sheet,
        onDone: {
          if let debtReminder { handled.insert(debtReminder.id) }
        }, payDue: debtReminder?.due
      )
      .handingOver(dependencies)
    }
  }

  @ViewBuilder
  private func row(_ reminder: Reminder) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: reminder.urgency == .overdue ? "exclamationmark.circle" : "bell")
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(verbatim: text(reminder))
        Text(verbatim: t("reminders.urgency.\(reminder.urgency)"))
          .font(.caption)
          .foregroundStyle(.secondary)
        if let reason = failed[reminder.id] {
          Text(verbatim: reason)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 8)
      actions(reminder)
      Button {
        if let dependencies, PlanningActions(dependencies).dismiss(reminder) {
          handled.insert(reminder.id)
        }
      } label: {
        Image(systemName: "xmark")
      }
      .buttonStyle(.borderless)
      .help(t("reminders.dismiss"))
      .accessibilityLabel(Text(verbatim: t("reminders.dismiss")))
    }
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder
  private func actions(_ reminder: Reminder) -> some View {
    switch reminder.kind {
    case .payment:
      // Only while the payment still waits for this very due date.
      if let status = status(reminder), let due = reminder.due, status.nextDue == due {
        Button(t("scheduled.markAsPaid")) {
          guard let dependencies else { return }
          let actions = PlanningActions(dependencies)
          if actions.markAsPaid(
            status.payment, due: due,
            amount: SubscriptionMath.price(
              of: status.payment, on: due, prices: prices), on: paidAt(due),
            paymentMethodId: status.payment.paymentMethodId, updatePrice: false)
          {
            handled.insert(reminder.id)
          } else {
            // Not in silence: the row says why (review of the app, 19.09).
            let currency = status.payment.currency
            failed[reminder.id] = environment.format(
              actions.failureKey(currency: currency, on: paidAt(due), at: .reminder),
              table: "Planning",
              currency.code)
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        Button(t("scheduled.skip")) {
          guard let dependencies else { return }
          if PlanningActions(dependencies).skip(status.payment, due: due) {
            handled.insert(reminder.id)
          }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    case .trialEnds:
      if let link = payment(reminder)?.cancelLink {
        Button(t("scheduled.cancelLink")) { openURL(link) }
          .buttonStyle(.bordered)
          .controlSize(.small)
      }
    case .priceChange:
      Button(t("reminders.open")) {
        openSection(.planning)
        dismiss()
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    case .debtPayment:
      if let debt = debt(reminder) {
        Button(environment.language("debts.pay", table: "Debts")) {
          debtReminder = reminder
          debtSheet = .pay(debt)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    case .reconciliation:
      Button(environment.language("reconcile.open", table: "Planning")) {
        dismiss()
        environment.showsReconciliation = true
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  /// The moment the payment of `due` is dated with (`PlanningActions.paidAt`).
  private func paidAt(_ due: DateOnly) -> Date {
    PlanningActions.paidAt(due: due, today: environment.today, calendar: environment.calendar)
  }

  private var prices: [SubscriptionPrice] { compute.snapshot?.dataset.planning.prices ?? [] }

  private func payment(_ reminder: Reminder) -> ScheduledPayment? {
    compute.snapshot?.dataset.planning.scheduled.first { $0.id == reminder.subjectId }
  }

  private func status(_ reminder: Reminder) -> ScheduledStatus? {
    compute.snapshot?.planning.scheduled.first { $0.id == reminder.subjectId }
  }

  private func debt(_ reminder: Reminder) -> Debt? {
    compute.snapshot?.dataset.debts.first { $0.id == reminder.subjectId }
  }

  /// «Интернет — 17.09, 900 ₽», «Пробный период «Музыки» кончается 21.09», «Цена «Облака» с
  /// 01.10 — 299 ₽ вместо 249 ₽», «Кредит — платёж 25.09, 8 500 ₽», «Сверка была 20 дней
  /// назад».
  private func text(_ reminder: Reminder) -> String {
    let day = reminder.due.map { environment.dates.dayAndMonth($0) } ?? ""
    switch reminder.kind {
    case .payment:
      guard let payment = payment(reminder) else { return "—" }
      let amount =
        reminder.due.map { SubscriptionMath.price(of: payment, on: $0, prices: prices) }
        ?? payment.amountE4
      return environment.format(
        "reminders.payment", table: "Planning", payment.name, day,
        environment.money.exact(amount, currency: payment.currency))
    case .trialEnds:
      return environment.format(
        "reminders.trialEnds", table: "Planning", payment(reminder)?.name ?? "—", day)
    case .priceChange:
      guard let payment = payment(reminder), let due = reminder.due else { return "—" }
      let new = SubscriptionMath.price(of: payment, on: due, prices: prices)
      let old = SubscriptionMath.price(of: payment, on: due.adding(days: -1), prices: prices)
      return environment.format(
        "reminders.priceChange", table: "Planning", payment.name, day,
        environment.money.exact(new, currency: payment.currency),
        environment.money.exact(old, currency: payment.currency))
    case .debtPayment:
      guard let debt = debt(reminder) else { return "—" }
      let amount =
        debt.monthlyPaymentE4.map {
          environment.money.exact($0, currency: debt.currency)
        } ?? "—"
      return environment.format("reminders.debtPayment", table: "Planning", debt.name, day, amount)
    case .reconciliation:
      guard let last = compute.snapshot?.planning.lastReconciliation,
        let today = compute.snapshot?.today
      else { return t("reminders.reconciliationFirst") }
      return environment.language.format(
        "reminders.reconciliation", table: "Planning", max(0, last.date.days(to: today)))
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
