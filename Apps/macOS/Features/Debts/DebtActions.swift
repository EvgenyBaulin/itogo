import AppCore
import AppDatabase
import Foundation

/// The actions of the Debts section. Each asks the debt rules of the core what to write and
/// hands it to the store as one `PlanningChange`: the operation of a payment and its journal
/// line, both lines of a transfer, a closing and its write-off — one write and one step of ⌘Z
/// each. A closed debt takes nothing but «Reopen»: a payment, a line, a transfer or a second
/// close would move a balance no list, total or reminder shows any more.
@MainActor
struct DebtActions {
  let planning: PlanningActions
  private var snapshot: DataSnapshot? { planning.snapshot }

  init(_ deps: AppDependencies) {
    planning = PlanningActions(deps)
  }

  /// Through the planning's own write, so a debt made, renamed or closed here is known to
  /// the entry line at once.
  private func apply(_ change: PlanningChange) -> Bool { planning.apply(change) }

  /// A new debt, with its Loans subcategory when its payments are expenses («подкатегория
  /// долга создаётся автоматически») and a first line for what is owed now. Owing less than
  /// nothing («100-300» in the field) is refused, not written as a debt at 0.
  ///
  /// Money that changes hands now is a line of cash on an account — `account` while it is
  /// live, else the main one — at `moment`, with what that account was charged when it does
  /// not hold the debt's currency (`charged` when typed, else the prefill).
  @discardableResult
  func create(
    _ debt: Debt, balance: AmountE4, on day: DateOnly, moneyMovedNow: Bool,
    account: UUID? = nil, charged: Money? = nil, at moment: Date? = nil
  ) -> Bool {
    guard !balance.isNegative else { return false }
    // Named without the spaces around it: the Loans subcategory and the entry line's word
    // take the name as it is saved.
    var debt = debt
    debt.name = debt.name.trimmingCharacters(in: .whitespacesAndNewlines)
    var rows = PlanningRows.empty
    rows.debts = [withSubcategory(debt, rows: &rows)]
    // What is owed when the debt is written down is not money that moves now, unless it is
    // (money lent or borrowed today): a reconciliation must not count an old loan as cash
    // that came in.
    if balance.raw > 0,
      var opening = try? DebtRules.opening(
        of: debt, balance: balance, date: day, moneyMovedNow: moneyMovedNow)
    {
      if moneyMovedNow {
        guard
          (try? layCash(
            on: &opening, of: debt, account: account, charged: charged, at: moment ?? Date()))
            != nil
        else { return false }
      }
      rows.debtEntries = [opening]
    }
    return apply(PlanningChange(upsert: rows))
  }

  /// A line of money borrowed or lent through the journal alone names the account it moved on
  /// — `account` while live, else the main one — its moment, and what that account was charged
  /// when it does not hold the debt's currency: `charged` when typed in that currency, else the
  /// prefill from the bank's rates of its day. Throws `FormChargeError.chargeMissing` when no
  /// rate gives the figure.
  func layCash(
    on line: inout DebtEntry, of debt: Debt, account chosen: UUID?, charged: Money?,
    at moment: Date
  ) throws {
    let environment = planning.environment
    let accounts =
      (try? environment.references?.paymentMethods(includeArchived: true))
      ?? snapshot?.dataset.paymentMethods ?? []
    let account = FormAccounts.account(chosen, among: accounts)
    line.paymentMethodId = account?.id ?? chosen
    line.occurredAt = moment
    line.date = environment.calendar.day(of: moment)
    line.accountCurrency = nil
    line.accountAmountE4 = nil
    guard let account, let leg = AccountRules.legCurrency(for: debt.currency, account: account)
    else { return }
    if let charged, charged.currency == leg, charged.amount.raw > 0 {
      line.accountCurrency = leg
      line.accountAmountE4 = charged.amount
      return
    }
    let table = (try? environment.rates?.table()) ?? RateTable()
    guard
      let figure = FormAccounts.charge(
        amount: line.amountE4.magnitude, currency: debt.currency, at: moment, rate: nil,
        account: account, table: table, calendar: environment.calendar)?.amount
    else { throw FormChargeError.chargeMissing }
    line.accountCurrency = leg
    line.accountAmountE4 = figure
  }

