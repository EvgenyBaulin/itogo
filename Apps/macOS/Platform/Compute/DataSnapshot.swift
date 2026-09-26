import AppCore
import Foundation

/// Which writes a snapshot has seen. `load` is the count of writes taken right before the
/// database was read (`WriteCounter`); `overlay` is the last write of the app laid over that
/// read in memory, or `load` when none was.
struct DataVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
  var load: Int
  var overlay: Int

  init(load: Int, overlay: Int? = nil) {
    self.load = load
    self.overlay = overlay ?? load
  }

  static func < (lhs: DataVersion, rhs: DataVersion) -> Bool {
    (lhs.load, lhs.overlay) < (rhs.load, rhs.overlay)
  }

  var description: String { "load \(load), overlay \(overlay)" }
}

/// What a snapshot needs besides the operations and the dictionaries, read with them and
/// carried over when the app lays its own writes over a snapshot.
struct SnapshotContext: Hashable, Sendable {
  /// The day of the last reconciliation.
  var lastReconciliation: DateOnly?
  /// The last known rate of every currency planning counts in — debts, scheduled payments
  /// and what others give back for them, expected income, the enabled currencies of a
  /// reconciliation, goals, accounts and transfers — so planned payments, funding, balances
  /// and totals convert without a guess. Rubles for one unit: 100 tenge are quoted, one is
  /// kept.
  var rubPerUnit: [CurrencyCode: Decimal] = [:]
  /// The day of each of those rates: on a weekend or offline it is not today, and the
  /// reconciliation says so.
  var rateDays: [CurrencyCode: DateOnly] = [:]
  /// Every rate the table holds of the enabled currencies and those of the goals and the
  /// accounts, by day, in rubles for one unit: what a contribution to a goal in another
  /// currency counts at on its own day.
  var dayRates: DayRates = .empty
  /// The language the names of the accounts are ordered in (`AccountsSnapshot`).
  var localeIdentifier = "en"

  /// Rates of those currencies as the table gives them for `today`.
  init(
    dataset: Dataset, rates: RateTable, today: DateOnly, also extra: [CurrencyCode] = [],
    localeIdentifier: String = "en"
  ) {
    self.lastReconciliation = dataset.planning.reconciliations.last?.date
    self.localeIdentifier = localeIdentifier
    var currencies = Set(dataset.debts.map(\.currency))
    for payment in dataset.planning.scheduled {
      currencies.insert(payment.currency)
      if let back = payment.reimbursementCurrency { currencies.insert(back) }
    }
    currencies.formUnion(dataset.planning.expected.map(\.currency))
    currencies.formUnion(dataset.transfers.flatMap { [$0.fromCurrency, $0.toCurrency] })
    // By day: what the goals count their contributions at, and what a leg is prefilled with.
    var byDay = Set(extra)
    byDay.formUnion(dataset.goals.map(\.currency))
    byDay.formUnion(dataset.paymentMethods.flatMap(\.currencies))
    byDay.remove(.rub)
    currencies.formUnion(byDay)
    for currency in currencies where currency != .rub {
      if let rate = rates.rate(for: currency, on: today) {
        rubPerUnit[currency] = rate.perUnit
        rateDays[currency] = rate.date
      }
    }
    var series: [CurrencyCode: [DayRate]] = [:]
    for rate in rates.rates where byDay.contains(rate.currency) {
      series[rate.currency, default: []].append(DayRate(day: rate.date, perUnit: rate.perUnit))
    }
    self.dayRates = DayRates(series: series)
  }

  init(
    lastReconciliation: DateOnly? = nil, rubPerUnit: [CurrencyCode: Decimal] = [:],
    dayRates: DayRates = .empty, localeIdentifier: String = "en"
  ) {
    self.lastReconciliation = lastReconciliation
    self.rubPerUnit = rubPerUnit
    self.dayRates = dayRates
    self.localeIdentifier = localeIdentifier
  }
}

/// «Owed to me»: parts I paid for somebody else that are still expected back — the figure of
/// step 3. Expected income is counted with the rest of the planning (`PlanningSnapshot`).
struct OwedSummary: Hashable, Sendable {
  var amount: AmountE4
  var count: Int

  init(amount: AmountE4 = .zero, count: Int = 0) {
    self.amount = amount
    self.count = count
  }

  /// The rule is `OverviewSummary`'s, so the card and the summary cannot disagree.
  init(_ summary: OverviewSummary) {
    self.init(amount: summary.owedToMe, count: summary.owedCount)
  }
}

/// The result of step 3, with the version of the data it was counted from.
struct OwedResult: Sendable {
  var summary: OwedSummary
  var version: DataVersion
}

/// Everything the data step hands over, built off the main thread: the ledger every screen
/// reads, the Overview figures, and the days the Overview lists. The lists read the last
/// snapshot the store has, so they keep their rows while a full run recalculates the cards.
struct DataSnapshot: Sendable {
  let ledger: Ledger
  let summary: OverviewSummary
  /// Payments, limits, goals, expectations, events, free to spend, debts, reminders and the
  /// money on the accounts, built from the same ledger off the main thread. Its `planned` is
  /// the one figure of planned payments the cards and the forecast show.
  let planning: PlanningSnapshot
  let owed: OwedSummary
  /// The days of the previous and the current month, and any later — Overview lists these.
  let recentGroups: [TransactionsStore.DayGroup]
  let recentIds: Set<UUID>
  let context: SnapshotContext
  let today: DateOnly
  let version: DataVersion

  var dataset: Dataset { ledger.dataset }

