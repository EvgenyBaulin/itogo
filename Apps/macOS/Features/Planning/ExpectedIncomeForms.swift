import AppCore
import SwiftUI

// The forms of the Planning section, one sheet at a time on the root of the section. A form
// is content: system `Form`, no glass of its own. «Save» writes one `PlanningChange` — one
// step of ⌘Z — and closes the sheet only over a write that landed.

// MARK: - Expected income

struct ExpectedIncomeForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let original: ExpectedIncome?
  @State private var income = ExpectedIncome(name: "", totalE4: .zero)
  @State private var loaded = false
  /// «On the last day of the month» of a recurring income; read off the stored day.
  @State private var lastDay = false

  var body: some View {
    let choices = PlanningChoices(compute, environment)
    VStack(alignment: .leading) {
      Text(verbatim: t(original == nil ? "form.expected.new" : "form.expected.edit")).font(
        .headline)
      Form {
        TextField(t("form.name"), text: $income.name)
        Picker(t("form.kind"), selection: $income.kind) {
          Text(verbatim: t("form.expected.oneOff")).tag(ExpectedIncomeKind.oneOff)
          Text(verbatim: t("form.expected.recurring")).tag(ExpectedIncomeKind.recurring)
        }
        .pickerStyle(.segmented)
        .onChange(of: income.kind) { followTheLastDay() }
        LabeledContent(t(income.kind == .oneOff ? "form.expected.total" : "form.expected.each")) {
          HStack {
            AmountField(amount: $income.totalE4, locale: environment.language.locale)
            Picker(selection: $income.currency) {
              ForEach(choices.currencies, id: \.self) { Text(verbatim: $0.code).tag($0) }
            } label: {
              EmptyView()
            }
            .labelsHidden()
            .fixedSize()
          }
        }
        Stepper(value: $income.partsExpected, in: 1...12) {
          Text(
            verbatim: environment.language.format(
              "form.expected.parts", table: "Planning", income.partsExpected))
        }
        DatePicker(
          t("form.expected.due"),
          selection: Binding(
            get: { environment.calendar.startOfDay(income.dueDate ?? environment.today) },
            set: {
              income.dueDate = environment.calendar.day(of: $0)
              followTheLastDay()
            }),
          displayedComponents: .date)
        if offersLastDay {
          Toggle(
            t("form.lastDay"),
            isOn: Binding(
              get: { lastDay },
              set: {
                lastDay = $0
                followTheLastDay()
              }))
        }
        if income.kind == .recurring {
          Picker(
            t("form.freq"),
            selection: Binding(
              get: { income.freq ?? .monthly },
              set: {
                income.freq = $0
                followTheLastDay()
              })
          ) {
            ForEach(Frequency.allCases, id: \.self) {
              Text(verbatim: t("form.freq.\($0.rawValue)")).tag($0)
            }
          }
        }
        Picker(t("form.category"), selection: $income.categoryId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(choices.options(.income)) {
            Text(verbatim: choices.label($0)).tag(Optional($0.id))
          }
        }
        Picker(t("form.person"), selection: $income.personId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(choices.people) { Text(verbatim: $0.name).tag(Optional($0.id)) }
        }
      }
      .formStyle(.grouped)
      HStack {
        if let original, !original.closed {
          Button(t("expected.close")) {
            if let dependencies, PlanningActions(dependencies).close(original) { dismiss() }
          }
        }
        FormButtons(
          title: environment.language("action.save"),
          enabled: !income.name.trimmingCharacters(in: .whitespaces).isEmpty
            && income.totalE4.raw > 0
        ) {
          guard let dependencies else { return false }
          return PlanningActions(dependencies).save(
            income.readyToSave(today: environment.today, lastDay: offersLastDay && lastDay))
        }
      }
    }
    .padding(20)
    .frame(width: 480, height: 520)
    .onAppear {
      guard !loaded else { return }
      loaded = true
      income = original ?? ExpectedIncome(name: "", totalE4: .zero, dueDate: environment.today)
      lastDay = income.isOnLastDay
    }
  }

  private var offersLastDay: Bool { income.offersLastDay }

  private func followTheLastDay() { income.followTheLastDay(&lastDay, today: environment.today) }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}

