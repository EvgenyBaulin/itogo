import AppCore
import SwiftUI

/// «Перевод»: money from one account and currency to another — or to another currency of the
/// same account, an exchange. The amount sent, and the amount received when the currencies
/// differ, as the bank shows them, with the rate they imply; an optional fee, written as an
/// expense in «Комиссии» from the account the money left; the day and a comment. Saving is one
/// step of ⌘Z with the fee.
///
/// A transfer dated on the day of a count of a balance it moves, saved after that count, asks
/// whether it happened before it: «Да» puts it just before the count, inside the balance
/// counted; «Нет» after it — or, when the day holds a later count of the other balance, asks
/// about that one too.
struct TransferSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store

  @State private var form: TransferForm
  /// Called once the sheet is done with: whether a transfer was written.
  let finish: (Bool) -> Void

  @State private var books: AccountBooks?
  @State private var refusal: TransferRefusal?
  @State private var failed = false
  @State private var question: CountQuestion?
  @State private var isSaving = false

  /// «Это было до сверки в 14:05?», asked before the transfer is written.
  struct CountQuestion: Identifiable {
    let questions: CountQuestions
    let books: AccountBooks
    var count: Date { questions.count }
    var id: Date { count }
  }

  init(form: TransferForm, finish: @escaping (Bool) -> Void) {
    _form = State(initialValue: form)
    self.finish = finish
  }

  private func t(_ key: String) -> String { environment.language(key, table: AccountText.table) }

  private var transfers: TransferActions { TransferActions(environment: environment, store: store) }

  /// The live accounts in the order of every menu; the ones of the transfer being edited stay
  /// even when they went to the archive since, so the form shows what was written.
  private var accounts: [PaymentMethod] {
    let all =
      books?.dataset.paymentMethods ?? AccountActions(environment: environment, store: store).all
    let kept = Set([form.previous?.fromAccountId, form.previous?.toAccountId].compactMap { $0 })
    return AccountRules.ordered(
      all.filter { !$0.archived || kept.contains($0.id) }, locale: environment.language.locale,
      includeArchived: true)
  }

  private func account(_ id: UUID?) -> PaymentMethod? {
    accounts.first { $0.id == id }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t(form.previous == nil ? "transfer.sheet.title" : "transfer.sheet.editTitle"))
        .font(.headline)
      Form {
        Section {
          accountPicker(
            selection: form.fromAccountId, choose: { form.chooseFrom($0) })
          currencyPicker(
            account: account(form.fromAccountId), selection: $form.fromCurrency)
          amountRow(t("transfer.sheet.sent"), amount: $form.sent, currency: form.fromCurrency)
          if let balance = balanceText(form.fromAccountId, form.fromCurrency) {
            Text(verbatim: balance)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } header: {
          Text(verbatim: t("transfer.sheet.from"))
        }

        Section {
          accountPicker(selection: form.toAccountId, choose: { form.chooseTo($0) })
          currencyPicker(account: account(form.toAccountId), selection: $form.toCurrency)
          if form.isExchange {
            amountRow(
              t("transfer.sheet.received"), amount: $form.received, currency: form.toCurrency)
            Text(verbatim: rateLine ?? t("transfer.sheet.receivedHint"))
              .font(.caption)
              .foregroundStyle(.secondary)
          } else {
            Text(verbatim: t("transfer.sheet.sameAmount"))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } header: {
          Text(verbatim: t("transfer.sheet.to"))
        }

        Section {
          amountRow(t("transfer.sheet.fee"), amount: $form.fee, currency: form.fromCurrency)
          Text(verbatim: t("transfer.sheet.feeHint"))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          DatePicker(selection: dayBinding, displayedComponents: .date) {
            Text(verbatim: t("transfer.sheet.date"))
          }
          TextField(text: $form.note) {
            Text(verbatim: t("transfer.sheet.note"))
          }
        }
      }
      .formStyle(.grouped)

      if let refusal {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "exclamationmark.triangle")
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
          Text(verbatim: TransferText.message(refusal, environment))
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
      }

      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { finish(false) }
          .keyboardShortcut(.cancelAction)
        Button(environment.language("action.save")) { save() }
          .keyboardShortcut(.defaultAction)
          .disabled(isSaving || store.isWritingInBackground)
      }
    }
    .padding(20)
    .frame(width: 460, height: 640)
    .task { books = await transfers.books() }
    .onChange(of: form) { _, _ in refusal = nil }
    .confirmationDialog(
      question.map {
        environment.format(
          "transfer.beforeCount.title", table: AccountText.table,
          environment.dates.time($0.count))
      } ?? "",
      isPresented: Binding(
        get: { question != nil },
        set: {
          // Dismissed without an answer — Esc, a click outside — nothing is written, and the
          // sheet can be saved again.
          if !$0 {
            question = nil
            isSaving = false
          }
        }),
      titleVisibility: .visible, presenting: question
    ) { question in
      Button(t("transfer.beforeCount.yes")) { answer(question, wasBefore: true) }
      Button(t("transfer.beforeCount.no")) { answer(question, wasBefore: false) }
      Button(environment.language("action.cancel"), role: .cancel) { isSaving = false }
    } message: { _ in
      Text(verbatim: t("transfer.beforeCount.message"))
    }
    .refusedWriteAlert($failed, environment)
  }

  // MARK: Fields

  private func accountPicker(
    selection: UUID?, choose: @escaping (PaymentMethod) -> Void
  )
    -> some View
  {
    Picker(
      selection: Binding(
        get: { selection },
        set: { id in if let chosen = account(id) { choose(chosen) } })
    ) {
      if selection == nil {
        Text(verbatim: "—").tag(UUID?.none)
      }
      ForEach(accounts, id: \.id) { account in
        Text(verbatim: account.name).tag(UUID?.some(account.id))
      }
    } label: {
      Text(verbatim: t("transfer.sheet.account"))
    }
  }

  @ViewBuilder
  private func currencyPicker(
    account: PaymentMethod?, selection: Binding<CurrencyCode?>
  )
    -> some View
  {
    // One currency needs no choice; it is named next to the amount.
    if let account, account.currencies.count > 1 {
      Picker(selection: selection) {
        ForEach(account.currencies, id: \.self) { currency in
          Text(verbatim: currency.code).tag(CurrencyCode?.some(currency))
        }
      } label: {
        Text(verbatim: t("transfer.sheet.currency"))
      }
      .pickerStyle(.segmented)
    }
  }

  private func amountRow(
    _ title: String, amount: Binding<AmountE4>, currency: CurrencyCode?
  )
    -> some View
  {
    LabeledContent {
      HStack(spacing: 4) {
        AmountField(amount: amount)
          .frame(maxWidth: 160)
        Text(verbatim: currency.map { environment.money.symbol(for: $0) } ?? "")
          .foregroundStyle(.secondary)
      }
    } label: {
      Text(verbatim: title)
    }
  }

  private var dayBinding: Binding<Date> {
    Binding(
      get: { environment.calendar.noon(of: form.day) },
      set: { form.day = environment.calendar.day(of: $0) })
  }

  /// «Курс обмена: 1 € = 98.5 ₽».
  private var rateLine: String? {
    guard let from = form.fromCurrency, let to = form.toCurrency,
      let rate = TransferText.rate(
        sent: form.sent, from: from, received: form.received, to: to, money: environment.money)
    else { return nil }
    return environment.format("transfer.sheet.rate", table: AccountText.table, rate)
  }

  /// «на счёте: 12,345.67 ₽» — what the key holds now, when it was ever counted.
  private func balanceText(_ accountId: UUID?, _ currency: CurrencyCode?) -> String? {
    guard let accountId, let currency, let books,
      let amount = books.balances[BalanceKey(accountId: accountId, currency: currency)]?.amountE4
    else { return nil }
    return environment.format(
      "transfer.sheet.balance", table: AccountText.table,
      environment.money.exact(amount, currency: currency))
  }

  // MARK: Saving

  private func save() {
    guard !isSaving else { return }
    isSaving = true
    Task {
      guard let books = await transfers.books() else {
        failed = true
        isSaving = false
        return
      }
      self.books = books
      let now = environment.now()
      let calendar = environment.calendar
      let occurredAt = form.occurredAt(now: now, calendar: calendar)
      // What is wrong is said before anything is asked.
      if case .failure(let reason) = transfers.change(
        for: form, occurredAt: occurredAt, books: books)
      {
        refusal = reason
        isSaving = false
        return
      }
      if let transfer = form.transfer(
        id: form.previous?.id ?? UUID(), occurredAt: occurredAt, now: now),
        form.asksAboutTheCount(transfer, calendar: calendar)
      {
        let counts = TransferActions.countMoments(
          for: transfer, savedAt: now, balances: books.balances, calendar: calendar)
        if !counts.isEmpty {
          question = CountQuestion(
            questions: CountQuestions(
              counts: counts, occurredAt: occurredAt, calendar: calendar),
            books: books)
          return
        }
      }
      write(occurredAt: occurredAt, books: books)
    }
  }

  private func answer(_ question: CountQuestion, wasBefore: Bool) {
    switch question.questions.answer(wasBefore: wasBefore) {
    case .stamp(let moment):
      write(occurredAt: moment, books: question.books)
    case .ask(let next):
      // The next count is asked as a dialog of its own, once this one has gone; meanwhile
      // nothing can be saved.
      isSaving = true
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(300))
        self.question = CountQuestion(questions: next, books: question.books)
        self.isSaving = true
      }
    }
  }

  private func write(occurredAt: Date, books: AccountBooks) {
    defer { isSaving = false }
    switch transfers.save(form, occurredAt: occurredAt, books: books) {
    case .done: finish(true)
    case .refused(let reason): refusal = reason
    case .failed: failed = true
    }
  }
}