  /// The pure part of the step: the same function builds a snapshot from a fresh read and
  /// from a read with the app's own writes laid over it.
  static func build(
    dataset: Dataset, calendar: CalendarContext, today: DateOnly, context: SnapshotContext,
    version: DataVersion, now: Date = Date()
  ) -> DataSnapshot {
    let ledger = Ledger(dataset: dataset, calendar: calendar)
    let summary = OverviewSummary(ledger: ledger, today: today)
    let start = today.monthKey.previous.firstDay
    let end = max(today, ledger.rows.last?.day ?? today)
    var ids: [UUID] = []
    var seen: Set<UUID> = []
    // Rows are oldest first; walked backwards, each day lists its newest operation first,
    // as the Transactions window does (`EntryFilter`), and a row just typed tops today.
    for row in ledger.rows(in: DayRange(start, end)).reversed()
    where seen.insert(row.transactionId).inserted {
      ids.append(row.transactionId)
    }
    // The transfers of those days too: rows of their own, in no total, and selectable as long
    // as they are shown.
    let transfers = dataset.transfers.filter {
      DayRange(start, end).contains(calendar.day(of: $0.occurredAt))
    }
    seen.formUnion(transfers.map(\.id))
    // A refund taken back from a purchase counts in the purchase's day, as everywhere else.
    let groups = TransactionsStore.group(
      ids.compactMap { ledger.entry($0) }, calendar: calendar, debts: dataset.debtsById,
      transfers: transfers, refunds: ledger.refundIndex)
    return DataSnapshot(
      ledger: ledger,
      summary: summary,
      planning: PlanningSnapshot.build(
        ledger: ledger, today: today, now: now, rubPerUnit: context.rubPerUnit,
        dayRates: context.dayRates, localeIdentifier: context.localeIdentifier),
      owed: OwedSummary(summary),
      recentGroups: groups,
      recentIds: seen,
      context: context,
      today: today,
      version: version)
  }
}

/// One write of the app laid over the last snapshot, so the new row and the numbers appear
/// at once instead of after the next read. The observation of the database reads
/// everything again a moment later; until then this is what the screen shows.
struct Overlay: Sendable {
  var mark: Int
  var upserted: [TransactionEntry]
  var removed: [UUID]
  /// Parts whose reimbursement status the write changed without the app holding the whole
  /// operation: a deleted reimbursement reopens the parts it closed.
  var partStatuses: [UUID: ReimbursementStatus]

  init(mark: Int, _ write: StoreWrite) {
    self.mark = mark
    self.upserted = write.upserted
    self.removed = write.removed
    self.partStatuses = write.partStatuses
  }

  /// The snapshot with the overlays laid over it, oldest first.
  static func compose(_ base: Dataset, _ overlays: [Overlay]) -> Dataset {
    var dataset = base
    for overlay in overlays {
      dataset = dataset.upserting(overlay.upserted).removing(overlay.removed)
      guard !overlay.partStatuses.isEmpty else { continue }
      for index in dataset.entries.indices {
        for part in dataset.entries[index].parts.indices {
          let id = dataset.entries[index].parts[part].id
          if let status = overlay.partStatuses[id] {
            dataset.entries[index].parts[part].reimbursementStatus = status
          }
        }
      }
    }
    return dataset
  }
}

/// The read the lists and the cards show and the writes laid over it. Pure, so its rules are
/// tested without a window:
///
/// * a read carries the count of writes taken before it began, and a read older than the
///   last one taken is dropped — a slow read must not bring back what a newer one replaced;
/// * a write of the app is an overlay stamped with its own count and shown at once;
/// * a read keeps the overlays newer than itself: a row typed while the read was on its way
///   is laid over it again, instead of vanishing until the next read.
struct DataTrack: Sendable {
  /// The last read taken.
  private(set) var base: Dataset?
  private(set) var baseMark = -1
  /// What that read brought besides the operations: a rebuild on it uses this, not the
  /// context of whatever snapshot was on screen before it.
  private(set) var context = SnapshotContext()
  /// The app's writes newer than `base`, oldest first.
  private(set) var overlays: [Overlay] = []

  enum Adoption: Equatable, Sendable {
    /// Older than the read already taken: dropped.
    case stale
    /// Taken, and nothing newer lies over it: shown as it is.
    case show
    /// Taken, but writes newer than it lie over it: it is shown once rebuilt with them.
    case rebuild
  }

  /// What the screen should show: the last read with every newer overlay.
  var target: DataVersion { DataVersion(load: baseMark, overlay: overlays.last?.mark) }

  /// The data with the overlays laid over it, built on demand.
  var composed: Dataset? { base.map { Overlay.compose($0, overlays) } }

  /// What the screen should show, built for `today` and the moment `now` of the store's
  /// clock: `nil` before the first read.
  func rebuilt(calendar: CalendarContext, today: DateOnly, now: Date) -> DataSnapshot? {
    guard let composed else { return nil }
    return DataSnapshot.build(
      dataset: composed, calendar: calendar, today: today, context: context, version: target,
      now: now)
  }

  mutating func adopt(_ snapshot: DataSnapshot) -> Adoption {
    let mark = snapshot.version.load
    guard mark >= baseMark else { return .stale }
    base = snapshot.dataset
    baseMark = mark
    context = snapshot.context
    overlays.removeAll { $0.mark <= mark }
    return overlays.isEmpty ? .show : .rebuild
  }

  mutating func add(_ overlay: Overlay) {
    overlays.append(overlay)
  }
}
