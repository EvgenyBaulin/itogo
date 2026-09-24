import AppCore
import AppDatabase
import Foundation
import Synchronization

/// Where the steps get their data: the two things that touch the outside world, as
/// closures, so the store runs the same way on the database and on a test's fakes.
struct ComputeSources: Sendable {
  /// Reads the whole history, stamped with `mark` — the count of writes taken right before
  /// the read — and builds the snapshot for `today` and the moment `now`, both of the store's
  /// clock: the planning of the snapshot is built for that moment, not for the wall clock.
  var loadData: @Sendable (_ mark: Int, _ today: DateOnly, _ now: Date) async throws -> DataSnapshot
  /// Refines provisional rates (step 1).
  var refineRates: @Sendable () async throws -> RefinementResult
  /// Trains the category model and publishes it (step 4). A test that does not care about
  /// the model leaves it out.
  var models: CategoryModelService?

  /// The app's sources: the database of `stack` and the rate service.
  static func live(
    stack: DatabaseStack, rateService: RateService, calendar: CalendarContext,
    models: CategoryModelService? = nil
  ) -> ComputeSources {
    let datasets = DatasetRepository(writer: stack.writer)
    let settings = SettingsRepository(writer: stack.writer)
    let rates = RateRepository(writer: stack.writer)
    return ComputeSources(
      loadData: { mark, today, now in
        let dataset = try await datasets.load(version: mark)
        let context = SnapshotContext(
          dataset: dataset, rates: RateTable(rates: try rates.allRates()), today: today,
          also: enabledCurrencies(settings))
        try Task.checkCancellation()
        return DataSnapshot.build(
          dataset: dataset, calendar: calendar, today: today, context: context,
          version: DataVersion(load: mark), now: now)
      },
      refineRates: { try await rateService.refine() }, models: models)
  }

  /// The currencies enabled in the settings, whose rates the reconciliation asks for. A read
  /// that fails leaves them out — the operations still load and every card still counts —
  /// and says so in the journal: the reconciliation then lacks their rates, and a problem
  /// report has to say why.
  private static func enabledCurrencies(_ settings: SettingsRepository) -> [CurrencyCode] {
    do {
      return try settings.enabledCurrencies()
    } catch {
      AppLog.warning(
        "settings.read.failed", .compute, "the enabled currencies could not be read",
        [
          LogPair("setting", .token("enabledCurrencies")), LogPair("error", .error(error)),
          LogPair("code", .count((error as NSError).code)),
        ])
      return []
    }
  }