  @discardableResult
  func save(_ debt: Debt) -> Bool {
    var rows = PlanningRows.empty
    rows.debts = [withSubcategory(debt, rows: &rows)]
    return apply(PlanningChange(upsert: rows))
  }

  /// «Reopen»: a closed debt back in its list, as it was — a write-off made at the close stays
  /// in the journal, where «Adjust» can take it back. One write, one ⌘Z.
  @discardableResult
  func reopen(_ debt: Debt) -> Bool {
    guard debt.closed else { return false }
    var reopened = debt
    reopened.closed = false
    return save(reopened)
  }

  /// What is left on a debt now: the sum of its journal as the database has it at the moment
  /// of asking, not the figure the card was drawn with — the entry line or another window may
  /// have written since. `nil` when there is no database to read.
  func balance(of debt: Debt) -> AmountE4? {
    guard let references = planning.environment.references,
      let journal = try? references.debtEntries(debtId: debt.id)
    else { return nil }
    return DebtRules.balance(entries: journal)
  }

  /// Whether a payment of `amount` pays off what is left, and «Pay» offers to close the debt.
  static func paysOff(_ amount: AmountE4, balance: AmountE4) -> Bool {
    amount.raw > 0 && amount >= balance
  }

  /// A subcategory once, never twice: a debt that has one keeps it even while the data on
  /// screen has not caught up with the write that made it.
  private func withSubcategory(_ debt: Debt, rows: inout PlanningRows) -> Debt {
    var debt = debt
    if debt.loansSubcategoryId == nil {
      debt.loansSubcategoryId =
        (try? planning.environment.references?.debts(includeClosed: true))?
        .first { $0.id == debt.id }?.loansSubcategoryId
    }
    guard debt.loansSubcategoryId == nil, let tree = snapshot?.ledger.tree,
      let made = SystemSubcategories.loanSubcategory(for: debt, tree: tree)
    else { return debt }
    debt.loansSubcategoryId = made.id
    rows.categories.append(made)
    return debt
  }

  /// «Pay»: an operation with the debt — an expense in Loans when the debt's payments are
  /// expenses, otherwise one that only lowers the debt; money a person returns on a debt owed
  /// to me is a reimbursement — and the journal line that lowers the balance.
  ///
  /// With `closing`, a payment that pays off what the journal has left at this moment closes
  /// the debt in the same write and the same ⌘Z, and what it paid over is written off: the
  /// closed debt owes nothing, like one closed by «Close». A payment that no longer
  /// covers the balance — a line landed since the form opened — is written alone, and the rest
  /// stays owed where it can be seen.
  ///
  /// The operation is on `paymentMethodId` while that account is live, else on the main one,
  /// with what the account was charged when it does not hold the debt's currency: `charged`
  /// when typed from the statement, else the prefill at the rate of the operation.
  @discardableResult
  func pay(
    _ debt: Debt, amount: AmountE4, on day: Date, paymentMethodId: UUID?, closing: Bool = false,
    charged: Money? = nil
  ) -> Bool {
    guard !debt.closed else { return false }
    var rows = PlanningRows.empty
    let debt = withSubcategory(debt, rows: &rows)
    if !rows.categories.isEmpty { rows.debts = [debt] }
    let date = planning.environment.calendar.day(of: day)
    guard
      let entry = try? paymentOperation(
        debt, amount: amount, on: day, account: paymentMethodId, charged: charged),
      let outcome = try? DebtRules.payment(
        on: debt, amountE4: amount, date: date, transactionId: entry.id)
    else { return false }
    rows.debtEntries = [outcome.entry]
    if closing, let left = balance(of: debt), Self.paysOff(amount, balance: left) {
      let closed = DebtRules.closing(
        debt, balance: left + outcome.entry.amountE4, writeOffRemainder: true, date: date)
      rows.debts = [closed.debt]
      if let writeOff = closed.entry { rows.debtEntries.append(writeOff) }
    }
    return apply(PlanningChange(created: [entry], upsert: rows))
  }

