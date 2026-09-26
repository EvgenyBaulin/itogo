import AppCore
import SwiftUI

/// The ↓ panel. Every field of an operation is here: type, category with suggestions,
/// quality, for whom, place, event, the account and what it was charged, goal, debt, note,
/// date, currency and rate — plus splitting, paying for somebody else and buying on credit.
/// Only the fields the kind has are shown (`EntryDraftModel.fields`): income has no place,
/// event, «на кого», «за другого» or credit; money back has its person and its account; a
/// refund names the purchase it takes money back from.
struct DetailsPanel: View {
  @Dependency(\.environment) private var environment
  @Dependency(\.compute) private var compute
  /// Handed to the sheet of «Add…», which SwiftUI lays out in a host of its own.
  @Environment(\.dependencies) private var dependencies
  @Bindable var model: EntryDraftModel
  /// Return in a text field of the panel («Сохранение — Enter»). The ↓ panel
  /// of the entry line saves with it; the editor of a saved operation has «Save» of its own.
  var submit: (() -> Void)? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      typeRow
      Divider()
      mainFields
      // Money back is never split: a split held before the kind changed stays out of sight,
      // and out of what is written.
      if model.isSplit && model.has(.split) {
        Divider()
        splitEditor
      }
      Divider()
      footer
      // «Save» is inactive for these, and nothing else in the panel says why. Wraps in the
      // width it is given: the panel is also the inspector, a column of a split view.
      if let refusal = model.shownRefusalKey {
        Text(verbatim: t(refusal))
          .font(.caption)
          .foregroundStyle(.red)
          .accessibilityIdentifier("entry.refusal")
      }
      // A record «Add…» asked for that the database refused: nothing was chosen.
      if let failure = model.creationFailureKey {
        Text(verbatim: t(failure))
          .font(.caption)
          .foregroundStyle(.red)
      }
    }
    .frame(maxWidth: 720, alignment: .leading)
    .onSubmit { submit?() }
    // The data was computed again — the bank's rates among it: «Списано со счёта» reads them
    // afresh the next time it is worked out.
    .onChange(of: compute.generation) { _, _ in model.ratesMayHaveChanged() }
    // «Add…» of a menu: a record of its kind, chosen in that menu once it is saved.
    .sheet(item: $model.adding) { kind in
      AddRecordSheet(kind: kind, model: model, today: environment.today) {
        model.adding = nil
      }
      .handingOver(dependencies)
    }
  }

  // MARK: Type

  private var typeRow: some View {
    Picker(selection: $model.draft.kind) {
      ForEach(TransactionKind.allCases, id: \.self) { kind in
        Text(verbatim: environment.language("kind.\(kind.rawValue)")).tag(kind)
      }
    } label: {
      Text(verbatim: t("entry.category"))
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    // Money came back for a part: what the operation is stays as the reimbursement found it.
    .disabled(model.hasClosedPart)
    // The defaults also drop a category of the other kind from every part, so switching an
    // expense to income never leaves an expense category behind.
    .onChange(of: model.draft.kind) { _, _ in
      model.applyDefaults(today: environment.today)
    }
  }

  // MARK: Main fields

  @ViewBuilder
  private var mainFields: some View {
    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
      GridRow {
        fieldLabel("entry.amount")
        HStack(spacing: 8) {
          AmountField(
            amount: totalBinding,
            // The text goes along: a formula typed here is kept in `amount_expr`.
            onTyped: { model.setTotal($0, typed: $1) }
          )
          .frame(width: 140)
          // One part is the whole operation: its amount is the total.
          .disabled(!model.isSplit && model.hasClosedPart)
          // The formula the amount was worked out from, its numbers written the way the app
          // writes them.
          if let expression = model.draft.amountExpression {
            Text(verbatim: ExpressionEvaluator.canonical(expression) ?? expression)
              .font(.caption.monospaced())
              .foregroundStyle(.secondary)
          }
        }
      }
      if !model.isSplit && model.hasClosedPart {
        GridRow {
          Color.clear.frame(width: 1, height: 1)
          closedPartCaption
        }
      }
      if model.offersRefundPurchase {
        GridRow {
          fieldLabel("entry.refund.purchase")
          refundPurchaseRow
        }
      }
      if model.has(.category) {
        GridRow {
          fieldLabel("entry.category")
          categoryPicker(forPartAt: 0)
        }
        GridRow {
          fieldLabel("entry.subcategory")
          subcategoryPicker(forPartAt: 0)
        }
        if !model.categorySuggestions.isEmpty {
          GridRow {
            Color.clear.frame(width: 1, height: 1)
            suggestionChips
          }
        }
      }
      if model.hasQuality && model.has(.quality) {
        GridRow {
          fieldLabel("entry.quality")
          qualityPicker(for: partBinding(0))
        }
      }
      if model.has(.fromPerson) {
        // Money back names the person it came from, and nothing else about them.
        GridRow {
          fieldLabel("entry.fromWhom")
          referencePicker(
            selection: partBinding(0).forPersonId,
            options: model.people.map { ($0.id, $0.name) }, adding: .person(part: 0))
        }
      } else if model.has(.forWhom) {
        GridRow {
          fieldLabel(forWhomKey)
          forWhomPicker(forPartAt: 0)
        }
      }
      if model.has(.place) {
        GridRow {
          fieldLabel("entry.place")
          // Through the model, like a place the line names: it brings its category and its
          // payment method. A place not been to yet is added from the menu, and the name the
          // line could not match is where its sheet starts.
          referencePicker(
            selection: Binding(
              get: { model.draft.placeId },
              set: { model.setPlace($0, today: environment.today) }),
            options: model.places.map { ($0.id, $0.name) }, adding: .place)
        }
      }
      if model.has(.event) {
        GridRow {
          fieldLabel("entry.event")
          HStack(spacing: 8) {
            referencePicker(
              selection: partBinding(0).eventId,
              options: model.events.map { ($0.id, $0.name) }, adding: .event(part: 0))
            if let suggested = model.suggestedEvent, model.draft.parts.first?.eventId == nil {
              Button {
                model.draft.parts[0].eventId = suggested.id
              } label: {
                Label {
                  Text(verbatim: suggested.name)
                } icon: {
                  Image(systemName: "calendar.badge.plus")
                }
              }
              .buttonStyle(.bordered)
              .controlSize(.small)
              .help(t("entry.eventSuggested"))
            }
          }
        }
      }
      GridRow {
        // «Со счёта» for spending, «На счёт» for money that comes in, «Счёт» for a goal.
        fieldLabel(model.accountFieldKey)
        // An account chosen here is the owner's: no place chosen after it replaces it. The
        // main account first, the rest in the owner's order, and no «none»: an operation that
        // names no account is on the main one, and the picker says so. Only a database with no
        // account yet shows «—», with «Add…» to make one.
        referencePicker(
          selection: Binding(
            get: { model.selectedAccount?.id }, set: { model.setPaymentMethod($0) }),
          options: model.accountChoices(locale: environment.language.locale)
            .map { ($0.id, $0.name) },
          adding: .paymentMethod, offersNone: model.selectedAccount == nil)
      }
      if model.needsCharge {
        GridRow {
          fieldLabel("entry.accountCharge")
          AccountChargeField(model: model)
        }
      }
      if model.has(.goal) && model.isGoalContribution(model.part(at: 0)) {
        GridRow {
          fieldLabel("entry.goal")
          referencePicker(
            selection: Binding(
              get: { model.part(at: 0).goalId },
              set: {
                model.setGoal($0, forPartAt: 0)
                model.applyDefaults(today: environment.today)
              }),
            options: model.goals.map { ($0.id, $0.name) })
        }
      }
      if model.has(.debt) && (model.draft.kind == .expense || model.draft.debtId != nil) {
        GridRow {
          fieldLabel("entry.debt")
          referencePicker(
            selection: $model.draft.debtId,
            options: model.debts.map { ($0.id, $0.name) })
        }
      }
      GridRow {
        fieldLabel("entry.note")
        TextField(text: Binding($model.draft.note, replacingNilWith: "")) {
          Text(verbatim: t("entry.note"))
        }
        .labelsHidden()
      }
      GridRow {
        fieldLabel("entry.date")
        // A new day offers the event covering it instead of the old day's.
        DatePicker(
          selection: Binding(
            get: { model.draft.occurredAt },
            set: { model.setDate($0, today: environment.today) }),
          displayedComponents: [.date, .hourAndMinute]
        ) {
          Text(verbatim: t("entry.date"))
        }
        .labelsHidden()
        .environment(\.locale, environment.language.locale)
      }
      if model.draft.kind == .income {
        GridRow {
          fieldLabel("entry.periodMonth")
          periodMonthPicker
        }
        if !openExpectations.isEmpty {
          GridRow {
            fieldLabel("entry.expected")
            if model.linksExpectedIncome {
              Picker(selection: $model.expectedIncomeId) {
                Text(verbatim: "—").tag(UUID?.none)
                ForEach(openExpectations) { status in
                  Text(verbatim: status.income.name).tag(Optional(status.id))
                }
              } label: {
                EmptyView()
              }
              .labelsHidden()
            } else {
              // The editor writes no link: a saved income is tied in Planning.
              caption("entry.expectedInPlanning")
            }
          }
        }
      }
      GridRow {
        fieldLabel("entry.currency")
        currencyPicker
      }
      if model.draft.currency != .rub {
        GridRow {
          fieldLabel("entry.rate")
          rateField
        }
      }
    }
  }

  private var suggestionChips: some View {
    HStack(spacing: 6) {
      ForEach(model.categorySuggestions, id: \.id) { category in
        // History remembers the most specific category, so a chip fills both pickers and
        // shows the whole path — otherwise two chips could read the same.
        Button(title(for: category)) {
          model.applySuggestion(category)
          model.applyDefaults(today: environment.today)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    }
  }

  // MARK: Split, paid for someone, on credit

  private var splitEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      // Two lines per part, not one. A part carries everything an operation does («У
      // каждой части свои категория, подкатегория, оценка, сумма (тоже выражением), «для
      // кого», событие и признак «за другого»»), and all of it in one row came to about 790 pt
      // against a panel of 720 — the «−» would have fallen off the right edge, and in the
      // inspector, which is 360 pt wide, most of the row with it.
      ForEach(Array(model.draft.parts.enumerated()), id: \.element.id) { index, part in
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 10) {
            // Stacked rather than side by side: a split row has to fit the panel as well.
            if model.has(.category) {
              VStack(alignment: .leading, spacing: 4) {
                categoryPicker(forPartAt: index)
                subcategoryPicker(forPartAt: index)
              }
              .frame(maxWidth: 200)
            }
            // Each part has a quality of its own, so it sits next to the amount.
            VStack(alignment: .leading, spacing: 4) {
              AmountField(amount: partBinding(index).amount)
                .frame(width: 120)
                .disabled(model.isClosedPart(id: part.id))
              if model.hasQuality {
                qualityMenu(for: partBinding(index))
              }
            }
            Spacer(minLength: 0)
            Button {
              model.removePart(id: part.id)
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            // A part someone gave the money back for stays.
            .disabled(!model.canRemovePart(id: part.id))
          }
          // The second line: «для кого» with its person, the event, and «за другого» with the
          // debtor. Until 21.09 the first two were offered for part one only, and the only way
          // to set them on part two was the bulk menu of the table. One line in the panel;
          // in the inspector, 360 pt, it did not fit — about 400 pt in English — and the column
          // showed the middle of the whole editor, «mount» and «ategory» cut at the left
          // (24.09, `testTheEditorFitsTheInspectorBesideTheSidebar`), so there the three groups
          // go one under another.
          // Income has none of the three: its parts are an amount and a category.
          if model.has(.forWhom) || model.has(.event) || model.has(.reimbursable) {
            ViewThatFits(in: .horizontal) {
              HStack(spacing: 10) {
                partForWhom(index)
                partEvent(index)
                partPaidForSomeone(index, part)
                Spacer(minLength: 0)
              }
              VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) { partForWhom(index) }
                HStack(spacing: 10) { partEvent(index) }
                HStack(spacing: 10) { partPaidForSomeone(index, part) }
              }
            }
            .font(.caption)
          }
          if model.isClosedPart(id: part.id) {
            closedPartCaption
          }
          if index < model.draft.parts.count - 1 { Divider() }
        }
      }
      HStack {
        Text(verbatim: t("entry.unallocated"))
          .foregroundStyle(model.draft.isBalanced ? Color.secondary : Color.red)
        Text(
          verbatim: environment.money.exact(model.draft.unallocated, currency: model.draft.currency)
        )
        .font(.body.monospacedDigit())
        .foregroundStyle(model.draft.isBalanced ? Color.secondary : Color.red)
      }
      .font(.caption)
    }
  }

  @ViewBuilder
  private func partForWhom(_ index: Int) -> some View {
    if model.has(.forWhom) {
      partLabel(forWhomKey)
      forWhomPicker(forPartAt: index)
    }
  }

  @ViewBuilder
  private func partEvent(_ index: Int) -> some View {
    if model.has(.event) {
      partEventPicker(index)
    }
  }

  @ViewBuilder
  private func partEventPicker(_ index: Int) -> some View {
    partLabel("entry.event")
    referencePicker(
      selection: partBinding(index).eventId,
      options: model.events.map { ($0.id, $0.name) }, adding: .event(part: index)
    )
    .frame(maxWidth: 140)
  }

  @ViewBuilder
  private func partPaidForSomeone(_ index: Int, _ part: PartDraft) -> some View {
    if model.has(.reimbursable) {
      partPaidForSomeonePicker(index, part)
    }
  }

  @ViewBuilder
  private func partPaidForSomeonePicker(_ index: Int, _ part: PartDraft) -> some View {
    Toggle(isOn: partBinding(index).reimbursable) {
      Text(verbatim: t("entry.paidForSomeone"))
    }
    .toggleStyle(.checkbox)
    // Its money came back: the part stays paid for them.
    .disabled(model.isClosedPart(id: part.id))
    if part.reimbursable {
      // Who pays it back is added from the menu, like the person of «для кого».
      referencePicker(
        selection: partBinding(index).debtorPersonId,
        options: model.people.map { ($0.id, $0.name) }, adding: .debtor(part: index)
      )
      .frame(maxWidth: 140)
      .disabled(model.isClosedPart(id: part.id))
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        // A refund of a purchase takes back one amount of one part: it is neither split nor
        // paid for somebody else.
        if model.canSplit {
          Button(t("entry.split")) {
            model.addPart()
          }
          .buttonStyle(.bordered)
        }

        if model.canMarkPaidForSomeone {
          Button(t("entry.paidForSomeone")) {
            model.markLastPartPaidForSomeone()
          }
          .buttonStyle(.bordered)
        }

        // In the editor the box only says what the purchase is: a saved purchase is put on
        // credit or taken off it in Debts, never by a plan the editor would not write. A plain
        // one does not show it at all, and neither does an income or a refund: only a purchase
        // is bought on credit.
        if model.offersCredit || model.isOnCredit {
          Toggle(isOn: onCreditBinding) {
            Text(verbatim: t("entry.onCredit"))
          }
          .toggleStyle(.checkbox)
          .disabled(!model.canChangeCredit)
        }

        Spacer()
      }

      if !model.canChangeCredit && model.isOnCredit {
        caption("entry.creditInDebts")
      }

      if model.creditPlan != nil {
        creditFields
      }
    }
  }

  /// Which debt the purchase joins — an existing one or a new one — and how it is repaid.
  @ViewBuilder
  private var creditFields: some View {
    let plan = Binding(
      get: { model.creditPlan ?? EntryDraftModel.CreditPlan() },
      set: { model.creditPlan = $0 })

    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
      GridRow {
        fieldLabel("entry.debt")
        Picker(selection: plan.debtId) {
          Text(verbatim: t("entry.newDebt")).tag(UUID?.none)
          ForEach(model.debts, id: \.id) { debt in
            Text(verbatim: debt.name).tag(UUID?.some(debt.id))
          }
        } label: {
          EmptyView()
        }
        .labelsHidden()
      }
      // The count and the instalment move together, and only a new debt takes them: an
      // existing one keeps its own payment.
      if plan.wrappedValue.debtId == nil {
        GridRow {
          fieldLabel("entry.payments")
          Stepper(
            value: Binding(
              get: { plan.wrappedValue.payments }, set: { model.setCreditPayments($0) }),
            in: EntryDraftModel.creditPaymentsRange
          ) {
            Text(verbatim: "\(plan.wrappedValue.payments)")
              .font(.body.monospacedDigit())
          }
          .fixedSize()
        }
        GridRow {
          fieldLabel("entry.monthlyPayment")
          AmountField(
            amount: Binding(
              get: { plan.wrappedValue.monthlyAmount }, set: { model.setCreditMonthly($0) })
          )
          .frame(width: 120)
        }
      }
    }
  }

  // MARK: Pieces

  private func fieldLabel(_ key: String) -> some View {
    Text(verbatim: t(key))
      .font(.caption)
      .foregroundStyle(.secondary)
      .gridColumnAlignment(.leading)
  }

  /// The category of a part. Choosing one drops whatever subcategory was under the
  /// previous category, so the pair can never end up mismatched.
  private func categoryPicker(forPartAt index: Int) -> some View {
    // The source is set inside the binding rather than in `onChange`: only a choice made
    // here is `manual`, while a category that history or a template filled in keeps its
    // own source.
    let selection = Binding<UUID?>(
      get: { model.categoryOfPart(model.part(at: index)) },
      set: { newValue in
        model.setCategory(newValue, forPartAt: index)
        model.applyDefaults(today: environment.today)
      })

    return Picker(selection: addingSelection(selection, .category(part: index))) {
      Text(verbatim: "—").tag(UUID?.none)
      ForEach(model.categoryOptions(forPartAt: index), id: \.id) { category in
        Text(verbatim: optionTitle(category)).tag(UUID?.some(category.id))
      }
      addItem
    } label: {
      Text(verbatim: t("entry.category"))
    }
    .labelsHidden()
  }

  /// The subcategory of a part: only children of the chosen category, plus the dash, which
  /// leaves the operation on the category itself. «Add…» files a new one under that category
  /// — only one of the owner's (`canAddSubcategory`) — so the menu is off only when there is
  /// neither a child to choose nor a category to add one under.
  private func subcategoryPicker(forPartAt index: Int) -> some View {
    let children = model.subcategoryOptions(forPartAt: index)
    let canAdd = model.canAddSubcategory(forPartAt: index)
    let selection = Binding<UUID?>(
      get: { model.subcategoryOfPart(model.part(at: index)) },
      set: { newValue in
        model.setSubcategory(newValue, forPartAt: index)
        model.applyDefaults(today: environment.today)
      })

    return Picker(
      selection: canAdd ? addingSelection(selection, .subcategory(part: index)) : selection
    ) {
      Text(verbatim: "—").tag(UUID?.none)
      ForEach(children, id: \.id) { category in
        Text(verbatim: optionTitle(category)).tag(UUID?.some(category.id))
      }
      if canAdd { addItem }
    } label: {
      Text(verbatim: t("entry.subcategory"))
    }
    .labelsHidden()
    .disabled(children.isEmpty && !canAdd)
  }

  private func qualityPicker(for part: Binding<PartDraft>) -> some View {
    Picker(selection: qualitySelection(for: part)) {
      ForEach(Quality.allCases, id: \.self) { quality in
        Text(verbatim: environment.language(Palette.qualityKey(quality)))
          .tag(Quality?.some(quality))
      }
    } label: {
      Text(verbatim: t("entry.quality"))
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .disabled(!model.canRateByHand(part.wrappedValue))
  }

  /// The same choice folded into a menu, narrow enough for a row of the split. Every value
  /// carries its symbol and its name, never a colour alone.
  private func qualityMenu(for part: Binding<PartDraft>) -> some View {
    Picker(selection: qualitySelection(for: part)) {
      ForEach(Quality.allCases, id: \.self) { quality in
        Label {
          Text(verbatim: environment.language(Palette.qualityKey(quality)))
        } icon: {
          Image(systemName: Palette.qualitySymbol(quality))
        }
        .tag(Quality?.some(quality))
      }
    } label: {
      Text(verbatim: t("entry.quality"))
    }
    .pickerStyle(.menu)
    .labelsHidden()
    .fixedSize()
    .help(t("entry.quality"))
    .disabled(!model.canRateByHand(part.wrappedValue))
  }

  /// Same reasoning as the category picker: only a choice made here is `manual`, and a
  /// contribution to a goal cannot be re-rated at all.
  private func qualitySelection(for part: Binding<PartDraft>) -> Binding<Quality?> {
    Binding(
      get: { part.wrappedValue.quality },
      set: { newValue in
        part.wrappedValue.quality = newValue
        part.wrappedValue.qualitySource = .manual
      })
  }

  private func forWhomPicker(forPartAt index: Int) -> some View {
    let part = partBinding(index)
    return HStack(spacing: 6) {
      // Choosing a value drops the person the part named. A set person beats the value
      // everywhere the app renders «для кого» (`TransactionRows`), so leaving it would make
      // the choice invisible — and the bulk edit already drops it for the same reason
      // (`BulkEditRule`).
      Picker(selection: forWhomBinding(for: part)) {
        ForEach(ForWhom.allCases, id: \.self) { value in
          Text(verbatim: environment.label(for: value)).tag(value)
        }
      } label: {
        Text(verbatim: t("entry.forWhom"))
      }
      .labelsHidden()
      referencePicker(
        selection: part.forPersonId,
        options: model.people.map { ($0.id, $0.name) }, adding: .person(part: index))
    }
  }

  /// «Для кого» as a choice that also lets go of the person the part named.
  private func forWhomBinding(for part: Binding<PartDraft>) -> Binding<ForWhom> {
    Binding(
      get: { part.wrappedValue.forWhom },
      set: { value in
        guard value != part.wrappedValue.forWhom else { return }
        part.wrappedValue.forWhom = value
        part.wrappedValue.forPersonId = nil
      })
  }

  /// A short caption beside a control of a split row: the field grid has a label column and
  /// a row of the split editor does not, and a disabled empty picker with nothing beside it
  /// is indistinguishable from a broken one.
  private func partLabel(_ key: String) -> some View {
    Text(verbatim: t(key))
      .foregroundStyle(.secondary)
      .fixedSize()
  }

  /// A menu of a dictionary. Given `adding`, «Add…» ends it and opens the sheet of that kind,
  /// and the menu is never off for want of rows: «Add…» is always there to choose. The goal and
  /// the debt have no «Add…» and are off while there is nothing to choose.
  /// `offersNone` false leaves out «—»: the account, which every operation has once there is
  /// one.
  private func referencePicker(
    selection: Binding<UUID?>, options: [(UUID, String)], adding kind: AddFromPicker.Kind? = nil,
    offersNone: Bool = true
  ) -> some View {
    Picker(selection: kind.map { addingSelection(selection, $0) } ?? selection) {
      if offersNone {
        Text(verbatim: "—").tag(UUID?.none)
      }
      ForEach(options, id: \.0) { option in
        Text(verbatim: option.1).tag(UUID?.some(option.0))
      }
      if kind != nil { addItem }
    } label: {
      EmptyView()
    }
    .labelsHidden()
    .disabled(kind == nil && options.isEmpty)
  }

  /// The last item of a menu of a dictionary, after a line.
  @ViewBuilder
  private var addItem: some View {
    Divider()
    Text(verbatim: t("entry.add")).tag(UUID?.some(AddFromPicker.tag))
  }

  /// The choice of a menu that ends with «Add…»: that item opens the sheet of `kind` and
  /// leaves the choice as it was.
  private func addingSelection(
    _ selection: Binding<UUID?>, _ kind: AddFromPicker.Kind
  ) -> Binding<UUID?> {
    AddFromPicker.selection(selection) { model.adding = kind }
  }

  /// Expectations not fulfilled yet, from the planning the pipeline counted.
  private var openExpectations: [ExpectedIncomeStatus] {
    (compute.snapshot?.planning.expected ?? []).filter { !$0.isFulfilled && !$0.income.closed }
  }

  /// Income says which month it is for; by default that is the month of its date.
  private var periodMonthPicker: some View {
    Picker(
      selection: Binding(
        get: { model.shownPeriodMonth },
        set: { model.draft.periodMonth = $0 })
    ) {
      ForEach(model.periodMonthOptions, id: \.iso) { month in
        Text(verbatim: month.iso).tag(month)
      }
    } label: {
      EmptyView()
    }
    .labelsHidden()
  }

  /// A currency picked here is the owner's: the account chosen after it does not replace it.
  private var currencyPicker: some View {
    Picker(
      selection: Binding(get: { model.draft.currency }, set: { model.setCurrency($0) })
    ) {
      ForEach(environment.vocabulary.enabledCurrencies, id: \.code) { currency in
        Text(verbatim: currency.code).tag(currency)
      }
    } label: {
      EmptyView()
    }
    .labelsHidden()
    // A refund of a purchase is in the purchase's currency.
    .disabled(model.hasClosedPart || model.refundTarget != nil)
  }

  /// The purchase a refund takes money back from: picked, «без покупки», or still to pick.
  private var refundPurchaseRow: some View {
    HStack(spacing: 8) {
      if let target = model.refundTarget {
        Label {
          Text(verbatim: purchaseTitle(target))
        } icon: {
          Image(systemName: "arrow.uturn.left.circle")
        }
        .accessibilityIdentifier("entry.refund.purchase")
      } else if model.refundWithoutPurchase {
        Text(verbatim: t("entry.refund.none"))
          .foregroundStyle(.secondary)
      }
      Button(t(model.refundTarget == nil ? "entry.refund.pick" : "entry.refund.change")) {
        model.refundPicking = RefundPickerRequest(savesAfterChoice: false)
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  /// «кроссовки · 12 September 2026 · 7,000.00 ₽».
  private func purchaseTitle(_ target: EntryDraftModel.RefundTarget) -> String {
    let transaction = target.purchase.transaction
    let day = environment.dates.longDay(environment.calendar.day(of: transaction.occurredAt))
    let amount = environment.money.exact(target.part.amountE4, currency: transaction.currency)
    return [target.part.note ?? transaction.note, day, amount].compactMap { $0 }
      .joined(separator: " · ")
  }

  /// Why the money of a part cannot be changed: someone gave it back.
  private var closedPartCaption: some View { caption("entry.closedPart") }

  /// Why a field cannot be changed here, or where it is changed instead.
  private func caption(_ key: String) -> some View {
    Text(verbatim: t(key))
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private var rateField: some View {
    HStack(spacing: 8) {
      RateField(model: model, title: t("entry.rate"))
        .labelsHidden()
        .frame(width: 120)
        // A refund of a purchase is at the purchase's rate.
        .disabled(!model.canTypeRate)
      if model.draft.rateSource == .manual {
        Text(verbatim: t("entry.rateManual"))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Helpers

  private func t(_ key: String) -> String { environment.language(key, table: "Entry") }

  /// Money back names the person it came from; everything else, whom it was spent on.
  private var forWhomKey: String { Self.forWhomKey(of: model.draft.kind) }

  static func forWhomKey(of kind: TransactionKind) -> String {
    kind == .reimbursement ? "entry.fromWhom" : "entry.forWhom"
  }

  /// A retired category is only ever shown for what is already filed under it, and says so.
  private func optionTitle(_ category: CoreKit.Category) -> String {
    category.archived ? environment.format("common.archivedName", category.name) : category.name
  }

  private func title(for category: CoreKit.Category) -> String {
    guard let parentId = category.parentId,
      let parent = model.categories.first(where: { $0.id == parentId })
    else { return category.name }
    return "\(parent.name) › \(category.name)"
  }

  private var onCreditBinding: Binding<Bool> {
    Binding(
      get: { model.isOnCredit },
      set: { isOn in
        if isOn {
          model.startCreditPlan()
        } else {
          model.stopCreditPlan()
        }
      })
  }

  /// The total of the operation. A draft with a single part keeps that part in step, so
  /// correcting the amount of an ordinary operation just works; a split keeps its parts
  /// and shows what is left unallocated.
  private var totalBinding: Binding<AmountE4> {
    Binding(get: { model.draft.amount }, set: { model.setTotal($0) })
  }

  private func partBinding(_ index: Int) -> Binding<PartDraft> {
    Binding(
      get: { model.draft.parts.indices.contains(index) ? model.draft.parts[index] : PartDraft() },
      set: { newValue in
        guard model.draft.parts.indices.contains(index) else { return }
        model.draft.parts[index] = newValue
      })
  }
}

/// An amount that can be typed as an expression: "1500×3−2000" is evaluated as you type.
/// The field also follows the amount when something else changes it — splitting evenly,
/// for example — so what is shown is always what will be saved.
///
/// The text stays exactly as typed while the owner types: rewritten on every keystroke, it
/// would move under the cursor. Enter, Tab and leaving the field write it back the one way the
/// app writes amounts — «1500,5» becomes «1,500.50», a formula becomes what it comes to (the
/// total of an operation keeps the formula itself beside the field). What the field writes it
/// also reads back as the same amount: an equal split of 37 in eight is «4.625», never a text
/// that reads as 4 625.
///
/// Text that does not read — «1700+», «abc» — leaves the amount as it was. A form that must not
/// save that amount under such text passes `reads`: false while the text does not read.
struct AmountField: View {
  @Binding var amount: AmountE4
  /// Given, it is told every amount typed together with the text behind it, and writes the
  /// amount itself: the total of an operation keeps a formula typed in it (`amount_expr`).
  var onTyped: ((AmountE4, String) -> Void)?
  private var reads: Binding<Bool>?
  @State private var text: String = ""
  @State private var lastShown: AmountE4 = .zero
  /// The text the field has just written back itself: its amount was told when it was typed.
  @State private var writtenBack: String?
  @FocusState private var isFocused: Bool

  /// `locale` is accepted and not needed: amounts are written the same way in every language.
  init(
    amount: Binding<AmountE4>, locale _: Locale? = nil, reads: Binding<Bool>? = nil,
    onTyped: ((AmountE4, String) -> Void)? = nil
  ) {
    self._amount = amount
    self.reads = reads
    self.onTyped = onTyped
  }

  var body: some View {
    TextField(text: $text) {
      Text(verbatim: "0")
    }
    .labelsHidden()
    .font(.body.monospacedDigit())
    .focused($isFocused)
    .onAppear { show(amount) }
    .onChange(of: amount) { _, newValue in
      guard newValue != lastShown else { return }
      show(newValue)
    }
    .onChange(of: text) { _, newValue in
      // Told again, the amount would land a second time — after Enter has already saved the
      // form and emptied it for the next operation.
      let isWrittenBack = newValue == writtenBack
      writtenBack = nil
      guard !isWrittenBack else { return }
      let parsed = Self.amount(from: newValue)
      if let reads, reads.wrappedValue != (parsed != nil) { reads.wrappedValue = parsed != nil }
      guard let parsed else { return }
      lastShown = parsed
      if let onTyped { onTyped(parsed, newValue) } else { amount = parsed }
    }
    // Submit actions add up along the hierarchy: Enter still reaches the form around the field.
    .onSubmit { settle() }
    .onChange(of: isFocused) { _, focused in
      if !focused { settle() }
    }
  }

  /// What the text says: zero when it is empty — a field cleared by hand, not the last digit
  /// left in it (fourth review, 19.09) — the value of an expression that reads, and nothing
  /// while it is half typed, so the amount stays as it was.
  static func amount(from text: String) -> AmountE4? {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return .zero }
    guard let value = try? ExpressionEvaluator.evaluate(text) else { return nil }
    return try? AmountE4(decimal: value)
  }

  /// The text once the owner is done with the field: the amount it reads as, written the way
  /// the app writes amounts. Nil leaves the text alone — nothing typed, or text that does not
  /// read yet and is left for the owner to finish.
  static func settledText(_ text: String) -> String? {
    guard !text.trimmingCharacters(in: .whitespaces).isEmpty,
      let value = amount(from: text)
    else { return nil }
    return Self.text(for: value)
  }

  private func settle() {
    guard let settled = Self.settledText(text), settled != text else { return }
    writtenBack = settled
    text = settled
  }

  private func show(_ value: AmountE4) {
    lastShown = value
    text = Self.text(for: value)
  }

  /// What the field shows for an amount: nothing for zero, otherwise the amount the way the
  /// app writes amounts — «1,500.50», «4.625» — which reads back as the same amount.
  static func text(for value: AmountE4) -> String {
    value.isZero ? "" : FieldNumber.text(value)
  }
}

/// The rate typed by hand. The text stays as it is typed — «81,» is 81 half-typed, «81,40»
/// is 81.4 — and is rewritten only when the rate becomes one the text does not read: cleared,
/// or put there by something else, and once the owner is done with the field (Enter, Tab,
/// leaving it), when it is written back the way the app writes rates: «81,40» becomes «81.4».
/// Bound straight to the rate, the field showed every keystroke back as the number it made, so
/// the separator vanished under the cursor and «81,43» came out as 8143. `AmountField` keeps its
/// text the same way.
///
/// A rate keeps the rule of rates: a lone separator is the decimal one, «83,125» is 83.125.
struct RateField: View {
  let model: EntryDraftModel
  let title: String
  @State private var text = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    TextField(text: $text) {
      Text(verbatim: title)
    }
    .focused($isFocused)
    .onAppear { text = Self.text(afterTyping: text, rate: model.draft.rate) }
    // Half-typed text must not clear the rate and claim the owner chose it: that combination
    // is what converts a foreign amount one to one (see the model). Text that already reads as
    // the rate is the rate being shown, not typed: passed on, it would make a bank rate manual.
    .onChange(of: text) { _, typed in
      guard !Self.reads(typed, as: model.draft.rate) else { return }
      model.setManualRate(typed)
    }
    .onChange(of: model.draft.rate) { _, rate in
      text = Self.text(afterTyping: text, rate: rate)
    }
    .onSubmit { settle() }
    .onChange(of: isFocused) { _, focused in
      if !focused { settle() }
    }
  }

  private func settle() {
    let settled = Self.settledText(text, rate: model.draft.rate)
    if settled != text { text = settled }
  }

  /// What the field shows once the model has taken `typed`: the text as typed while it reads
  /// as the rate, otherwise the rate itself.
  static func text(afterTyping typed: String, rate: Decimal?) -> String {
    reads(typed, as: rate) ? typed : (rate.map { FieldNumber.text($0) } ?? "")
  }

  /// The text once the owner is done with the field: the rate the way the app writes rates,
  /// or nothing for no rate. Text that does not read as the rate stays as it is.
  static func settledText(_ typed: String, rate: Decimal?) -> String {
    guard reads(typed, as: rate) else { return typed }
    return rate.map { FieldNumber.text($0) } ?? ""
  }

  /// Whether `text` says `rate`: the same number however it is typed, or nothing for no rate.
  static func reads(_ text: String, as rate: Decimal?) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard let rate else { return trimmed.isEmpty }
    return DecimalMath.parse(trimmed) == rate
  }
}

/// A number put into a text field for editing, written the one way the app writes numbers, in
/// every language, so that it reads back as the same number.
enum FieldNumber {
  /// An amount: thousands grouped by commas, a point before at least two decimals — «1,500.50»,
  /// «4.625», «250». Amounts typed by hand read a lone comma before three digits as thousands,
  /// so a fraction is never written with a comma.
  static func text(_ value: AmountE4) -> String {
    NumberText.amount(value, minus: "-")
  }

  /// A rate: every digit it has, a point, no grouping — «81.4321». Rates read a lone separator
  /// as the decimal one, so a comma between thousands would turn 1,234 into 1.234.
  static func text(_ value: Decimal) -> String {
    NumberText.plain(value)
  }
}

extension Binding<String> {
  /// Lets a `TextField` edit an optional note without inventing an empty string in the model.
  init(_ source: Binding<String?>, replacingNilWith placeholder: String) {
    self.init(
      get: { source.wrappedValue ?? placeholder },
      set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
  }
}
