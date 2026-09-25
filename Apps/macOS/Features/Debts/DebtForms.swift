import AppCore
import SwiftUI

/// Which form the Debts section shows.
enum DebtSheet: Identifiable {
  case create
  case pay(Debt)
  case entry(Debt)
  case offset(Debt)
  case transfer(Debt, balance: AmountE4, others: [Debt])
  case adjust(Debt, balance: AmountE4)
  case close(Debt, balance: AmountE4)

  var id: String {
    switch self {
    case .create: "create"
    case .pay(let debt): "pay-\(debt.id)"
    case .entry(let debt): "entry-\(debt.id)"
    case .offset(let debt): "offset-\(debt.id)"
    case .transfer(let debt, _, _): "transfer-\(debt.id)"
    case .adjust(let debt, _): "adjust-\(debt.id)"
    case .close(let debt, _): "close-\(debt.id)"
    }
  }
}

/// The forms of the Debts section: system `Form`, no glass; the main action writes one change,
/// one step of ⌘Z, and closes the sheet only over a write that landed.
struct DebtSheetView: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  let sheet: DebtSheet
  /// Told once the action has landed: the reminders sheet takes its row away then, so the
  /// same payment is not offered twice.
  var onDone: () -> Void = {}
  /// The due a reminder's «Платёж» is for: one of next month is paid on its own day.
  var payDue: DateOnly?

  @State private var debt = Debt(direction: .iOwe, type: .loan, name: "")
  @State private var amount: AmountE4 = .zero
  @State private var fullAmount: AmountE4 = .zero
  @State private var shareText = ""
  @State private var byShare = false
  @State private var moneyMoved = false
  @State private var date = Date()
  @State private var method: UUID?
  @State private var text = ""
  @State private var group = ""
  @State private var target: UUID?
  @State private var writeOff = true
  @State private var loaded = false
  @State private var rateText = ""
  @State private var failed: String?
  /// What is left on the debt, read from the journal when the form opens; `nil` without a
  /// database, and the figure the card was drawn with stands in (`shown`).
  @State private var balance: AmountE4?
  @State private var closesDebt = true

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: title).font(.headline)
      Form { fields }
        .formStyle(.grouped)
      if let failed {
        // Never left open without a word (review of the app, 19.09).
        Text(verbatim: failed)
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(action.title) {
          if action.run() {
            onDone()
            dismiss()
          } else {
            failed = failure()
          }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!action.enabled)
      }
    }
    .padding(20)
    .frame(width: 480)
    .onAppear(perform: load)
  }

  // MARK: The fields of each form

  @ViewBuilder
  private var fields: some View {
    switch sheet {
    case .create:
      TextField(t("form.name"), text: $debt.name)
      Picker(t("form.direction"), selection: $debt.direction) {
        Text(verbatim: t("debts.iOwe")).tag(DebtDirection.iOwe)
        Text(verbatim: t("debts.owedToMe")).tag(DebtDirection.owedToMe)
      }
      .pickerStyle(.segmented)
      Picker(t("form.type"), selection: $debt.type) {
        ForEach(DebtType.allCases, id: \.self) {
          Text(verbatim: t("debts.type.\($0.rawValue)")).tag($0)
        }
      }
      if debt.type == .personal {
        Picker(t("form.person"), selection: $debt.personId) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(people) { Text(verbatim: $0.name).tag(Optional($0.id)) }
        }
      }
      Picker(t("form.currency"), selection: $debt.currency) {
        ForEach(currencies, id: \.self) { Text(verbatim: $0.code).tag($0) }
      }
      LabeledContent(t("form.balance")) { amountField($amount) }
      if amount.isNegative {
        Text(verbatim: t("form.balance.negative")).font(.caption).foregroundStyle(.secondary)
      }
      Toggle(t("form.moneyMovedToday"), isOn: $moneyMoved)
      TextField(t("form.rate"), text: $rateText)
      LabeledContent(t("form.monthlyPayment")) {
        amountField(
          Binding(
            get: { debt.monthlyPaymentE4 ?? .zero },
            set: { debt.monthlyPaymentE4 = $0.isZero ? nil : $0 }))
      }
      // A day of payment only with a payment: a loan from a friend with no schedule is not
      // reminded of on the 1st (third review, 19.09).
      if debt.monthlyPaymentE4 != nil {
        Stepper(
          value: Binding(get: { debt.paymentDay ?? 1 }, set: { debt.paymentDay = $0 }), in: 1...31
        ) {
          Text(
            verbatim: Self.paymentDayText(debt.paymentDay ?? 1, language: environment.language))
        }
      }
      if debt.direction == .iOwe {
        Toggle(t("debts.paymentsAreExpenses"), isOn: $debt.paymentsAreExpenses)
      }
    case .pay(let debt), .offset(let debt):
      LabeledContent(t("form.amount")) { amountField($amount, currency: debt.currency) }
      DatePicker(t("form.date"), selection: $date)
      if case .pay = sheet {
        Picker(t("form.method"), selection: $method) {
          Text(verbatim: "—").tag(UUID?.none)
          ForEach(methods) { Text(verbatim: $0.name).tag(Optional($0.id)) }
        }
        Text(
          verbatim: t(
            DebtRules.paymentIsExpense(on: debt)
              ? "form.pay.expense"
              : (debt.direction == .iOwe ? "form.pay.notExpense" : "form.pay.returned"))
        )
        .font(.caption).foregroundStyle(.secondary)
        if paysOff, let balance {
          // Said, and closing offered: paid off and left open, the debt stayed in its list at
          // zero or below, and went on being reminded of.
          Toggle(t("form.pay.close"), isOn: $closesDebt)
          if amount > balance {
            Text(
              verbatim: environment.format(
                "form.pay.over", table: "Debts",
                environment.money.exact(balance, currency: debt.currency),
                environment.money.exact(amount - balance, currency: debt.currency))
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      } else {
        TextField(t("form.description"), text: $text)
      }
    case .entry(let debt):
      Toggle(t("form.moneyMoved"), isOn: $moneyMoved)
      Toggle(t("form.byShare"), isOn: $byShare)
      if byShare {
        LabeledContent(t("form.fullAmount")) { amountField($fullAmount, currency: debt.currency) }
        TextField(t("form.share"), text: $shareText)
        if let share = DebtRules.parseShare(shareText),
          let part = try? DebtRules.share(of: fullAmount, share: share)
        {
          Text(verbatim: environment.money.exact(part, currency: debt.currency)).font(
            .caption.monospacedDigit())
        }
      } else {
        LabeledContent(t("form.amount")) { amountField($amount, currency: debt.currency) }
      }
      TextField(t("form.group"), text: $group)
      TextField(t("form.description"), text: $text)
      DatePicker(t("form.date"), selection: $date, displayedComponents: .date)
    case .transfer(let debt, let carried, let others):
      let balance = shown(carried)
      Text(
        verbatim: environment.format(
          "form.transfer.from", table: "Debts", debt.name,
          environment.money.exact(balance, currency: debt.currency)))
      Picker(t("form.transfer.to"), selection: $target) {
        Text(verbatim: "—").tag(UUID?.none)
        ForEach(others.filter { $0.currency == debt.currency && !$0.closed }) {
          Text(verbatim: $0.name).tag(Optional($0.id))
        }
      }
      LabeledContent(t("form.amount")) { amountField($amount, currency: debt.currency) }
      if amount > balance {
        // Refused, not capped: the source would close with money on it.
        Text(verbatim: t("form.transfer.tooMuch")).font(.caption).foregroundStyle(.secondary)
      }
      DatePicker(t("form.date"), selection: $date, displayedComponents: .date)
    case .adjust(let debt, let carried):
      Text(
        verbatim: environment.format(
          "form.adjust.now", table: "Debts",
          environment.money.exact(shown(carried), currency: debt.currency)))
      LabeledContent(t("form.adjust.to")) { amountField($amount, currency: debt.currency) }
      if let over = Self.overpaid(to: amount) {
        // Asked, not refused: an overpaid card is below zero for real.
        Text(
          verbatim: environment.format(
            "form.adjust.negative", table: "Debts",
            environment.money.exact(over, currency: debt.currency))
        )
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      TextField(t("form.note"), text: $text)
    case .close(let debt, let carried):
      Text(
        verbatim: environment.format(
          "form.close.balance", table: "Debts",
          environment.money.exact(shown(carried), currency: debt.currency)))
      if !shown(carried).isZero {
        Toggle(t("form.close.writeOff"), isOn: $writeOff)
      }
    }
  }

  private func amountField(_ value: Binding<AmountE4>, currency: CurrencyCode? = nil) -> some View {
    HStack {
      AmountField(amount: value, locale: environment.language.locale)
      if let currency { Text(verbatim: currency.code).foregroundStyle(.secondary) }
    }
  }

  // MARK: What «Save» does

  private var action: (title: String, enabled: Bool, run: () -> Bool) {
    let day = environment.calendar.day(of: date)
    guard let dependencies else { return (t("form.save"), false, { false }) }
    let actions = DebtActions(dependencies)
    switch sheet {
    case .create:
      let valid =
        !debt.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !amount.isNegative
      var made = debt
      made.interestRate = DebtPayoff.parseRate(rateText)
      made.paymentDay = Self.savedPaymentDay(monthly: made.monthlyPaymentE4, day: made.paymentDay)
      if made.direction == .owedToMe { made.paymentsAreExpenses = false }
      return (
        t("form.save"), valid,
        { actions.create(made, balance: amount, on: environment.today, moneyMovedNow: moneyMoved) }
      )
    case .pay(let debt):
      let closing = paysOff && closesDebt
      return (
        t("debts.pay"), amount.raw > 0,
        {
          actions.pay(debt, amount: amount, on: date, paymentMethodId: method, closing: closing)
        }
      )
    case .offset(let debt):
      return (
        t("debts.offset"), amount.raw > 0,
        {
          actions.offset(debt, amount: amount, on: date, description: text.isEmpty ? nil : text)
        }
      )
    case .entry(let debt):
      let share = byShare ? DebtRules.parseShare(shareText) : nil
      let valid = byShare ? (share != nil && fullAmount.raw > 0) : amount.raw > 0
      return (
        t("debts.addEntry"), valid,
        {
          actions.addEntry(
            debt, amount: amount, fullAmount: byShare ? fullAmount : nil, share: share, on: day,
            group: group.isEmpty ? nil : group, description: text.isEmpty ? nil : text,
            moneyMoved: moneyMoved)
        }
      )
    // The actions read the journal again when they write: what landed since the form opened
    // is not written off, transferred or adjusted over.
    case .transfer(let debt, let carried, let others):
      let destination = others.first { $0.id == target }
      let balance = shown(carried)
      return (
        t("debts.transfer"), destination != nil && amount.raw > 0 && amount <= balance,
        {
          guard let destination else { return false }
          return actions.transfer(debt, balance: balance, to: destination, amount: amount, on: day)
        }
      )
    case .adjust(let debt, let carried):
      let balance = shown(carried)
      return (
        t("debts.adjust"), amount != balance,
        {
          actions.adjust(debt, from: balance, to: amount, on: day, note: text.isEmpty ? nil : text)
        }
      )
    case .close(let debt, let carried):
      return (
        t("debts.close"), true,
        { actions.close(debt, balance: shown(carried), writeOff: writeOff, on: day) }
      )
    }
  }

  /// Why the action did not happen: no rate for the debt's currency on that day, or else.
  /// Why the action did not happen. Only a payment and an «Offset» write an operation that
  /// needs a rate; the other actions write the journal alone, so a rate is never the reason.
  private func failure() -> String {
    let generic = environment.language("form.notSaved", table: "Planning")
    guard let dependencies else { return generic }
    switch sheet {
    case .pay(let debt), .offset(let debt):
      return environment.format(
        PlanningActions(dependencies).failureKey(currency: debt.currency, on: date, at: .debt),
        table: "Planning", debt.currency.code)
    case .create, .entry, .transfer, .adjust, .close:
      return generic
    }
  }

  /// The date «Платёж» starts with when it pays `due`: the due itself (at noon) when it is
  /// in a later month than today — a payment made ahead for October belongs to October,
  /// the month the schedule counts it in — and nothing, that is now, otherwise.
  static func payDate(due: DateOnly?, today: DateOnly, calendar: CalendarContext) -> Date? {
    guard let due, due.monthKey > today.monthKey else { return nil }
    return calendar.startOfDay(due).addingTimeInterval(12 * 3600)
  }

  /// Whether «Pay» starts with «Close the debt» on once the payment covers what is left. A
  /// credit card is paid down to zero month after month and stays open; any other debt paid
  /// off is done with.
  static func closesWhenPaidOff(_ debt: Debt) -> Bool { debt.type != .creditCard }

  /// How much more than owed a balance below zero says was paid; `nil` at zero and above.
  static func overpaid(to balance: AmountE4) -> AmountE4? {
    balance.isNegative ? balance.magnitude : nil
  }

  /// What is left on the debt as the form shows it: the journal read when it opened, else the
  /// figure the card handed over.
  private func shown(_ carried: AmountE4) -> AmountE4 { balance ?? carried }

  /// The payment typed covers what is left on the debt.
  private var paysOff: Bool {
    guard let balance else { return false }
    return DebtActions.paysOff(amount, balance: balance)
  }

  /// The day of payment a new debt is saved with: the one shown — the 1st until changed —
  /// when it has a monthly payment, none without one.
  static func savedPaymentDay(monthly: AmountE4?, day: Int?) -> Int? {
    monthly == nil ? nil : (day ?? 1)
  }

  /// The caption of the day stepper: «День платежа: 5», and at 31 «последний день» — a debt due
  /// on the 31st is due on the last day of every shorter month.
  static func paymentDayText(_ day: Int, language: AppLanguage) -> String {
    let shown = day >= 31 ? language("form.paymentDay.last", table: "Debts") : String(day)
    return language.format("form.paymentDay", table: "Debts", shown)
  }

  /// The payment on the card of a debt: «платёж 5 000 ₽, 10-го числа», and at 31 «…, в
  /// последний день месяца» — the day the stepper calls «последний день». `amount` is the
  /// payment as the card writes money.
  static func cardPaymentText(_ amount: String, day: Int?, language: AppLanguage) -> String {
    if let day, day >= 31 {
      return language.format("debts.payment.lastDay", table: "Debts", amount)
    }
    return language.format("debts.payment", table: "Debts", amount, day.map(String.init) ?? "—")
  }

  private func load() {
    guard !loaded else { return }
    loaded = true
    method = methods.first { $0.isDefault }?.id
    switch sheet {
    case .create:
      debt = Debt(direction: .iOwe, type: .loan, name: "", paymentsAreExpenses: true)
    case .pay(let debt):
      amount = debt.monthlyPaymentE4 ?? .zero
      balance = dependencies.flatMap { DebtActions($0).balance(of: debt) }
      closesDebt = Self.closesWhenPaidOff(debt)
      if let ahead = Self.payDate(
        due: payDue, today: environment.today, calendar: environment.calendar)
      {
        date = ahead
      }
    case .transfer(let debt, let carried, _), .adjust(let debt, let carried):
      balance = dependencies.flatMap { DebtActions($0).balance(of: debt) }
      amount = shown(carried)
    case .close(let debt, _):
      balance = dependencies.flatMap { DebtActions($0).balance(of: debt) }
    default:
      break
    }
  }

  private var title: String {
    switch sheet {
    case .create: t("form.create.title")
    case .pay(let debt): environment.format("form.pay.title", table: "Debts", debt.name)
    case .entry(let debt): environment.format("form.entry.title", table: "Debts", debt.name)
    case .offset(let debt): environment.format("form.offset.title", table: "Debts", debt.name)
    case .transfer(let debt, _, _):
      environment.format("form.transfer.title", table: "Debts", debt.name)
    case .adjust(let debt, _): environment.format("form.adjust.title", table: "Debts", debt.name)
    case .close(let debt, _): environment.format("form.close.title", table: "Debts", debt.name)
    }
  }

  private var people: [Person] { (compute.snapshot?.dataset.people ?? []).filter { !$0.archived } }
  private var methods: [PaymentMethod] {
    (compute.snapshot?.dataset.paymentMethods ?? []).filter { !$0.archived }
  }
  private var currencies: [CurrencyCode] { PlanningChoices(compute, environment).currencies }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