  /// The operation a payment of `debt` writes — «Pay», or «Offset» with its note — on
  /// `account` while it is live, else on the main one, with «Списано со счёта» when that
  /// account does not hold the debt's currency. The forms ask «Это было до сверки?» about it
  /// before the write.
  func paymentOperation(
    _ debt: Debt, amount: AmountE4, on day: Date, account: UUID?, charged: Money?,
    note: String? = nil
  ) throws -> TransactionEntry {
    let loans = debt.loansSubcategoryId ?? snapshot?.ledger.tree.systemCategory(.loans)?.id
    var draft = DebtRules.paymentDraft(
      debt: debt, amount: amount, occurredAt: day, paymentMethodId: account,
      loansCategoryId: loans)
    draft.note = note
    try FormAccounts.lay(on: &draft, account: account, charged: charged, actions: planning)
    return try planning.operation(draft, link: nil)
  }

  /// «Offset»: I paid something for the creditor and the debt goes down. Money left my
  /// pocket, so it is an operation, counted the way a payment of this debt is — on `account`
  /// while it is live, else on the main one.
  @discardableResult
  func offset(
    _ debt: Debt, amount: AmountE4, on day: Date, description: String?, account: UUID? = nil,
    charged: Money? = nil
  ) -> Bool {
    guard !debt.closed else { return false }
    guard
      let entry = try? paymentOperation(
        debt, amount: amount, on: day, account: account, charged: charged,
        note: DebtRules.cleaned(description)),
      let line = try? DebtRules.offset(
        on: debt, amountE4: amount, date: planning.environment.calendar.day(of: day),
        transactionId: entry.id, description: description)
    else { return false }
    var rows = PlanningRows.empty
    rows.debtEntries = [line]
    return apply(PlanningChange(created: [entry], upsert: rows))
  }

  /// «Add entry»: borrowed, or the debt grew — an amount, or a share of a full amount
  /// («полная сумма 1 000 000, доля 1/2»).
  ///
  /// Money that moved is a line of cash on `account` — while live, else the main one — at
  /// `moment` (noon of `day` when none is given), with «Списано со счёта» when that account
  /// does not hold the debt's currency.
  @discardableResult
  func addEntry(
    _ debt: Debt, amount: AmountE4, fullAmount: AmountE4?, share: Decimal?, on day: DateOnly?,
    group: String?, description: String?, moneyMoved: Bool, account: UUID? = nil,
    charged: Money? = nil, at moment: Date? = nil
  ) -> Bool {
    guard !debt.closed else { return false }
    var line: DebtEntry?
    if moneyMoved {
      // Borrowed: money came in (or went out, on a debt owed to me) — a real movement.
      if let fullAmount, let share {
        line = try? DebtRules.makeShareEntry(
          debtId: debt.id, fullAmountE4: fullAmount, share: share, date: day, groupName: group,
          description: description)
      } else {
        line =
          amount.raw > 0
          ? DebtRules.makeEntry(
            debtId: debt.id, kind: .borrowed, amountE4: amount, date: day, groupName: group,
            description: description) : nil
      }
    } else {
      // The debt grew without money moving — interest, a fine, a share of a common bill.
      line = try? DebtRules.growth(
        on: debt, amountE4: amount, fullAmountE4: fullAmount, share: share, date: day,
        groupName: group, description: description)
    }
    guard var line else { return false }
    if moneyMoved {
      let calendar = planning.environment.calendar
      let when =
        moment ?? day.map { calendar.startOfDay($0).addingTimeInterval(12 * 3600) } ?? Date()
      guard
        (try? layCash(on: &line, of: debt, account: account, charged: charged, at: when)) != nil
      else { return false }
    }
    var rows = PlanningRows.empty
    rows.debtEntries = [line]
    return apply(PlanningChange(upsert: rows))
  }

