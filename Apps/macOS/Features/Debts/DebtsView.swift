import AppCore
import SwiftUI

/// The Debts section of the main window, ⌘3: the totals on top, «I owe» and «Owed to me» on
/// the left — personal debts and the parts paid for others that wait to come back, by person —
/// and the card of the chosen debt on the right with its journal by groups and its actions.
/// Debt balances are never part of Overview, Analytics or Reports: only operations are.
struct DebtsView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @State private var selection: DebtsSelection?
  @State private var sheet: DebtSheet?
  @State private var recordingReimbursement = false
  /// The debt «Удалить…» asks about.
  @State private var deleting: DebtLine?
  @State private var deleteFailed = false

  var body: some View {
    ComputedBlock(
      title: nil, state: compute.states.data, style: .plain,
      retry: { compute.retry(ComputeStep.data) }
    ) { snapshot in
      let overview = snapshot.planning.debts
      VStack(alignment: .leading, spacing: 0) {
        totals(overview)
          .padding(.horizontal, 20)
          .padding(.vertical, 12)
        Divider()
        HStack(spacing: 0) {
          DebtsList(
            overview: overview, people: snapshot.dataset.people, selection: $selection,
            deleting: $deleting
          )
          .frame(width: 300)
          Divider()
          detail(overview, snapshot: snapshot)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
      }
    }
    .navigationTitle(environment.language("section.debts"))
    .task {
      // `--present debt`: the card of the first debt, as a click on it shows it.
      guard await LaunchPresentation.due(.debt) else { return }
      for _ in 0..<50 where compute.snapshot == nil {
        try? await Task.sleep(for: .milliseconds(200))
      }
      if let first = compute.snapshot?.planning.debts.iOwe.first { selection = .debt(first.id) }
    }
    .sheet(item: $sheet) { sheet in
      DebtSheetView(sheet: sheet).handingOver(dependencies)
    }
    .sheet(isPresented: $recordingReimbursement) {
      ReimbursementSheet().handingOver(dependencies)
    }
    .confirmationDialog(
      deletionTitle, isPresented: deletionAsked, titleVisibility: .visible, presenting: deleting
    ) { line in
      Button(t("debts.delete.action"), role: .destructive) { delete(line) }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: { line in
      Text(verbatim: deletionMessage(line))
    }
    .alert(t("debts.deleteFailed"), isPresented: $deleteFailed) {
      Button(environment.language("action.ok")) {}
    }
  }

  private var deletionAsked: Binding<Bool> {
    Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
  }

  private var deletionTitle: String {
    environment.format("debts.delete.title", table: "Debts", deleting?.debt.name ?? "")
  }

  /// What the confirmation says stays and goes, from the data on screen.
  private func deletionMessage(_ line: DebtLine) -> String {
    guard let snapshot = compute.snapshot else { return t("debts.delete.undo") }
    let deletion = DebtActions.deletion(of: line.debt, snapshot: snapshot, at: Date())
    return DebtDeletionText.message(
      deletion, personName: snapshot.dataset.people.first { $0.id == line.debt.personId }?.name,
      language: environment.language, money: environment.money)
  }

  private func delete(_ line: DebtLine) {
    guard let dependencies else { return }
    if DebtActions(dependencies).delete(line.debt) {
      if selection == .debt(line.id) { selection = nil }
    } else {
      deleteFailed = true
    }
    deleting = nil
  }

  private func totals(_ overview: DebtsOverview) -> some View {
    HStack(spacing: 24) {
      figure(t("debts.iOwe"), overview.totalIOweRub)
      figure(t("debts.monthly"), overview.monthlyPaymentsRub)
      figure(t("debts.owedToMe"), overview.totalOwedToMeRub)
      if !overview.withoutRate.isEmpty {
        Text(
          verbatim: environment.language.format(
            "debts.withoutRateCount", table: "Debts", counts: overview.withoutRate.count)
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button(t("debts.add")) { sheet = .create }
        .buttonStyle(.bordered)
    }
  }

  private func figure(_ label: String, _ amount: AmountE4) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: label).font(.caption).foregroundStyle(.secondary)
      Text(verbatim: environment.money.rounded(amount)).font(.headline.monospacedDigit())
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func detail(_ overview: DebtsOverview, snapshot: DataSnapshot) -> some View {
    switch selection {
    case .debt(let id):
      if let line = (overview.iOwe + overview.closed + overview.owedToMe.flatMap(\.debts))
        .first(where: { $0.id == id })
      {
        DebtDetail(
          line: line, all: overview.iOwe + overview.owedToMe.flatMap(\.debts), sheet: $sheet,
          deleting: $deleting)
      } else {
        placeholder
      }
    case .person(let id):
      if let group = overview.owedToMe.first(where: { $0.personId == id }) {
        PersonDetail(
          group: group, people: snapshot.dataset.people,
          record: { recordingReimbursement = true }, open: { selection = .debt($0) },
          sheet: $sheet)
      } else {
        placeholder
      }
    case nil:
      placeholder
    }
  }

  private var placeholder: some View {
    Text(verbatim: t("debts.choose"))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

enum DebtsSelection: Hashable {
  case debt(UUID)
  case person(UUID?)
}

/// A row of «Owed to me»: a person with everything they owe, and under them each personal
/// debt of theirs, which opens its card — the journal and every action — as a debt I owe does.
enum OwedToMeRow: Identifiable, Hashable {
  case person(OwedToMeGroup)
  case debt(DebtLine)

  var selection: DebtsSelection {
    switch self {
    case .person(let group): .person(group.personId)
    case .debt(let line): .debt(line.id)
    }
  }

  var id: DebtsSelection { selection }

  static func rows(of overview: DebtsOverview) -> [OwedToMeRow] {
    overview.owedToMe.flatMap { group in [.person(group)] + group.debts.map { .debt($0) } }
  }
}

/// The actions the card of a debt offers. A closed debt offers «Reopen» and «Delete…» only: a
/// payment or a line on it would move a balance no list, total or reminder shows any more.
/// «Delete…» comes last, open or closed.
enum DebtCardAction: Hashable {
  case pay, addEntry, offset, transfer, adjust, close, reopen, delete

  static func offered(for debt: Debt) -> [DebtCardAction] {
    guard !debt.closed else { return [.reopen, .delete] }
    return [.pay, .addEntry] + (debt.direction == .iOwe ? [.offset] : [])
      + [.transfer, .adjust, .close, .delete]
  }
}

extension DebtLine {
  /// The next payment was due before today and is still unpaid: «просрочен» beside it.
  func isOverdue(today: DateOnly) -> Bool {
    guard !debt.closed, let next = nextPayment else { return false }
    return next < today
  }

  /// «Оплачено X из Y — осталось Z» on the card: money paid toward the earliest owed due, less
  /// than the due, of a debt I owe with a monthly payment. The due stays owed until it is covered.
  var partialDue: (paid: AmountE4, due: AmountE4, left: AmountE4)? {
    guard debt.direction == .iOwe, dues.owes, dues.partialE4.raw > 0,
      let monthly = debt.monthlyPaymentE4
    else { return nil }
    return (dues.partialE4, monthly, max(monthly - dues.partialE4, .zero))
  }
}

/// The words of the confirmation of «Удалить…»: what leaves with the debt and what stays, one
/// sentence a line — the journal, what was left on it, the operations that paid it by what they
/// were, the purchases on credit, the money the journal moved, the archived subcategory, the
/// income a later repayment would be, and that ⌘Z brings it back.
@MainActor
enum DebtDeletionText {
  static func message(
    _ deletion: DebtDeletion, personName: String?, language: AppLanguage, money: MoneyFormatter
  ) -> String {
    let debt = deletion.debt
    var lines = [
      language.format("debts.delete.journal", table: "Debts", counts: deletion.journalLines)
    ]
    if !deletion.balance.isZero {
      let amount = money.exact(deletion.balance.magnitude, currency: debt.currency)
      lines.append(
        language.format(
          "debts.delete.left", table: "Debts",
          deletion.balance.isNegative ? "\u{2212}" + amount : amount))
    }
    if deletion.operations > 0 {
      let key =
        switch deletion.meaning {
        case .loansExpense: "debts.delete.ops.loans"
        case .notSpending: "debts.delete.ops.notSpending"
        case .moneyBack: "debts.delete.ops.moneyBack"
        }
      lines.append(language.format(key, table: "Debts", counts: deletion.operations))
    }
    for purchase in deletion.creditPurchases {
      lines.append(
        language.format(
          "debts.delete.purchase", table: "Debts", purchase.transaction.note ?? debt.name))
    }
    if deletion.movesMoneyLines > 0 { lines.append(language("debts.delete.cash", table: "Debts")) }
    if let subcategory = deletion.archivedSubcategory {
      lines.append(language.format("debts.delete.category", table: "Debts", subcategory.name))
    }
    if deletion.warnsOfIncomeLater {
      lines.append(
        language.format("debts.delete.owedLater", table: "Debts", personName ?? debt.name))
    }
    lines.append(language("debts.delete.undo", table: "Debts"))
    return lines.joined(separator: "\n")
  }
}

/// «I owe», «Owed to me» by person, and the closed debts folded.
private struct DebtsList: View {
  @Dependency(\.environment) private var environment
  let overview: DebtsOverview
  let people: [Person]
  @Binding var selection: DebtsSelection?
  @Binding var deleting: DebtLine?
  @State private var showsClosed = false

  var body: some View {
    List(selection: $selection) {
      Section {
        if overview.iOwe.isEmpty {
          Text(verbatim: t("debts.none")).foregroundStyle(.secondary)
        }
        ForEach(overview.iOwe) { line in
          row(
            line.debt.name, line.balanceRub ?? line.balance,
            currency: line.balanceRub == nil ? line.debt.currency : .rub,
            withoutRate: overview.withoutRate.contains(line.id)
          )
          .tag(DebtsSelection.debt(line.id))
          .contextMenu { deleteButton(line) }
        }
      } header: {
        Text(verbatim: t("debts.iOwe"))
      }
      Section {
        if overview.owedToMe.isEmpty {
          Text(verbatim: t("debts.nobodyOwes")).foregroundStyle(.secondary)
        }
        ForEach(OwedToMeRow.rows(of: overview)) { item in
          switch item {
          case .person(let group):
            row(
              name(group.personId), group.totalRub, currency: .rub,
              withoutRate: group.debts.contains { overview.withoutRate.contains($0.id) }
            )
            .tag(item.selection)
          case .debt(let line):
            row(
              line.debt.name, line.balance, currency: line.debt.currency,
              withoutRate: overview.withoutRate.contains(line.id)
            )
            .padding(.leading, 14)
            .tag(item.selection)
            .contextMenu { deleteButton(line) }
          }
        }
      } header: {
        Text(verbatim: t("debts.owedToMe"))
      }
      if !overview.closed.isEmpty {
        // Folded by default: closed debts pile up over the years. The header
        // is its own button: an inset list on macOS draws no disclosure for a section.
        Section {
          if showsClosed {
            ForEach(overview.closed) { line in
              row(line.debt.name, line.balance, currency: line.debt.currency)
                .foregroundStyle(.secondary)
                .tag(DebtsSelection.debt(line.id))
                .contextMenu { deleteButton(line) }
            }
          }
        } header: {
          Button {
            withAnimation(.snappy) { showsClosed.toggle() }
          } label: {
            HStack(spacing: 4) {
              Image(systemName: "chevron.right")
                .rotationEffect(.degrees(showsClosed ? 90 : 0))
                .accessibilityHidden(true)
              Text(verbatim: "\(t("debts.closed")) (\(overview.closed.count))")
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
    // Content, not navigation: no material under the list.
    .listStyle(.inset)
  }

  private func row(
    _ title: String, _ amount: AmountE4, currency: CurrencyCode, withoutRate: Bool = false
  ) -> some View {
    HStack {
      Text(verbatim: title).lineLimit(1)
      Spacer(minLength: 6)
      if withoutRate {
        // Not in the totals: there is no rate to count it in rubles.
        Text(verbatim: t("debts.withoutRate")).font(.caption).foregroundStyle(.secondary)
      }
      Text(verbatim: environment.money.rounded(amount, currency: currency)).monospacedDigit()
    }
  }

  private func name(_ id: UUID?) -> String {
    people.first { $0.id == id }?.name ?? t("debts.noPerson")
  }

  private func deleteButton(_ line: DebtLine) -> some View {
    Button(t("debts.delete"), role: .destructive) { deleting = line }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

/// The card of one debt: type, balance, payment and day, rate, «payments are expenses», the
/// early payoff scenario, the journal by groups with their totals, and the actions.
private struct DebtDetail: View {
  @Dependency(\.environment) private var environment
  @Environment(\.dependencies) private var dependencies
  let line: DebtLine
  let all: [DebtLine]
  @Binding var sheet: DebtSheet?
  @Binding var deleting: DebtLine?
  @State private var confirmsToggle = false
  @State private var reopenFailed = false

  var body: some View {
    let debt = line.debt
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text(verbatim: debt.name).font(.title2)
        Text(verbatim: facts).foregroundStyle(.secondary)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
          Text(verbatim: t("debts.balance"))
          Text(verbatim: environment.money.exact(line.balance, currency: debt.currency))
            .font(.title3.monospacedDigit())
          if let next = line.nextPayment {
            Text(
              verbatim: environment.format(
                "debts.nextPayment", table: "Debts", environment.dates.longDay(next))
            )
            .foregroundStyle(.secondary)
            if line.isOverdue(today: environment.today) {
              // A symbol and a word, never a colour alone.
              Label(t("debts.overdue"), systemImage: "exclamationmark.circle")
                .accessibilityIdentifier("debts.overdue")
            }
          }
        }
        // Money paid toward a due, less than the due: the due stays owed until it is covered.
        if let partial = line.partialDue {
          Text(
            verbatim: environment.format(
              "debts.partialDue", table: "Debts",
              environment.money.exact(partial.paid, currency: debt.currency),
              environment.money.exact(partial.due, currency: debt.currency),
              environment.money.exact(partial.left, currency: debt.currency))
          )
          .font(.caption).foregroundStyle(.secondary)
          .accessibilityIdentifier("debts.partialDue")
        }
        if debt.direction == .iOwe {
          Toggle(
            isOn: Binding(
              get: { debt.paymentsAreExpenses },
              set: { _ in confirmsToggle = true })
          ) {
            Text(verbatim: t("debts.paymentsAreExpenses"))
          }
          .confirmationDialog(
            t("debts.toggleTitle"), isPresented: $confirmsToggle, titleVisibility: .visible
          ) {
            Button(t("debts.toggleConfirm")) {
              var changed = debt
              changed.paymentsAreExpenses.toggle()
              if let dependencies { DebtActions(dependencies).save(changed) }
            }
          } message: {
            Text(verbatim: t("debts.toggleMessage"))
          }
          if let payoff = payoff {
            Text(verbatim: payoff).font(.caption).foregroundStyle(.secondary)
          }
        }
        actions
        Divider()
        journal
      }
      .padding(20)
    }
  }

  private var facts: String {
    let debt = line.debt
    var pieces = [t("debts.type.\(debt.type.rawValue)")]
    if let rate = debt.interestRate {
      pieces.append(
        environment.format(
          "debts.rate", table: "Debts", environment.money.rate(rate)))
    }
    if let payment = debt.monthlyPaymentE4 {
      pieces.append(
        DebtSheetView.cardPaymentText(
          environment.money.rounded(payment, currency: debt.currency), day: debt.paymentDay,
          language: environment.language))
    }
    return pieces.joined(separator: " · ")
  }

  /// «Досрочно +2,000 ₽ в месяц — закроется на 7 мес. раньше».
  private var payoff: String? {
    let debt = line.debt
    guard let payment = debt.monthlyPaymentE4, payment.raw > 0, line.balance.raw > 0 else {
      return nil
    }
    // A tenth of the payment in the debt's currency, as Advice tries it: at least 100 of any
    // currency made a 50 USD payment +100 USD a month.
    let extra = DebtPayoff.suggestedExtra(for: payment, currency: debt.currency)
    let scenario = DebtPayoff.scenario(
      balance: line.balance, annualRatePercent: debt.interestRate,
      monthlyPayment: payment, extra: extra)
    guard let saved = scenario.monthsSaved else {
      return scenario.monthsWithout == nil ? t("debts.payoffNever") : nil
    }
    return environment.format(
      "debts.payoff", table: "Debts", environment.money.rounded(extra, currency: debt.currency),
      environment.language.format("advice.months", table: "Planning", counts: saved))
  }

  @ViewBuilder
  private var actions: some View {
    if line.debt.closed {
      Text(verbatim: t("debts.closedCaption")).font(.caption).foregroundStyle(.secondary)
    }
    HStack(spacing: 8) {
      ForEach(DebtCardAction.offered(for: line.debt), id: \.self) { action in
        if action == .pay || action == .reopen {
          button(action).buttonStyle(.borderedProminent)
        } else {
          button(action)
        }
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .alert(t("debts.reopenFailed"), isPresented: $reopenFailed) {
      Button(environment.language("action.ok")) {}
    }
  }

  private func button(_ action: DebtCardAction) -> Button<Text> {
    let debt = line.debt
    switch action {
    case .pay:
      return Button(t("debts.pay")) { sheet = .pay(debt) }
    case .addEntry:
      return Button(t("debts.addEntry")) { sheet = .entry(debt) }
    case .offset:
      return Button(t("debts.offset")) { sheet = .offset(debt) }
    case .transfer:
      return Button(t("debts.transfer")) {
        sheet = .transfer(
          debt, balance: line.balance, others: all.map(\.debt).filter { $0.id != debt.id })
      }
    case .adjust:
      return Button(t("debts.adjust")) { sheet = .adjust(debt, balance: line.balance) }
    case .close:
      return Button(t("debts.close")) { sheet = .close(debt, balance: line.balance) }
    case .reopen:
      return Button(t("debts.reopen")) {
        guard let dependencies else { return }
        if !DebtActions(dependencies).reopen(debt) { reopenFailed = true }
      }
    case .delete:
      return Button(t("debts.delete"), role: .destructive) { deleting = line }
    }
  }

  /// The lines by group, each group with its total («журнал записей с группами и итогами
  /// по группам»).
  private var journal: some View {
    let byGroup = Dictionary(grouping: line.entries, by: \.groupName)
    return VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: t("debts.journal")).font(.headline)
      if line.entries.isEmpty {
        Text(verbatim: t("debts.journalEmpty")).foregroundStyle(.secondary)
      }
      ForEach(line.groups, id: \.groupName) { group in
        VStack(alignment: .leading, spacing: 4) {
          HStack {
            Text(verbatim: group.groupName ?? t("debts.noGroup")).font(
              .subheadline.weight(.semibold))
            Spacer()
            Text(
              verbatim: environment.format(
                "debts.groupTotal", table: "Debts",
                environment.money.exact(group.totalE4, currency: line.debt.currency))
            )
            .font(.subheadline.monospacedDigit())
          }
          ForEach(byGroup[group.groupName] ?? [], id: \.id) { entry in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
              Text(verbatim: entry.date.map(day) ?? "—")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 110, alignment: .leading)
              Text(verbatim: entry.description ?? t("debts.kind.\(entry.kind.rawValue)"))
                .lineLimit(1)
              // «В этом месяце больше платежей не будет»: said, so the due is shown as closed.
              if entry.closesTerm {
                Label {
                  Text(verbatim: t("debts.journal.closesTerm"))
                } icon: {
                  Image(systemName: "checkmark.circle")
                }
                .font(.caption).foregroundStyle(.secondary)
                .help(t("debts.journal.closesTermHelp"))
              }
              if let full = entry.fullAmountE4, let share = entry.share {
                Text(
                  verbatim: environment.money.rounded(full, currency: line.debt.currency) + " × "
                    + environment.money.number(share)
                )
                .font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Text(
                // Exact, like the group totals and the balance it adds up to.
                verbatim: (entry.amountE4.isZero ? "" : entry.amountE4.isNegative ? "−" : "+")
                  + environment.money.exact(entry.amountE4.magnitude, currency: line.debt.currency)
              )
              .monospacedDigit()
            }
            .font(.callout)
          }
        }
      }
    }
  }

  /// «25 августа», with the year when it is not this one: a journal runs over years.
  private func day(_ date: DateOnly) -> String {
    date.year == environment.today.year
      ? environment.dates.dayAndMonth(date) : environment.dates.longDay(date)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}

/// A person in «Owed to me»: personal debts and the parts paid for them that wait to come
/// back, oldest first, with «Record reimbursement». A debt's name opens its card.
private struct PersonDetail: View {
  @Dependency(\.environment) private var environment
  let group: OwedToMeGroup
  let people: [Person]
  let record: () -> Void
  let open: (UUID) -> Void
  @Binding var sheet: DebtSheet?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        Text(verbatim: people.first { $0.id == group.personId }?.name ?? t("debts.noPerson"))
          .font(.title2)
        Text(verbatim: environment.money.rounded(group.totalRub)).font(.title3.monospacedDigit())
        if !group.parts.isEmpty {
          Button(environment.language("reimbursement.title", table: "Entry"), action: record)
            .buttonStyle(.bordered)
          Text(verbatim: t("debts.parts")).font(.headline)
          ForEach(group.parts) { part in
            HStack {
              Text(verbatim: environment.dates.dayAndMonth(part.day)).monospacedDigit()
                .foregroundStyle(.secondary)
              Text(verbatim: part.note ?? "—").lineLimit(1)
              Spacer()
              Text(verbatim: environment.money.exact(part.amountRub)).monospacedDigit()
            }
            .font(.callout)
          }
        }
        ForEach(group.debts) { line in
          HStack {
            Button(line.debt.name) { open(line.debt.id) }
              .buttonStyle(.link)
            Spacer()
            Text(verbatim: environment.money.exact(line.balance, currency: line.debt.currency))
              .monospacedDigit()
            Button(t("debts.pay")) { sheet = .pay(line.debt) }
              .buttonStyle(.bordered).controlSize(.small)
          }
        }
      }
      .padding(20)
    }
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
