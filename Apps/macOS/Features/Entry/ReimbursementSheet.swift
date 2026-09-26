import AppCore
import AppDatabase
import SwiftUI

/// "Money back from a person": pick the person, pick the parts that are waiting and enter
/// what came back. The rules live in `CoreAccounting` — an excess becomes income in
/// Surcharges, a shortfall becomes my spending in the category of the original part, and
/// the reimbursement itself is never income.
///
/// Everything here is in rubles: the money that comes back, the distribution and what each
/// part is owed. A part paid in another currency shows its own amount with the rubles next
/// to it, and one whose rate is still provisional waits for the pipeline.
///
/// Opened from the entry line, it starts from what was typed there (`prefill`): the money
/// that came back stays as typed while parts are ticked, and `recorded` tells the line the
/// reimbursement went in.
struct ReimbursementSheet: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Environment(\.dismiss) private var dismiss

  private let prefill: ReimbursementPrefill?
  private let recorded: () -> Void

  @State private var owed: [OwedPart] = []
  @State private var selected: Set<UUID> = []
  /// The money that came back, in rubles. Zero is nothing typed yet.
  @State private var received: AmountE4 = .zero
  /// Whether the text of «Received» reads: while it does not, `received` is the amount it read
  /// before, which the field no longer shows.
  @State private var receivedReads = true
  @State private var people: [Person] = []
  @State private var personId: UUID?
  @State private var errorText: String?
  /// What goes to each chosen part. Filled automatically and editable by hand, as the
  /// specification asks: the money that came back rarely matches the parts exactly.
  @State private var distribution = ReimbursementDistribution()
  /// «Received» was typed in the entry line: ticking a part spreads that money instead of
  /// replacing it with what the parts cost.
  @State private var receivedIsGiven: Bool

  init(prefill: ReimbursementPrefill? = nil, recorded: @escaping () -> Void = {}) {
    self.prefill = prefill
    self.recorded = recorded
    // Set before the first draw, so the change of person does not fire and tick over it.
    _personId = State(initialValue: prefill?.personId)
    _received = State(initialValue: prefill?.received ?? .zero)
    _receivedIsGiven = State(initialValue: prefill != nil)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(verbatim: environment.language("reimbursement.title", table: "Entry"))
        .font(.headline)

      Picker(selection: $personId) {
        Text(verbatim: "—").tag(UUID?.none)
        ForEach(people, id: \.id) { person in
          Text(verbatim: person.name).tag(UUID?.some(person.id))
        }
      } label: {
        // Who gave the money back, not whom it was spent on.
        Text(verbatim: environment.language("entry.fromWhom", table: "Entry"))
      }
      .onChange(of: personId) { _, _ in selectAllOfPerson() }

      List {
        ForEach(filteredOwed, id: \.partId) { part in
          HStack {
            Toggle(isOn: binding(for: part.partId)) {
              VStack(alignment: .leading, spacing: 2) {
                HStack {
                  Text(verbatim: part.note ?? "—")
                  Spacer()
                  Text(verbatim: amountText(for: part))
                    .font(.body.monospacedDigit())
                }
                if part.rateProvisional {
                  // The rubles a link fixes now would drift from the refined ones.
                  Text(verbatim: t("reimbursement.provisionalRate"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if part.returnedRubE4.raw > 0 {
                  // Some of it came back already: what is owed is the rest.
                  Text(
                    verbatim: environment.language.format(
                      "reimbursement.returnedSoFar", table: "Entry",
                      environment.money.exact(part.returnedRubE4))
                  )
                  .font(.caption)
                  .foregroundStyle(.secondary)
                }
              }
            }
            .toggleStyle(.checkbox)
            .disabled(part.rateProvisional)
            if selected.contains(part.partId) {
              AmountField(amount: allocationBinding(for: part))
                .frame(width: 110)
            }
            // Giving up on the money: the part stops waiting and becomes my spending — all of
            // it, or only the rest when some of it came back already.
            Button(
              environment.language(
                part.returnedRubE4.raw > 0 ? "reimbursement.writeOffRest" : "owed.writeOff",
                table: "Entry")
            ) {
              writeOff(part)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
          }
        }
      }
      .frame(minWidth: 460, minHeight: 180)

      HStack {
        Text(verbatim: environment.language("reimbursement.received", table: "Entry"))
        // Typed like every amount: «1,500» is 1 500, a formula comes to its result.
        AmountField(amount: $received, reads: $receivedReads)
          .frame(width: 120)
          // Typing less than the parts cost is how a shortfall is recorded: the shares
          // follow the amount, or they would stay larger than the money that came back.
          .onChange(of: received) { _, _ in spreadAutomatically() }
          .onChange(of: receivedReads) { _, _ in spreadAutomatically() }
        Spacer()
        Text(verbatim: environment.money.exact(selectedTotal))
          .foregroundStyle(.secondary)
        Button(environment.language("reimbursement.spread", table: "Entry")) {
          spreadAutomatically()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(selected.isEmpty)
      }

      if let errorText {
        Text(verbatim: errorText)
          .font(.caption)
          .foregroundStyle(.red)
      } else if ReimbursementRecording.payer(chosen: personId, closing: selectedParts)
        == .differentPeople
      {
        // Why «Save» is off: with «—» the list shows everybody's parts.
        Text(verbatim: t("reimbursement.differentPeople"))
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Spacer()
        Button(environment.language("action.cancel"), role: .cancel) { dismiss() }
        Button(environment.language("action.save"), action: record)
          .buttonStyle(.borderedProminent)
          .disabled(
            !Self.canRecord(closing: selectedParts, chosen: personId, received: amountValue))
      }
    }
    .padding(20)
    .onAppear {
      reload()
      startFromTheLine()
    }
  }

  /// What the entry line handed over: the parts the person it named owes are ticked, and the
  /// money typed there is spread over them.
  private func startFromTheLine() {
    guard let prefill, selected.isEmpty else { return }
    selected = prefill.initialSelection(in: owed)
    spreadAutomatically()
  }

  private var filteredOwed: [OwedPart] {
    guard let personId else { return owed }
    return owed.filter { $0.debtorPersonId == personId }
  }

  private var selectedParts: [OwedPart] { owed.filter { selected.contains($0.partId) } }

  /// What is still owed on the chosen parts in rubles — the money the person is expected to
  /// return: a part some money came back for already owes only the rest.
  private var selectedTotal: AmountE4 { AmountE4.sum(selectedParts.map(\.remainingRubE4)) }

  /// The part in the money it was paid in; a foreign one also shows what that was in rubles.
  private func amountText(for part: OwedPart) -> String {
    let own = environment.money.exact(part.amountE4, currency: part.currency)
    guard part.currency != .rub else { return own }
    return "\(own) ≈ \(environment.money.exact(part.amountRubE4))"
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Entry") }

  private var amountValue: AmountE4? { Self.received(received, reads: receivedReads) }

  /// The money that came back, once there is some and the field reads: nothing is not an
  /// amount to record, and neither is the amount left over from text that no longer reads
  /// («1,700» turned into «1,700+»).
  static func received(_ amount: AmountE4, reads: Bool) -> AmountE4? {
    reads && amount.raw > 0 ? amount : nil
  }

  private func binding(for id: UUID) -> Binding<Bool> {
    Binding(
      get: { selected.contains(id) },
      set: { isOn in
        if isOn { selected.insert(id) } else { selected.remove(id) }
        if !receivedIsGiven { received = selectedTotal }
        spreadAutomatically()
      })
  }

  private func allocationBinding(for part: OwedPart) -> Binding<AmountE4> {
    Binding(
      get: { distribution.share(of: part.partId) },
      set: { distribution.correct(part.partId, to: $0) })
  }

  /// Spreads what came back over the chosen parts, oldest first, as the core does; a
  /// correction made by hand before is dropped.
  private func spreadAutomatically() {
    distribution.spread(amountValue, over: owed.filter { selected.contains($0.partId) })
  }

  private func writeOff(_ part: OwedPart) {
    let outcome =
      part.returnedRubE4.raw > 0
      ? Self.writeOffRest(
        of: part, repository: environment.transactions, store: store,
        setting: try? environment.transactions.map(recordingSetting),
        scheduleBackup: environment.scheduleBackup)
      : Self.writeOff(
        part.partId, repository: environment.transactions, store: store,
        scheduleBackup: environment.scheduleBackup)
    switch outcome {
    case .writtenOff: errorText = nil
    case .gone: errorText = t("reimbursement.partGone")
    case .failed: errorText = t("owed.writeOffFailed")
    }
    selected.remove(part.partId)
    reload()
  }

  /// «Save» is on once something is ticked, the money that came back reads as an amount, and
  /// the ticked parts are owed by one person — the one chosen, or with «—» the one they all
  /// name (`ReimbursementRecording.payer`).
  static func canRecord(
    closing parts: [OwedPart], chosen personId: UUID?, received: AmountE4?
  )
    -> Bool
  {
    !parts.isEmpty && received != nil
      && ReimbursementRecording.payer(chosen: personId, closing: parts) != .differentPeople
  }

  /// What became of «Write off».
  enum WriteOffOutcome: Equatable {
    case writtenOff
    /// The part stopped waiting while the sheet was open — closed, written off, its purchase
    /// deleted: nothing was written.
    case gone
    /// The write did not land; the journal has why.
    case failed
  }

  /// Writes a part off. Only a write that landed forgets ⌘Z and asks for a backup: the undo
  /// stack holds whole operations and cannot describe a write-off, so ⌘Z must not look as if
  /// it could — it would silently undo whatever came before instead. A write that did not
  /// land changed nothing, so the history stays and the owner is told. The lists and the
  /// numbers follow through the observation of the database.
  static func writeOff(
    _ partId: UUID, repository: TransactionRepository?, store: TransactionsStore,
    scheduleBackup: () -> Void
  ) -> WriteOffOutcome {
    do {
      guard let repository else { throw WriteOffUnavailable() }
      try repository.writeOffPart(id: partId)
    } catch ReimbursementError.partNoLongerOwed {
      return .gone
    } catch {
      AppLog.error(
        "reimbursement.writeOff", .db, "a part was not written off",
        [LogPair("error", .error(error)), LogPair("code", .count((error as NSError).code))])
      return .failed
    }
    store.forgetUndoHistory()
    scheduleBackup()
    return .writtenOff
  }

  /// «Списать остаток»: what is left of a part some money already came back for becomes my
  /// spending — an expense of the rest in rubles in the part's category, from the account the
  /// purchase was paid from — and the part is settled, in one write. Like writing a whole part
  /// off, it cannot be undone step by step, so a write that landed clears ⌘Z.
  static func writeOffRest(
    of part: OwedPart, repository: TransactionRepository?, store: TransactionsStore,
    setting: ReimbursementRecording.Setting?, now: Date = Date(), scheduleBackup: () -> Void
  ) -> WriteOffOutcome {
    do {
      guard let repository else { throw WriteOffUnavailable() }
      let companion = MoneyBack.remainderWriteOff(
        part: part, occurredAt: now, operationId: UUID(),
        tree: setting?.categories ?? CategoryTree(), history: setting?.history ?? .empty, now: now)
      try repository.writeOffRemainder(partId: part.partId, companion: companion, at: now)
    } catch ReimbursementError.partNoLongerOwed {
      return .gone
    } catch {
      AppLog.error(
        "reimb.writeOffRest", .db, "the rest of a part was not written off",
        [LogPair("error", .error(error))])
      return .failed
    }
    store.forgetUndoHistory()
    scheduleBackup()
    return .writtenOff
  }

  /// The database is not open: there is nothing to write the part off in.
  private struct WriteOffUnavailable: Error {}

  private func reload() {
    people = (try? environment.references?.people()) ?? []
    owed = (try? environment.transactions?.owedParts()) ?? []
  }

  private func selectAllOfPerson() {
    selected = Set(filteredOwed.filter { !$0.rateProvisional }.map(\.partId))
    if !receivedIsGiven { received = selectedTotal }
    spreadAutomatically()
  }

  /// Writes the reimbursement, the links and whatever the rules add on top.
  private func record() {
    guard let repository = environment.transactions,
      let amount = amountValue
    else { return }
    let parts = selectedParts

    do {
      let recording = try ReimbursementRecording.make(
        id: UUID(), received: amount, closing: parts, distribution: distribution,
        personId: personId, occurredAt: prefill?.occurredAt, note: prefill?.note,
        accountId: prefill?.accountId, leg: prefill?.leg,
        setting: try recordingSetting(repository))
      try repository.apply(
        recording.outcome, reimbursement: recording.reimbursement, extra: recording.extra)
      environment.scheduleBackup()
      // Several operations and the links between them went in at once; a single undo step
      // cannot take that back, so ⌘Z is not offered rather than undoing something else.
      store.forgetUndoHistory()
      recorded()
      dismiss()
    } catch ReimbursementError.provisionalRate {
      errorText = t("reimbursement.provisionalRate")
    } catch ReimbursementError.allocationExceedsAmount {
      // Only shares corrected by hand get here: an untouched distribution is left to the core.
      errorText = t("reimbursement.sharesExceedReceived")
    } catch ReimbursementError.allocationExceedsPart {
      errorText = t("reimbursement.shareExceedsPart")
    } catch ReimbursementRecording.Failure.noSurchargesCategory {
      // A database without the system category: the surplus is never written as income
      // with no category. Money that matches the parts, or falls short, still goes in.
      AppLog.error("reimb.noSurcharges", .db, "no Surcharges category for a surplus")
      errorText = t("reimbursement.noSurcharges")
    } catch ReimbursementRecording.Failure.partsOfDifferentPeople {
      errorText = t("reimbursement.differentPeople")
    } catch ReimbursementError.partNoLongerOwed {
      // Deleted, taken back by ⌘Z, written off or closed while the sheet was open: nothing
      // was written. The list is read again, and what is still ticked is spread again.
      errorText = t("reimbursement.partGone")
      reload()
      selected.formIntersection(owed.map(\.partId))
      spreadAutomatically()
    } catch {
      AppLog.error(
        "reimbursement.failed", .db, "a reimbursement was not recorded",
        [LogPair("error", .error(error))])
      errorText = t("reimbursement.failed")
    }
  }

  /// The dictionaries and the history a shortfall needs for its category and its quality.
  /// Archived categories are included: the part being closed may sit in one retired since.
  private func recordingSetting(
    _ repository: TransactionRepository
  ) throws
    -> ReimbursementRecording.Setting
  {
    let categories = try environment.references?.categories(includeArchived: true) ?? []
    let history = try repository.manualQualityHistory()
    return ReimbursementRecording.Setting(
      surchargesCategoryId: try environment.references?
        .category(systemRole: .surcharges, kind: .income)?.id,
      categories: CategoryTree(categories),
      history: history,
      surplusNote: t("reimbursement.surplus"),
      shortfallNote: t("reimbursement.shortfall"))
  }
}
