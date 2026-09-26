import AppCore
import SwiftUI

// The blocks of the Planning section below the payments. Content, never glass; states in
// words and symbols, never colour alone.

/// Events with budgets: spent, left, by category; the upcoming ones with what they cost
/// last time and how much to put aside a month. «+ Событие» and «Изменить» set an event and
/// its budget right here — the free sum keeps back what is left of it — each one step of ⌘Z.
struct EventsBlock: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @State private var form: EventFormItem?

  var body: some View {
    ComputedBlock(
      title: t("events.title"), state: compute.states.data,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let shown = Self.shown(
        snapshot.planning.events, budgeted: snapshot.planning.budgetedEvents)
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          if shown.isEmpty {
            Text(verbatim: t("events.none")).foregroundStyle(.secondary)
          }
          Spacer()
          Button(t("events.add")) { form = EventFormItem(event: nil) }
            .buttonStyle(.bordered)
            .controlSize(.small)
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
              Button(t("events.edit")) { form = EventFormItem(event: plan.event) }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityLabel(Text(verbatim: "\(t("events.edit")): \(plan.event.name)"))
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
    .sheet(item: $form) { item in
      EventForm(original: item.event)
        .handingOver(dependencies)
    }
  }

  /// The events of the block: under way, with a budget, coming within 120 days — and every
  /// event with a budget still ahead however far, since the free sum keeps its budget back
  /// until a day up to a year away (`budgeted`): what it keeps back is here to see and change.
  /// Each once.
  static func shown(_ events: EventsPlanning, budgeted: [EventPlan]) -> [EventPlan] {
    var seen: Set<UUID> = []
    return (events.active + events.withBudget + events.upcoming + budgeted)
      .filter { seen.insert($0.event.id).inserted }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

/// The event a form edits, or none for a new one.
struct EventFormItem: Identifiable {
  let event: Event?
  var id: String { event?.id.uuidString ?? "new" }
}

/// An event and its budget: its name, its days, and how much it may cost — an empty budget is
/// none. «Save» writes one `PlanningChange`, one step of ⌘Z.
struct EventForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  let original: Event?
  @State private var name = ""
  @State private var start = Date()
  @State private var end = Date()
  @State private var budget: AmountE4 = .zero
  @State private var loaded = false

  var body: some View {
    let event = edited
    let issue = PlanningActions.issue(
      of: event, among: compute.snapshot?.dataset.events ?? [])
    VStack(alignment: .leading) {
      Text(verbatim: t(original == nil ? "events.form.new" : "events.form.edit"))
        .font(.headline)
      Form {
        TextField(text: $name) { Text(verbatim: t("events.form.name")) }
        DatePicker(selection: $start, displayedComponents: .date) {
          Text(verbatim: t("events.form.start"))
        }
        DatePicker(selection: $end, in: start..., displayedComponents: .date) {
          Text(verbatim: t("events.form.end"))
        }
        LabeledContent(t("events.form.budget")) {
          HStack {
            AmountField(amount: $budget)
            Text(verbatim: "₽").foregroundStyle(.secondary)
          }
        }
        Text(verbatim: t("events.form.budgetHint"))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if let issue {
          Text(verbatim: t("events.issue.\(issue.rawValue)"))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .formStyle(.grouped)
      FormButtons(title: environment.language("action.save"), enabled: issue == nil) {
        guard let dependencies else { return false }
        return PlanningActions(dependencies).save(event)
      }
    }
    .padding(20)
    .frame(width: 460, height: 400)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      let calendar = environment.calendar
      if let original {
        name = original.name
        start = calendar.startOfDay(original.startDate)
        end = calendar.startOfDay(original.endDate)
        budget = original.budgetE4 ?? .zero
      } else {
        start = calendar.startOfDay(environment.today)
        end = start
      }
    }
  }

  /// The event as the form has it: the name without spaces around it, the days in order, an
  /// empty or zero budget as none.
  private var edited: Event {
    let calendar = environment.calendar
    var event =
      original
      ?? Event(name: "", startDate: environment.today, endDate: environment.today)
    event.name = PlanningActions.trimmed(name)
    event.startDate = calendar.day(of: start)
    event.endDate = max(event.startDate, calendar.day(of: end))
    event.budgetE4 = budget > .zero ? budget : nil
    return event
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