extension ExpectedIncome {
  /// Only a recurring income by the month or the year comes on a day of the month.
  var offersLastDay: Bool { kind == .recurring && freq != .weekly }

  /// The income as the last-day switch of its form leaves it: with the switch on, the first due
  /// date is the last day of its month. A switch the form no longer shows — a one-off income,
  /// a weekly one — is turned off: out of sight it would move a date picked later.
  mutating func followTheLastDay(_ lastDay: inout Bool, today: DateOnly) {
    guard offersLastDay else {
      lastDay = false
      return
    }
    guard lastDay else { return }
    dueDate = MonthEnd.lastDay(of: dueDate ?? today)
  }

  /// Whether a recurring income comes on the last day of the month: its day is the one a rule
  /// keeps for it (`MonthEnd`).
  var isOnLastDay: Bool {
    kind == .recurring
      && MonthEnd.isLastDay(day: day, freq: freq ?? .monthly, month: dueDate?.month)
  }

  /// The row the form saves: a recurring income keeps its frequency and the day of it, a
  /// one-off one neither, and a due date left empty is today — the day the date field shows.
  /// With `lastDay` a monthly or yearly income keeps the day of the last day of the month, so
  /// a first due of 30 September is followed by 31 October, not by 30 October.
  func readyToSave(today: DateOnly, lastDay: Bool = false) -> ExpectedIncome {
    var saved = self
    // The date first: the day of the schedule is read off it.
    if saved.dueDate == nil { saved.dueDate = today }
    if saved.kind == .recurring {
      let freq = saved.freq ?? .monthly
      saved.freq = freq
      saved.day = saved.dueDate.map { due in
        lastDay && freq != .weekly
          ? MonthEnd.day(freq: freq, month: due.month)
          : Recurrence.anchor(of: due, freq: freq).day
      }
    } else {
      saved.freq = nil
      saved.day = nil
    }
    return saved
  }
}

/// Ties an income already received to what was expected: the income of the last 60 days not
/// tied to anything yet, the likeliest first (same category and person).
struct LinkIncomeForm: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let status: ExpectedIncomeStatus

  var body: some View {
    let candidates = self.candidates
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: environment.format("form.link.title", table: "Planning", status.income.name))
        .font(.headline)
      if candidates.isEmpty {
        Text(verbatim: t("form.link.none")).foregroundStyle(.secondary)
      }
      List(candidates, id: \.id) { entry in
        HStack {
          Text(
            verbatim: environment.dates.longDay(
              environment.calendar.day(of: entry.transaction.occurredAt))
          )
          .monospacedDigit()
          .foregroundStyle(.secondary)
          Text(verbatim: entry.transaction.note ?? "—").lineLimit(1)
          Spacer()
          Text(
            verbatim: environment.money.exact(
              entry.transaction.amountE4, currency: entry.transaction.currency)
          )
          .monospacedDigit()
          Button(t("expected.link")) {
            guard let dependencies else { return }
            if PlanningActions(dependencies).link(income: entry.id, to: status.income) { dismiss() }
          }
          .buttonStyle(.bordered)
          .controlSize(.small)
        }
      }
      .frame(minHeight: 220)
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 520, height: 380)
  }

  private var candidates: [TransactionEntry] {
    guard let snapshot = compute.snapshot else { return [] }
    let linked = Set(snapshot.dataset.planning.expectedLinks.map(\.transactionId))
    let since = environment.calendar.adding(days: -60, to: snapshot.today)
    return snapshot.dataset.entries
      .filter {
        $0.transaction.kind == .income && !$0.transaction.isDeleted && !linked.contains($0.id)
          && environment.calendar.day(of: $0.transaction.occurredAt) >= since
      }
      .sorted { lhs, rhs in
        let left = likely(lhs)
        let right = likely(rhs)
        return left != right ? left : lhs.transaction.occurredAt > rhs.transaction.occurredAt
      }
  }

  private func likely(_ entry: TransactionEntry) -> Bool {
    entry.parts.contains {
      $0.categoryId == status.income.categoryId && status.income.categoryId != nil
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