  /// The graph of the steps, the same as `ComputeStep.dependencies`. Every step first honours
  /// the faults of the Debug menu.
  ///
  /// The forecast waits for the data step, but counts on the freshest ledger the store has:
  /// rerun at midnight inside a run that started days ago, it would otherwise miss every
  /// operation entered since.
  func steps(
    faults: FaultSwitch, counter: WriteCounter, latest: LatestSnapshot,
    today: @escaping @Sendable () -> DateOnly, now: @escaping @Sendable () -> Date
  ) -> [PipelineStep] {
    let sources = self
    var steps = [
      PipelineStep(ComputeStep.rates) { _ in
        try await faults.hold(ComputeStep.rates)
        return try await sources.refineRates()
      },
      PipelineStep(ComputeStep.data) { _ in
        try await faults.hold(ComputeStep.data)
        // Taken before the read: a write that lands during it is laid over it again.
        return try await sources.loadData(counter.value, today(), now())
      },
      PipelineStep(ComputeStep.owed, dependsOn: [ComputeStep.data]) { inputs in
        try await faults.hold(ComputeStep.owed)
        let snapshot = try inputs.value(of: ComputeStep.data, as: DataSnapshot.self)
        return OwedResult(summary: OwedSummary(snapshot.summary), version: snapshot.version)
      },
      PipelineStep(ComputeStep.forecast, dependsOn: [ComputeStep.data]) { inputs in
        try await faults.hold(ComputeStep.forecast)
        let snapshot = try inputs.value(of: ComputeStep.data, as: DataSnapshot.self)
        let ledger = latest.newest(than: snapshot).ledger
        try Task.checkCancellation()
        return MonthForecast.remainder(ledger: ledger, today: today())
      },
      // Step 4: the category model. It trains on the freshest ledger the store has, and
      // only when what it would learn from has changed.
      PipelineStep(ComputeStep.model, dependsOn: [ComputeStep.data]) { inputs in
        try await faults.hold(ComputeStep.model)
        guard let models = sources.models else {
          return CategoryModelService.Result(
            readiness: .tooFewExamples(have: 0, needed: 50), summary: nil, retrained: false)
        }
        let snapshot = try inputs.value(of: ComputeStep.data, as: DataSnapshot.self)
        let newest = latest.newest(than: snapshot)
        try Task.checkCancellation()
        let examples = LedgerTraining.examples(
          of: newest.ledger.dataset, calendar: newest.ledger.calendar)
        try Task.checkCancellation()
        return models.refresh(examples: examples, anchor: today())
      },
      // Step 6: the seven rules of «Аномалии». Like the forecast they read the freshest
      // ledger the store has, and the events come from the planning the data step already
      // built, so this screen and Planning cannot disagree about a budget.
      PipelineStep(ComputeStep.anomalies, dependsOn: [ComputeStep.data]) { inputs in
        try await faults.hold(ComputeStep.anomalies)
        let snapshot = try inputs.value(of: ComputeStep.data, as: DataSnapshot.self)
        let newest = latest.newest(than: snapshot)
        try Task.checkCancellation()
        return AnomalyRules.build(
          ledger: newest.ledger, events: newest.planning.events, today: today(),
          dismissals: newest.ledger.dataset.dismissals,
          options: .standard(newest.ledger.dataset.settings.anomalySensitivity))
      },
      // Step 7: the suggestions of the month, on the freshest data the store has, like the
      // forecast they need.
      PipelineStep(ComputeStep.advice, dependsOn: [ComputeStep.data, ComputeStep.forecast]) {
        inputs in
        try await faults.hold(ComputeStep.advice)
        let snapshot = try inputs.value(of: ComputeStep.data, as: DataSnapshot.self)
        let remainder = try inputs.value(
          of: ComputeStep.forecast, as: MonthForecast.Remainder.self)
        let newest = latest.newest(than: snapshot)
        try Task.checkCancellation()
        return AdviceBook.build(
          planning: newest.planning, ledger: newest.ledger, remainder: remainder,
          today: today())
      },
      // Step 8: payments, trials, prices, debts and the reconciliation to remind of.
      PipelineStep(ComputeStep.reminders, dependsOn: [ComputeStep.data]) { inputs in
        try await faults.hold(ComputeStep.reminders)
        let snapshot = try inputs.value(of: ComputeStep.data, as: DataSnapshot.self)
        return latest.newest(than: snapshot).planning.reminders
      },
    ]
    for step in ComputeStep.all where ComputeStep.stubs[step] != nil {
      steps.append(
        PipelineStep(step) { _ in
          try await faults.hold(step)
          return PlaceholderResult()
        })
    }
    return steps
  }
}

/// What a placeholder step returns: nothing yet.
struct PlaceholderResult: Sendable {}

/// The count of writes, read by steps off the main thread. It grows with every
/// write of the app and with every change the database observation reports, and every read
/// is stamped with its value taken before the read began.
final class WriteCounter: Sendable {
  private let storage = Mutex(0)

  var value: Int { storage.withLock { $0 } }

  /// Counts one more write and returns its number.
  @discardableResult
  func increment() -> Int {
    storage.withLock { value in
      value += 1
      return value
    }
  }
}

/// The faults of the Debug menu, where the steps can read them.
final class FaultSwitch: Sendable {
  private let storage = Mutex(PipelineFaults())

  var faults: PipelineFaults {
    get { storage.withLock { $0 } }
    set { storage.withLock { $0 = newValue } }
  }

  /// Slows the step down or fails it, as the Debug menu asks. Cancellable, like the step.
  func hold(_ step: StepID) async throws {
    let faults = self.faults
    if faults.slowsDown {
      try await Task.sleep(for: PipelineFaults.delay)
    }
    if faults.failing.contains(step) {
      throw InjectedFault(step: step)
    }
  }
}

/// The snapshot the store shows, where a step can read it.
final class LatestSnapshot: Sendable {
  private let storage = Mutex<DataSnapshot?>(nil)

  func set(_ snapshot: DataSnapshot?) {
    storage.withLock { $0 = snapshot }
  }

  /// The newer of `snapshot` and the one the store shows.
  func newest(than snapshot: DataSnapshot) -> DataSnapshot {
    storage.withLock { shown in
      guard let shown, shown.version > snapshot.version else { return snapshot }
      return shown
    }
  }
}
