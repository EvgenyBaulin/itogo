import AppCore
import Foundation

/// «Такая же операция уже записана»: asked before a new operation that repeats one written a
/// moment ago is written again. «Добавить» writes it, «Не добавлять» leaves the line as it was.
struct RepeatQuestion: Identifiable {
  let entry: TransactionEntry
  var id: UUID { entry.id }

  /// The amount, what it was called, and when it was written.
  @MainActor func message(_ environment: AppEnvironment) -> String {
    let written = entry.transaction
    let money = environment.money.exact(written.amountE4, currency: written.currency)
    let note = written.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return environment.language.format(
      "entry.repeat.message", table: "Entry", note.isEmpty ? money : "\(money) · \(note)",
      environment.dates.time(written.createdAt))
  }
}

/// «Запись или план?»: asked once before an operation dated after today is written. «Записать
/// как есть» writes it on its date, the other button makes a plan of it instead (`OperationAhead`).
struct AheadQuestion: Identifiable {
  let plan: OperationAhead.Plan
  let day: DateOnly
  var id: String { "\(plan)-\(day.iso)" }

  @MainActor func title(_ environment: AppEnvironment) -> String {
    environment.language.format("entry.ahead.title", table: "Entry", environment.dates.longDay(day))
  }

  /// The key of the button that makes the plan.
  var planKey: String {
    plan == .payment ? "entry.ahead.planPayment" : "entry.ahead.planIncome"
  }
}

/// The sheet of a transfer that «Перевести…» of the panel opens: the form it starts with.
struct TransferRequest: Identifiable {
  let id = UUID()
  let form: TransferForm
  /// The sheet saves as soon as it opens: the line named everything a transfer needs.
  var saveAtOnce = false
  /// Started by «перевод …» typed in the line, not by «Перевести…».
  var fromTheLine = false
}
