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
  @discardableResult
  func create(_ debt: Debt, balance: AmountE4, on day: DateOnly, moneyMovedNow: Bool) -> Bool {
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
      let opening = try? DebtRules.opening(
        of: debt, balance: balance, date: day, moneyMovedNow: moneyMovedNow)
    {
      rows.debtEntries = [opening]
    }
    return apply(PlanningChange(upsert: rows))
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
  @discardableResult
  func pay(
    _ debt: Debt, amount: AmountE4, on day: Date, paymentMethodId: UUID?, closing: Bool = false
  ) -> Bool {
    guard !debt.closed else { return false }
    var rows = PlanningRows.empty
    let debt = withSubcategory(debt, rows: &rows)
    if !rows.categories.isEmpty { rows.debts = [debt] }
    let loans = debt.loansSubcategoryId ?? snapshot?.ledger.tree.systemCategory(.loans)?.id
    let draft = DebtRules.paymentDraft(
      debt: debt, amount: amount, occurredAt: day, paymentMethodId: paymentMethodId,
      loansCategoryId: loans)
    let date = planning.environment.calendar.day(of: day)
    guard let entry = try? planning.operation(draft, link: nil),
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

  /// «Offset»: I paid something for the creditor and the debt goes down. Money left my
  /// pocket, so it is an operation, counted the way a payment of this debt is.
  @discardableResult
  func offset(_ debt: Debt, amount: AmountE4, on day: Date, description: String?) -> Bool {
    guard !debt.closed else { return false }
    let loans = debt.loansSubcategoryId ?? snapshot?.ledger.tree.systemCategory(.loans)?.id
    var draft = DebtRules.paymentDraft(
      debt: debt, amount: amount, occurredAt: day, paymentMethodId: nil, loansCategoryId: loans)
    draft.note = DebtRules.cleaned(description)
    guard let entry = try? planning.operation(draft, link: nil),
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
  @discardableResult
  func addEntry(
    _ debt: Debt, amount: AmountE4, fullAmount: AmountE4?, share: Decimal?, on day: DateOnly?,
    group: String?, description: String?, moneyMoved: Bool
  ) -> Bool {
    guard !debt.closed else { return false }
    let line: DebtEntry?
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
    guard let line else { return false }
    var rows = PlanningRows.empty
    rows.debtEntries = [line]
    return apply(PlanningChange(upsert: rows))
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