  /// The open «Мне должны» debt a money back is offered to repay: the person owes no part but
  /// owes on it (`MoneyBackRefusal.owesOnDebt`). `nil` for any other refusal or a debt that is
  /// closed, gone or owed the other way.
  static func repaid(by refusal: MoneyBackRefusal, among debts: [Debt]) -> Debt? {
    guard case .owesOnDebt(let id) = refusal,
      let debt = debts.first(where: { $0.id == id }),
      !debt.closed, debt.direction == .owedToMe
    else { return nil }
    return debt
  }

  /// The payment form a money back opens as a repayment of `debt`: the amount given back when
  /// it is in the debt's currency (otherwise typed in the form), on the account it came to.
  static func repaymentSheet(of debt: Debt, money: Money, account: UUID?) -> DebtSheet {
    .repay(debt, amount: money.currency == debt.currency ? money.amount : nil, account: account)
  }

  /// What a money back that repays `debt` needs from the entry line: nothing when it is in the
  /// debt's currency — the line saves it with the debt, and asks what the line asks — or, in
  /// another currency, which the line cannot write on the debt (5 $ back on a ruble debt), the
  /// payment form of the debt on the account the money came to, the amount typed there in the
  /// debt's currency.
  static func repaymentSheetIfNeeded(of debt: Debt, money: Money, account: UUID?) -> DebtSheet? {
    money.currency == debt.currency
      ? nil : repaymentSheet(of: debt, money: money, account: account)
  }

  /// «Transfer»: a third party paid one debt off and the sum moved into another — the first
  /// closes when all of it moved, the second gets a line. «All of it» is what the journal of
  /// the first has left when the transfer is written; `balance`, the figure the card showed,
  /// stands in only without a database to read.
  @discardableResult
  func transfer(
    _ source: Debt, balance: AmountE4, to destination: Debt, amount: AmountE4, on day: DateOnly
  )
    -> Bool
  {
    guard !source.closed, !destination.closed,
      let moved = try? DebtRules.transfer(
        from: source, to: destination, amountE4: amount,
        sourceBalanceE4: self.balance(of: source) ?? balance, date: day)
    else { return false }
    var rows = PlanningRows.empty
    rows.debtEntries = [moved.out, moved.into]
    if moved.closesSource {
      var closed = source
      closed.closed = true
      rows.debts = [closed]
    }
    return apply(PlanningChange(upsert: rows))
  }

  /// «Adjust»: the balance set to what it really is, by a signed line — the difference from
  /// what the journal has when it is written, so the balance comes to the figure typed even
  /// when a payment landed after the form opened. `balance`, the figure the form showed,
  /// stands in only without a database to read.
  @discardableResult
  func adjust(
    _ debt: Debt, from balance: AmountE4, to newBalance: AmountE4, on day: DateOnly, note: String?
  )
    -> Bool
  {
    guard !debt.closed,
      let line = try? DebtRules.adjustment(
        on: debt, from: self.balance(of: debt) ?? balance, to: newBalance, date: day, note: note)
    else { return false }
    var rows = PlanningRows.empty
    rows.debtEntries = [line]
    return apply(PlanningChange(upsert: rows))
  }

  /// «Close»: the debt leaves the lists; what is left of it — in the journal when it is
  /// written, not in the figure the card showed — is written off when asked, so the closed
  /// debt owes nothing. `balance` stands in only without a database to read.
  @discardableResult
  func close(_ debt: Debt, balance: AmountE4, writeOff: Bool, on day: DateOnly) -> Bool {
    guard !debt.closed else { return false }
    let closing = DebtRules.closing(
      debt, balance: self.balance(of: debt) ?? balance, writeOffRemainder: writeOff, date: day)
    var rows = PlanningRows.empty
    rows.debts = [closing.debt]
    if let line = closing.entry { rows.debtEntries = [line] }
    return apply(PlanningChange(upsert: rows))
  }
}
