import AppCore
import SwiftUI

/// «Сверка»: how much money I have in total — one sum in rubles or by currency at today's
/// rate of the bank — against what the books expect, with every term of the formula shown,
/// and the difference written to «Сверка» in one step of ⌘Z. The first reconciliation is the
/// starting point.
///
/// What was counted is the truth; the difference is how the books catch up with it, dated the
/// day of the reconciliation, because nothing says when the money really moved. It goes to a
/// category of its own rather than into «Не помню», where it would be mixed with purchases
/// the owner simply could not place.
struct ReconcileSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  @Environment(\.dependencies) private var dependencies
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openWindow) private var openWindow

  @State private var byCurrency = false
  @State private var total: AmountE4 = .zero
  @State private var amounts: [CurrencyCode: AmountE4] = [:]
  @State private var now = Date()
  @State private var showsHistory = false
  /// The key of why the last press saved nothing, until the next one: the sheet is never left
  /// open without a word.
  @State private var failure: String?

  var body: some View {
    let snapshot = compute.snapshot
    let expectation = snapshot.flatMap {
      ReconciliationRules.expectation(
        ledger: $0.ledger, book: $0.dataset.planning, now: now, calendar: environment.calendar,
        rubPerUnit: $0.context.rubPerUnit)
    }
    let actual = actualTotal(snapshot)
    VStack(alignment: .leading, spacing: 12) {
      Text(verbatim: t("reconcile.title")).font(.headline)
      Text(verbatim: t("reconcile.question")).foregroundStyle(.secondary)
      Picker(selection: $byCurrency) {
        Text(verbatim: t("reconcile.oneSum")).tag(false)
        Text(verbatim: t("reconcile.byCurrency")).tag(true)
      } label: {
        EmptyView()
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      if byCurrency {
        currencyRows(snapshot)
      } else {
        HStack {
          AmountField(amount: $total, locale: environment.language.locale)
            .frame(width: 200)
          Text(verbatim: "₽").foregroundStyle(.secondary)
        }
      }
      Divider()
      if let expectation {
        ScrollView {
          VStack(alignment: .leading, spacing: 6) {
            Text(
              verbatim: environment.format(
                "reconcile.previous", table: "Planning",
                environment.dates.longDay(expectation.previous.date))
            )
            .font(.caption.weight(.semibold))
            FormulaLines(
              lines: expectation.lines.map {
                (key: $0.term.key, plus: $0.sign == .plus, amount: $0.amount)
              },
              exact: true)
            if expectation.undatedJournalLines > 0 || expectation.journalLinesWithoutRate > 0
              || expectation.journalLinesOnPreviousDay > 0
            {
              Text(verbatim: t("reconcile.journalLeftOut"))
                .font(.caption).foregroundStyle(.tertiary)
            }
            Divider()
            figure(t("reconcile.expected"), expectation.expected)
            if let actual {
              figure(t("reconcile.difference"), actual - expectation.expected, signed: true)
            }
          }
        }
        .frame(maxHeight: 300)
      } else if snapshot == nil {
        // Without the data a reconciliation cannot tell the first from the next: nothing
        // is saved until it is here (review of the app, 19.09).
        ComputedBlock(
          title: nil, state: compute.states.data, style: .plain,
          retry: { compute.retry(ComputeStep.data) }
        ) { _ in EmptyView() }
      } else {
        Label {
          Text(verbatim: t("reconcile.first"))
        } icon: {
          Image(systemName: "flag")
        }
        .foregroundStyle(.secondary)
      }
      DisclosureGroup(isExpanded: $showsHistory) {
        history(snapshot)
      } label: {
        Text(verbatim: t("reconcile.history"))
      }
      if let failure {
        Text(verbatim: t(failure))
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        if let expectation {
          Button(t("reconcile.findMissing")) {
            environment.pendingTransactionsRange = DayRange(
              expectation.previous.date, environment.today)
            openWindow(id: "transactions")
          }
        }
        Spacer()
        Button(environment.language("action.cancel")) { dismiss() }
          .keyboardShortcut(.cancelAction)
        if let expectation {
          Button(t("reconcile.saveOnly")) {
            save(actual, breakdown(snapshot), expectation, record: false)
          }
          .disabled(actual == nil)
          Button(t("reconcile.record")) {
            save(actual, breakdown(snapshot), expectation, record: true)
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .disabled(actual == nil || actual == expectation.expected)
          .help(t("reconcile.recordHint"))
        } else {
          Button(t("reconcile.saveStart")) { save(actual, breakdown(snapshot), nil, record: false) }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(actual == nil || snapshot == nil)
        }
      }
    }
    .padding(20)
    .frame(width: 560)
    .onAppear { now = Date() }
    // The expectation is counted for `now`, and the reconciliation is stamped with it
    // (`PlanningActions.reconcile`). An operation entered while the sheet stands open — the
    // coffee «Найти пропущенные…» went looking for — comes with new data, and the moment moves
    // with it, so the expectation on screen takes it in and the difference is what is left.
    .onChange(of: compute.generation) { _, _ in now = Date() }
  }

  // MARK: Input

  @ViewBuilder
  private func currencyRows(_ snapshot: DataSnapshot?) -> some View {
    let currencies = PlanningChoices(compute, environment).currencies
    VStack(alignment: .leading, spacing: 4) {
      ForEach(currencies, id: \.self) { currency in
        HStack {
          Text(verbatim: currency.code).frame(width: 44, alignment: .leading)
          AmountField(
            amount: Binding(get: { amounts[currency] ?? .zero }, set: { amounts[currency] = $0 }),
            locale: environment.language.locale
          )
          .frame(width: 160)
          if currency != .rub {
            if let rate = snapshot?.context.rubPerUnit[currency] {
              // The latest rate of the bank, as the language writes numbers, and the rubles.
              let rubles =
                (try? AmountE4(decimal: (amounts[currency] ?? .zero).decimal * rate)) ?? .zero
              let rateText = rate.formatted(
                .number.locale(environment.language.locale).precision(.fractionLength(0...4)))
              let day = snapshot?.context.rateDays[currency].map { environment.dates.longDay($0) }
              Text(
                verbatim: "× \(rateText) ₽ = \(environment.money.exact(rubles))"
                  + (day.map {
                    " · " + environment.format("reconcile.rateOf", table: "Planning", $0)
                  }
                    ?? "")
              )
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
            } else {
              Text(verbatim: t("reconcile.noRate")).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
    }
  }

  private static func typed(_ amounts: [CurrencyCode: AmountE4]) -> [Money] {
    amounts.filter { !$0.value.isZero }.sorted { $0.key.code < $1.key.code }
      .map { Money(amount: $0.value, currency: $0.key) }
  }

  private func breakdown(_ snapshot: DataSnapshot?) -> [ReconciliationAmount] {
    guard byCurrency else { return [] }
    return
      (try? ReconciliationRules.breakdown(
        Self.typed(amounts), rubPerUnit: snapshot?.context.rubPerUnit ?? [:]))
      ?? []
  }

  /// The total in rubles, or nothing while it cannot be saved.
  private func actualTotal(_ snapshot: DataSnapshot?) -> AmountE4? {
    Self.counted(
      byCurrency: byCurrency, total: total, amounts: amounts,
      rubPerUnit: snapshot?.context.rubPerUnit ?? [:])
  }

  /// The counted total in rubles, or nothing while it cannot be saved: nothing typed yet, an
  /// amount below zero, or a currency typed without a rate.
  ///
  /// An empty field reads as zero, and Return presses «Записать разницу»: without this an
  /// untouched sheet would write the whole expected balance off as an expense. The field also
  /// evaluates «−100», and money on hand is never below zero.
  static func counted(
    byCurrency: Bool, total: AmountE4, amounts: [CurrencyCode: AmountE4],
    rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    guard byCurrency else { return total > .zero ? total : nil }
    let typed = typed(amounts)
    guard
      !typed.contains(where: { $0.amount.isNegative }),
      let converted = try? ReconciliationRules.breakdown(typed, rubPerUnit: rubPerUnit)
    else { return nil }
    let counted = ReconciliationRules.actualTotal(converted)
    return counted > .zero ? counted : nil
  }

  private func figure(_ label: String, _ amount: AmountE4, signed: Bool = false) -> some View {
    HStack {
      Text(verbatim: label)
      Spacer()
      Text(
        verbatim: signed ? signedExact(amount) : environment.money.exact(amount)
      )
      .monospacedDigit()
    }
    .font(.callout.weight(.semibold))
  }

  /// «−5 550,49 ₽»: a reconciliation shows kopecks, the operation it writes has them too.
  private func signedExact(_ amount: AmountE4) -> String {
    (amount.isNegative ? "−" : amount.isZero ? "" : "+") + environment.money.exact(amount.magnitude)
  }

  private func history(_ snapshot: DataSnapshot?) -> some View {
    let all = (snapshot?.dataset.planning.reconciliations ?? []).reversed()
    return VStack(alignment: .leading, spacing: 3) {
      if all.isEmpty { Text(verbatim: t("reconcile.historyNone")).foregroundStyle(.secondary) }
      ForEach(Array(all), id: \.id) { item in
        HStack {
          Text(verbatim: environment.dates.longDay(item.date))
          Spacer()
          Text(verbatim: environment.money.exact(item.actualTotalRubE4)).monospacedDigit()
          Text(verbatim: item.expectedTotalRubE4.map { environment.money.exact($0) } ?? "—")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(minWidth: 110, alignment: .trailing)
          if let difference = item.differenceE4 {
            Text(verbatim: signedExact(difference))
              .monospacedDigit()
              .foregroundStyle(.secondary)
              .frame(minWidth: 90, alignment: .trailing)
          }
        }
        .font(.caption)
      }
    }
  }

  private func save(
    _ actual: AmountE4?, _ breakdown: [ReconciliationAmount],
    _ expectation: ReconciliationExpectation?, record: Bool
  ) {
    guard let actual, let dependencies else { return }
    if let failure = Self.save(
      actual: actual, breakdown: breakdown, expectation: expectation, record: record,
      dependencies: dependencies)
    {
      self.failure = failure
      return
    }
    environment.showsReconciliation = false
    dismiss()
  }

  /// Writes the reconciliation: nil when it landed, or the key of what the sheet says when it
  /// did not. A refused save keeps the sheet open with the money counted in it — and says so,
  /// rather than leave a button that seems to do nothing (the journal has `reconcile.failed`).
  static func save(
    actual: AmountE4, breakdown: [ReconciliationAmount],
    expectation: ReconciliationExpectation?, record: Bool, dependencies: AppDependencies
  ) -> String? {
    // A difference that could not be written says so apart: the owner can then save the
    // reconciliation without recording it.
    PlanningActions(dependencies).reconcile(
      actual: actual, breakdown: breakdown, expectation: expectation, recordDifference: record)
      ? nil : (record ? "reconcile.notRecorded" : "reconcile.notSaved")
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Planning") }
}
