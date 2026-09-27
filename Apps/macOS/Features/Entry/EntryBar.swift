import AppCore
import AppKit
import SwiftUI

/// The column the entry bar floats in. It is 560 to 720 pt wide but never wider
/// than 70% of the whole window, and never comes closer than 16 pt to the sides of the
/// column it floats over. Below an 800 pt window the share wins over the minimum, and with
/// the sidebar open the column can win over both, so the bar shrinks instead of spilling
/// over the edges.
enum EntryBarMetrics {
  static let minimumWidth: CGFloat = 560
  static let maximumWidth: CGFloat = 720
  static let widthShare: CGFloat = 0.7
  /// Room kept free between the bar and each side of the column it floats over.
  static let sideMargin: CGFloat = 16
  /// Distance between the capsule and the bottom edge of the window.
  static let bottomInset: CGFloat = 18
  /// Space between the elements stacked in the bar: the panel, the chips, the caption and
  /// the capsule.
  static let spacing: CGFloat = 10
  /// Space left between the last row of the content and the top of the bar.
  static let contentGap: CGFloat = 12

  static func columnWidth(windowWidth: CGFloat, detailWidth: CGFloat) -> CGFloat {
    // The very first layout pass can hand out a width of zero. The column stands in for the
    // window until the window is measured, and the bar starts at its minimum when neither is
    // known, instead of collapsing to nothing.
    let window = isUsable(windowWidth) ? windowWidth : detailWidth
    guard isUsable(window) else { return minimumWidth }
    // Clamp the share to 560…720, then cap it by the share again: the owner's rule is
    // «never wider than 70% of the window», and on a narrow window it beats the minimum.
    let share = window * widthShare
    let preferred = min(min(max(minimumWidth, share), maximumWidth), share)
    guard isUsable(detailWidth) else { return preferred }
    return max(0, min(preferred, detailWidth - 2 * sideMargin))
  }

  /// The room the list keeps under the bar is no longer counted here. It is the height of the
  /// bar itself, and the safe area takes it (`safeAreaInset`): a height
  /// measured off the screen and handed back to the window is what made the window of
  /// Transactions loop until AppKit gave up. What that count used to say —
  /// that the capsule, the chips and the selection bar are part of the room while the ↓ panel
  /// and the caption are not — is now the shape of the view, and `MainWindowLayoutTests`
  /// holds it.
  private static func isUsable(_ width: CGFloat) -> Bool { width.isFinite && width > 0 }
}

extension EnvironmentValues {
  /// Width of the whole window, measured once at the root of the scene. Views deep inside a
  /// split view only see their own column, and some sizes are defined by the window.
  @Entry var windowWidth: CGFloat = 0
}

/// The floating glass capsule that is always visible in the main window. Enter saves.
/// It keeps to a column of its own — centred above the content and bounded by
/// `EntryBarMetrics` — instead of stretching from one edge of the window to the other.
/// The ↓ panel grows out of the same `GlassEffectContainer`, so the two morph into one
/// another instead of stacking glass on glass.
///
/// `accessory` is another control of the same layer, shown just above the capsule — the
/// bar of a selection in the list. It lives in the same container for the same reason.
struct EntryBar<Accessory: View>: View {
  /// Width of the whole window: the bar takes a share of it.
  let windowWidth: CGFloat
  /// Width of the column the bar floats over: the bar never reaches its sides.
  let detailWidth: CGFloat
  /// The ↓ panel is open from the start. A test opens it this way: a key press needs a key
  /// window, and a test host is not always given one.
  var opensDetails: Bool = false
  /// Glass of its own, or nothing. While it is shown it stands in the bar, so the safe area
  /// grows by its height and the last rows of the list can be scrolled out from under it. It
  /// morphs in and out of the capsule only inside an animated change; the screen that owns it
  /// animates its coming and going.
  @ViewBuilder var accessory: () -> Accessory

  @Dependency(\.environment) private var environment
  @Dependency(\.store) private var store
  @Dependency(\.compute) private var compute
  /// Handed to the reimbursement sheet, which SwiftUI lays out in a host of its own.
  @Environment(\.dependencies) private var dependencies
  @FocusState private var focused: Bool

  @State private var text = ""
  @State private var showsDetails = false
  /// The caption above the line: why it was not saved, or what the panel asks for.
  @State private var message: EntryLineMessage?
  /// One keystroke of Return saves once, however many ways AppKit hands it over.
  @State private var returnGate = EntrySaving.ReturnGate()
  @State private var model: EntryDraftModel?
  /// Money back from a person, waiting in its confirmation.
  @State private var moneyBack: MoneyBackPrefill?
  /// The payment form of a debt the money back repays in another currency than the debt's:
  /// waiting for the confirmation to close, then open.
  @State private var pendingRepayment: DebtSheet?
  @State private var repayment: DebtSheet?
  /// «Это было до сверки в 14:05?», waiting for the owner's answer before the save goes on.
  @State private var countQuestion: BeforeTheCountQuestion?
  /// The picker of purchases a refund takes money back from, while it is open.
  @State private var refundRequest: RefundPickerRequest?
  /// The chips under the line.
  @State private var templates = TemplatesModel()
  @Namespace private var glass

  private var interpreter: any LineInterpreter {
    CoreLineInterpreter(vocabulary: environment.vocabulary, calendar: environment.calendar)
  }

  var body: some View {
    GlassEffectContainer(spacing: 12) {
      VStack(alignment: .leading, spacing: EntryBarMetrics.spacing) {
        TemplatesStrip(
          model: templates,
          currencyOf: { Templates.currency(of: $0, in: environment, model: model) }
        ) { template in
          text = templateLine(for: template)
          focused = true
        }

        accessory()
          .glassEffectID("accessory", in: glass)

        GlassCapsule {
          HStack(spacing: 10) {
            Image(systemName: "plus.circle")
              .foregroundStyle(.secondary)
            TextField(
              text: $text,
              prompt: Text(verbatim: environment.language("entry.placeholder", table: "Entry"))
            ) {
              Text(verbatim: environment.language("entry.amount", table: "Entry"))
            }
            .textFieldStyle(.plain)
            .focused($focused)
            .accessibilityIdentifier("entry.line")
            .onSubmit(save)
            // ↓ opens the panel only while the line has focus: a window-wide shortcut
            // would swallow arrow keys meant for the list.
            .onKeyPress(.downArrow) { press(.down) }
            .onKeyPress(.upArrow) { press(.up) }
            // Esc closes the panel and keeps the draft. With the panel closed it is not
            // ours, so it goes on to whatever else wants it.
            .onKeyPress(.escape) { press(.escape) }
            // Tab with the panel open goes to the first field of the owner's order, Shift-Tab
            // to the last; with the panel closed Tab is the window's, as before.
            .onKeyPress(keys: [.tab, PanelTabOrder.backTab]) { key in tab(key) }

            Button(action: toggleDetails) {
              Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                // The closed panel still holds choices the next line will keep: a dot says
                // so, and the help and VoiceOver say what it means.
                .overlay(alignment: .topTrailing) {
                  if carriesChoices {
                    Circle()
                      .fill(.tint)
                      .frame(width: 6, height: 6)
                      .offset(x: 5, y: -3)
                      .accessibilityHidden(true)
                  }
                }
            }
            .buttonStyle(.glass)
            .help(
              environment.language(
                carriesChoices ? "entry.detailsCarried" : "entry.details", table: "Entry")
            )
            .accessibilityValue(
              Text(
                verbatim: carriesChoices
                  ? environment.language("entry.detailsCarried", table: "Entry") : "")
            )
            .accessibilityIdentifier("entry.details.toggle")

            Button(environment.language("entry.save", table: "Entry"), action: save)
              .buttonStyle(.glassProminent)
              // While the panel is open Return saves wherever the focus is — a menu, the date,
              // a checkbox — as Enter in the line does. An open menu takes Return itself.
              .keyboardShortcut(showsDetails ? .defaultAction : nil)
              .disabled(!EntrySaving.isOffered(line: text, showsDetails: showsDetails))
          }
        }
        .glassEffectID("capsule", in: glass)
        // Above the capsule, not under it: the capsule keeps its place at the bottom of the
        // window while the result of a formula or an error comes and goes. It hangs over the
        // capsule instead of standing in the stack so that it adds nothing to the height —
        // otherwise the list would be nudged by every keystroke that changes what a formula
        // comes to.
        .overlay(alignment: .top) { standing(above: caption) }
      }
      // The ↓ panel stands above the whole bar and adds nothing to its height either. The
      // room the list keeps under the bar is the safe area's, and the safe area takes it from
      // what stands in this stack — a panel counted in would shove the whole list down the
      // moment somebody pressed ↓. It stays inside the same `GlassEffectContainer`, so it
      // still morphs out of the capsule.
      .overlay(alignment: .top) {
        standing(above: Group { if showsDetails, let model { detailsPanel(model) } })
      }
    }
    // One width for the panel, the chips and the capsule together: bounding them
    // separately would make the morph jump as the panel opens.
    .frame(
      width: EntryBarMetrics.columnWidth(windowWidth: windowWidth, detailWidth: detailWidth)
    )
    // The space the last row of the list keeps above the bar, and the space the bar keeps
    // above the bottom of the window. Together with the bar itself they are the whole of the
    // safe area it asks for.
    .padding(.top, EntryBarMetrics.contentGap)
    .padding(.bottom, EntryBarMetrics.bottomInset)
    .onAppear {
      focused = true
      prepareModel()
      templates.attach(environment.references)
      if opensDetails { showsDetails = true }
    }
    .onReceive(NotificationCenter.default.publisher(for: .focusEntryLine)) { _ in
      startNewOperation()
    }
    // Goals and debts made in Planning or Debts belong in the pickers of the ↓ panel at once
    // (review of the app, 19.09): read again when the panel opens and after each write. The
    // defaults are laid as it opens too: an operation entered in the panel alone never passes
    // through the line, and is not saved without the default payment method.
    .onChange(of: showsDetails) { _, shown in
      if shown { model?.prepareForPanel(today: environment.today) }
    }
    .onChange(of: compute.generation) { _, _ in
      if showsDetails { model?.reload() }
      // The chips too: a restore or an archive brought in replaces them.
      templates.reload()
    }
    // Cancelled, the confirmation leaves the line as it was; recorded, it clears it like a
    // save. A person who owes nothing, or owes on a debt, sends the money back to the line as
    // income or as that debt's repayment.
    .sheet(
      item: $moneyBack,
      onDismiss: {
        // One sheet at a time: the payment form of the debt opens once the confirmation is gone.
        repayment = pendingRepayment
        pendingRepayment = nil
      }
    ) { prefill in
      MoneyBackConfirmSheet(
        prefill: prefill,
        recordAsIncome: { recordMoneyBack(.income, from: $0) },
        recordAsDebtRepayment: { recordMoneyBack(.debtRepayment($0), from: $1) },
        recorded: { if let model { finishSaving(model) } }
      )
      .handingOver(dependencies)
    }
    // Written there, the repayment clears the line like a save; cancelled, the line stays.
    .sheet(item: $repayment) { form in
      DebtSheetView(sheet: form, onDone: { if let model { finishSaving(model) } })
        .handingOver(dependencies)
    }
    // The ↓ panel asks for the picker through the model: read here, in the body, so the ask
    // is seen, and handed to the sheet.
    .onChange(of: model?.refundPicking) { _, request in
      guard let request else { return }
      model?.refundPicking = nil
      refundRequest = request
    }
    // A refund picks the purchase it takes money back from; asked by Enter, the save goes on
    // once one is picked — or «Без покупки».
    .sheet(item: $refundRequest) { request in
      if let model {
        RefundPicker(entry: model) {
          guard request.savesAfterChoice else { return }
          Task { @MainActor in commit(model) }
        }
        .handingOver(dependencies)
      }
    }
    // The answers date the operation before or after each count of its day, and the save
    // goes on at the moment they give.
    .beforeTheCountQuestions($countQuestion) { moment in
      guard let model else { return }
      model.stampCount(moment)
      commit(model)
    }
  }

  /// Money back of a person who owes nothing is income; of one who owes on a debt, that debt's
  /// repayment. The line saves it that way at once, as the confirmation held it: a repayment of
  /// a debt kept in another currency comes already in the debt's currency, at the rate the
  /// confirmation showed, with the money as the account received it — and like every repayment
  /// it closes the debt once covered, the rest income in «Доплаты» (`EntrySave`). Only money the
  /// confirmation could not convert — an account that holds the debt's currency — opens the
  /// payment form of the debt instead, on the account the money came to.
  private func recordMoneyBack(
    _ route: EntryDraftModel.MoneyBackInstead, from sheet: TransactionDraft
  ) {
    guard let model else { return }
    if case .debtRepayment(let debtId) = route,
      let form = MoneyBackConfirmation.repaymentForm(
        of: debtId, money: Money(amount: sheet.amount, currency: sheet.currency),
        account: sheet.paymentMethodId,
        among: (try? environment.references?.debts()) ?? model.debts)
    {
      pendingRepayment = form
      return
    }
    model.recordMoneyBackInstead(
      route, from: sheet,
      fromNote: { environment.language.format("moneyBack.fromNote", table: "Entry", $0) },
      today: environment.today)
    // The owner has just confirmed a form: nothing more is asked about the category.
    Task { @MainActor in commit(model, askingForGaps: false) }
  }

  /// Hangs a view over the top edge of whatever it is put on, one `spacing` clear of it, and
  /// takes none of its height. The alignment guide is what does it: an overlay aligned `.top`
  /// puts its own top guide on the content's top edge, so a top guide redefined to be the
  /// overlay's own bottom edge leaves the overlay standing above.
  private func standing(above view: some View) -> some View {
    view
      .frame(maxWidth: .infinity, alignment: .leading)
      // The overlay is proposed the height of what it hangs over; the panel is far taller and
      // must take the height it asks for instead of being squeezed into that proposal.
      .fixedSize(horizontal: false, vertical: true)
      .alignmentGuide(.top) { $0[.bottom] + EntryBarMetrics.spacing }
  }

  /// The ↓ panel: the same fields the edit sheet shows, on glass of its own above the capsule.
  private func detailsPanel(_ model: EntryDraftModel) -> some View {
    GlassPanel {
      VStack(alignment: .leading, spacing: 4) {
        // A row of its own above the fields: laid over them, the button covered the
        // controls at the right end of the first row. It belongs to the floating
        // panel, not to `DetailsPanel`: the edit sheet shows the same fields and has
        // buttons of its own.
        HStack {
          Spacer()
          closeButton
        }
        ScrollView {
          // Return in a field of the panel saves, as Return in the line does.
          DetailsPanel(model: model, submit: save)
            .padding(.trailing, 4)
        }
        .frame(maxHeight: 420)
      }
      // Esc while a control inside the panel has focus. Esc on the line itself is
      // handled by the line, so neither reaches the list behind.
      .onExitCommand(perform: closeDetails)
    }
    .glassEffectID("details", in: glass)
  }

  @ViewBuilder
  private var caption: some View {
    if let message, message.isError {
      Text(verbatim: message.text(environment))
        .font(.caption)
        .foregroundStyle(.red)
        .padding(.horizontal, 14)
        .accessibilityIdentifier("entry.caption")
    } else if let message {
      // A question, not an error: a symbol and words, in the secondary colour.
      Label {
        Text(verbatim: message.text(environment))
      } icon: {
        Image(systemName: "exclamationmark.circle")
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 14)
      .accessibilityIdentifier("entry.caption")
    } else if let preview {
      // "Результат виден сразу": the amount a formula comes to, before Enter.
      Text(verbatim: preview)
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
    }
  }

  /// A plain button: the panel is glass already, and glass is never put on glass.
  private var closeButton: some View {
    Button(action: closeDetails) {
      Image(systemName: "xmark")
    }
    .buttonStyle(.borderless)
    .help(environment.language("action.close"))
    .accessibilityLabel(Text(verbatim: environment.language("action.close")))
    .accessibilityIdentifier("entry.details.close")
  }

  private func toggleDetails() {
    if showsDetails {
      closeDetails()
    } else {
      prepareModel()
      withAnimation(.snappy) { showsDetails = true }
    }
  }

  /// «+» in the toolbar and ⌘N: a new operation.
  ///
  /// Asking for the focus was all this used to do, and the line holds that focus already —
  /// the bar takes it the moment it appears, and a click on a toolbar button does not take
  /// it away. A `@FocusState` set to the value it already holds changes nothing, so «+» drew
  /// nothing at all and the owner reported a dead button (21.09). A new operation therefore
  /// opens the ↓ panel — the same whole form ↓ opens — which is something to see.
  ///
  /// Opened, never toggled: ⌘N twice in a row must not close the form it just opened.
  ///
  /// The focus is asked for twice, the way ⌘F asks for the search field
  /// (`TransactionsRootView.takeSearchFocus`): a click on a toolbar can move the first
  /// responder on its way in, after the action has already run.
  private func startNewOperation() {
    message = nil
    prepareModel()
    if !showsDetails { withAnimation(.snappy) { showsDetails = true } }
    focused = true
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(150))
      focused = true
    }
  }

  /// Tab and Shift-Tab of the line: into the panel while it is open.
  private func tab(_ key: KeyPress) -> KeyPress.Result {
    guard showsDetails, let model else { return .ignored }
    let backwards = key.key == PanelTabOrder.backTab || key.modifiers.contains(.shift)
    model.focusRequest = backwards ? .last : .first
    return .handled
  }

  private func press(_ key: DetailsPanelKey) -> KeyPress.Result {
    // While Enter's stop for a category stands, ↓ and ↑ choose in the menu it asked for: the
    // panel is open already, and without «Навигация с клавиатуры» the focus never reaches a menu.
    if showsDetails, key != .escape, let model,
      model.stepTheAskedMenu(by: key == .down ? 1 : -1, today: environment.today)
    {
      return .handled
    }
    let outcome = key.outcome(showing: showsDetails)
    guard outcome.handled else { return .ignored }
    if outcome.showing {
      prepareModel()
      withAnimation(.snappy) { showsDetails = true }
    } else {
      closeDetails()
    }
    return .handled
  }

  /// Closing only hides the panel: the draft stays for the next ↓, and typing goes on in
  /// the line.
  private func closeDetails() {
    withAnimation(.snappy) { showsDetails = false }
    focused = true
  }

  /// The panel is closed over a draft whose choices the next line will keep (Esc keeps the
  /// draft): the ↓ button shows a dot.
  private var carriesChoices: Bool {
    !showsDetails && (model?.carriesChoices ?? false)
  }

  /// What the line currently comes to, shown above the capsule while it is being typed.
  /// Only a formula is worth showing, a number not written the way the app writes numbers —
  /// «1500,5 = 1,500.50 ₽», «0,500 = 0.50 ₽» — and a point that may be taken for thousands,
  /// «1.500 = 1.50 ₽». A plain «250» or «1,500» already reads as itself.
  private var preview: String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let parsed = interpreter.interpret(trimmed, today: environment.today)
    guard let expression = parsed.amountToPreview, let amount = parsed.amount,
      let value = try? AmountE4(decimal: amount)
    else { return nil }
    let currency = EntryPreview.currency(of: parsed, model: model, in: environment)
    return "\(expression) = \(environment.money.exact(value, currency: currency))"
  }

  private func prepareModel() {
    guard model == nil else { return }
    let model = EntryDraftModel(environment: environment)
    model.reload()
    self.model = model
  }

  private func save() {
    // Return may reach the save twice — the field's own action and the default button — and a
    // held Return repeats: one keystroke is one save.
    let event = NSApp.currentEvent
    let isRepeat = event?.type == .keyDown && event?.isARepeat == true
    guard returnGate.admits(now: ProcessInfo.processInfo.systemUptime, isRepeat: isRepeat) else {
      return
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    prepareModel()
    guard let model else { return }

    // An empty line with the panel open saves whatever the panel holds, or says why not.
    if trimmed.isEmpty {
      guard showsDetails else { return }
      if let refusal = model.saveRefusalKey {
        message = .error(refusal)
        return
      }
      commit(model)
      return
    }

    let parsed = interpreter.interpret(trimmed, today: environment.today, kind: model.draft.kind)
    // A day the calendar does not have is what was typed wrong: said before anything else.
    if let problem = parsed.dateProblem {
      message = .date(problem)
      return
    }
    // A line of words alone, with the panel open over an amount, saves that amount: Return saves
    // what the panel shows. A number in the line that does not read is refused all the same.
    let takesThePanelAmount =
      parsed.amount == nil && parsed.amountProblem == nil && showsDetails
      && model.draft.amount.raw > 0
    guard parsed.amount != nil || takesThePanelAmount else {
      message = .error(parsed.missingAmountErrorKey)
      return
    }

    do {
      let amount = try parsed.amount.map { try AmountE4(decimal: $0) } ?? model.draft.amount
      model.apply(parsed, amount: amount, today: environment.today, text: trimmed)
      if let refusal = model.saveRefusalKey {
        message = .error(refusal)
        return
      }
      commit(model)
    } catch CoreError.divisionByZero {
      message = .error("entry.error.divisionByZero")
    } catch CoreError.amountOutOfRange {
      message = .error("entry.error.amountTooLarge")
    } catch {
      message = .error("entry.error.badExpression")
    }
  }

  private func templateLine(for template: Template) -> String {
    prepareModel()
    return Templates.line(
      for: template, categories: (model?.categories ?? []) + (model?.archivedCategories ?? []),
      in: environment, model: model)
  }

  /// Nothing the owner typed is thrown away unless the operation really reached the
  /// database: a failed write used to look exactly like a successful one — the line cleared
  /// itself, the panel closed, and there was no operation.
  ///
  /// `askingForGaps`: a line that did not say the category — or whose subcategory the model
  /// left open — stops once and opens the panel on that field (`gapToAsk`); false where the
  /// owner has just confirmed a form.
  private func commit(_ model: EntryDraftModel, askingForGaps: Bool = true) {
    // A date nobody chose is now, not when the draft was made; first, so the
    // rate is the one of the day the operation lands on.
    model.takeTheMomentOfSaving()
    // Asked again on every way into the save — after the picker of purchases, after the
    // question about the count, after the confirmation of money back: what they changed may
    // stop it (a purchase whose account needs «Списано со счёта» typed). The panel opens on
    // a reason it shows.
    if let refusal = model.saveRefusalKey {
      message = .error(refusal)
      if model.shownRefusalKey != nil, !showsDetails {
        withAnimation(.snappy) { showsDetails = true }
      }
      return
    }
    // A refund first says which purchase it takes money back from — or that it has none.
    if model.needsRefundPurchase {
      message = nil
      refundRequest = RefundPickerRequest(savesAfterChoice: true)
      return
    }
    // The line did not say where the money goes: nothing is saved yet, the panel opens on the
    // field, marked, and the next Return saves the operation as it stands then.
    if askingForGaps, let gap = model.gapToAsk() {
      message = .gap(gap)
      model.focusRequest = .control(gap == .category ? .category : .subcategory)
      if !showsDetails { withAnimation(.snappy) { showsDetails = true } }
      AppLog.info(
        "entry.gapAsked", .ui, "Enter asked for a field before saving",
        [LogPair("field", .token(gap.rawValue))])
      return
    }
    // Dated on the day of counts of its balances and saved after them: whether its money was
    // already counted is asked about each count of the day, oldest first, before anything is
    // written. An answer remembered for a count («Больше не спрашивать для этой сверки») is used
    // without a question.
    switch model.countAsk(
      savedAt: Date(), balances: compute.snapshot?.planning.accounts.balances ?? .empty,
      remembered: environment.rememberedCountAnswers())
    {
    case .none:
      break
    case .answered(let stamp):
      model.stampCount(stamp)
    case .ask(let questions):
      countQuestion = BeforeTheCountQuestion(
        count: questions.count, reconciliation: questions.reconciliation, questions: questions)
      return
    }
    // Money back from a person closes parts, and which ones the confirmation shows: nothing
    // is written here. Its rate and what the account received are worked out there.
    if model.recordsThroughReimbursementSheet {
      message = nil
      // Laid as a save lays it, which also asks the bank for the rate of the day when the cache
      // has none yet: the confirmation works it out again once it came.
      var money = model.draftForSaving
      environment.applyRate(to: &money)
      moneyBack = MoneyBackPrefill(draft: money)
      return
    }
    do {
      guard let written = try EntrySave.write(model, environment: environment, store: store)
      else {
        message = .error("entry.error.notSaved")
        return
      }
      CategoryLearning.saved(
        written.entry, choice: model.categoryChoice(), environment: environment)
      if written.openedCredit != nil || written.paidDebt != nil { model.reload() }
      // A debt opened by this purchase is a name the line should know next time.
      if written.openedCredit?.isNew == true { environment.refreshVocabulary() }
      templates.remember(model.draft, categories: model.categories + model.archivedCategories)
      finishSaving(model)
    } catch {
      message = .error(EntryCommit.errorKey(of: error))
    }
  }

  /// The operation went in — here, or in the reimbursement sheet: the line, the panel and the
  /// draft start over.
  private func finishSaving(_ model: EntryDraftModel) {
    model.reset()
    // A rating just given by hand is history now (rule 2 of the qualities): the next
    // operation described the same way should find it.
    model.reload()
    text = ""
    message = nil
    withAnimation(.snappy) { showsDetails = false }
    // The field of the panel that had the focus — Return in it, or «Save» clicked while it
    // was being typed in — goes with the panel: without this the window kept no first
    // responder and the next line was typed into nothing. `closeDetails` does the same.
    focused = true
  }
}

extension Notification.Name {
  static let focusEntryLine = Notification.Name("io.github.EvgenyBaulin.itogo.focusEntryLine")
}

/// The write of the entry line, once nothing is left to ask: the rate of the day, what the
/// account was charged, the operation and everything it moves — a debt opened for it, the line of
/// a debt it pays, the income over a debt owed to me, the link to an expected income — in one
/// write, so one ⌘Z takes all of it back.
@MainActor
enum EntrySave {
  /// What went in.
  struct Written {
    var entry: TransactionEntry
    /// The debt a purchase on credit opened or joined.
    var openedCredit: (debt: Debt, isNew: Bool)?
    /// The debt the operation pays or grows.
    var paidDebt: Debt?
  }

  /// Writes the draft of `model`. `nil` when the database did not take the write; a throw
  /// when the draft cannot be written as it is (`EntryCommit.errorKey` words it).
  static func write(
    _ model: EntryDraftModel, environment: AppEnvironment, store: TransactionsStore
  ) throws -> Written? {
    // A refund of a purchase keeps the purchase's rate: `applyRate` leaves it alone.
    environment.applyRate(to: &model.draft)
    // «Списано со счёта» follows the rate the save has just laid.
    model.refreshCharge()
    // The conversion is tried before anything is written, so a missing rate cannot leave
    // a debt behind that nothing bought. A refund of a purchase is in the purchase's rubles,
    // checked against what is left of it now.
    let convert =
      model.refundTarget == nil
      ? environment.rublesConverter(for: model.draft)
      : try model.refundRubles(index: model.refundIndexNow())
    _ = try convert(model.draft.amount)
    let credit = openCreditIfNeeded(model, environment: environment)
    // What the kind has no field for stays out of what is written.
    let entry = try model.draftForSaving.materialize(rublesConverter: convert)
    let paidDebt = model.debtPaid(by: entry)
    let repayment = repaymentSetting(of: paidDebt, by: entry, environment: environment)
    let saved: Bool
    if let change = try EntryCommit.change(
      entry: entry, openedCredit: credit?.debt, creditIsNew: credit?.isNew ?? false,
      paidDebt: paidDebt, expectedIncomeId: model.expectedIncomeId,
      day: environment.calendar.day(of: model.draft.occurredAt),
      paidDebtBalance: repayment?.balance, surplus: repayment?.surplus)
    {
      saved = store.apply(change)
    } else {
      saved = store.save(entry)
    }
    guard saved else { return nil }
    return Written(entry: entry, openedCredit: credit, paidDebt: paidDebt)
  }

  /// Money given back on a debt owed to me follows the one rule of repayments
  /// (`DebtRules.repayment`), as the debt's own form and the money-back sheet do: the journal
  /// takes what is left of the debt as it is read now, the debt closes once it is covered, and
  /// what came back above it is income in «Доплаты» — without that category the save is refused.
  /// Only money back: an income that names such a debt is income already, all of it, and a
  /// surplus written beside it would count its money twice — it pays the debt as it always did.
  static func repaymentSetting(
    of debt: Debt?, by entry: TransactionEntry, environment: AppEnvironment
  ) -> (balance: AmountE4, surplus: EntryCommit.SurplusSetting)? {
    guard let debt, debt.direction == .owedToMe, entry.transaction.kind == .reimbursement,
      let references = environment.references,
      let journal = try? references.debtEntries(debtId: debt.id)
    else { return nil }
    let surcharges = (try? references.category(systemRole: .surcharges, kind: .income))?.id
    return (
      DebtRules.balance(entries: journal),
      EntryCommit.SurplusSetting(
        categoryId: surcharges,
        note: environment.language("reimbursement.surplus", table: "Entry"))
    )
  }

  /// "On credit" means the expense is recorded once, now, and the debt grows by the same
  /// amount; later payments only reduce the debt, so nothing is counted twice.
  ///
  /// Only a purchase has a plan to open with (`EntryDraftModel.offersCredit`). A plan left on
  /// an income or a refund is refused before this (`saveRefusalKey`), and is handed on all the
  /// same should it get here: `EntryCommit` refuses it with a reason rather than saving the
  /// operation without the debt the owner asked for, or with one nothing bought.
  private static func openCreditIfNeeded(
    _ model: EntryDraftModel, environment: AppEnvironment
  ) -> (debt: Debt, isNew: Bool)? {
    guard let plan = model.creditPlan else { return nil }

    if let chosen = plan.debtId, let existing = model.debts.first(where: { $0.id == chosen }) {
      model.draft.creditDebtId = existing.id
      return (existing, false)
    }

    // A debt of its own for this purchase: its payments are not expenses, because the
    // expense is this very operation. It is written with the purchase, not before it.
    // The count of payments chosen is in the instalment: a debt is paid off in ⌈balance ÷
    // monthly payment⌉ months, and keeps no term of its own.
    let debt = Debt(
      direction: .iOwe,
      type: .installment,
      name: model.draft.note ?? environment.language("entry.onCredit", table: "Entry"),
      currency: model.draft.currency,
      monthlyPaymentE4: plan.monthlyAmount.isZero ? nil : plan.monthlyAmount,
      paymentsAreExpenses: false,
      origin: .purchase)
    model.draft.creditDebtId = debt.id
    return (debt, true)
  }
}

/// What a key of the entry line does to the ↓ panel, apart from the view so a test reads it
/// without a window: ↓ opens it, ↑ and Esc close it (the draft stays), and with the panel
/// closed ↑ and Esc are not ours and go on to whatever else wants them. The × of the panel
/// and Esc inside it close it the same way (`closeDetails`).
/// When the bar saves («Сохранение — Enter»): a line to read, or the ↓ panel open. «Save» is
/// active exactly then, and Return — in the line, or anywhere in the open panel — saves the
/// same way (`EntryBar.save`), with the save or with the reason there is none: a Return that
/// does nothing is what the owner reported.
enum EntrySaving {
  static func isOffered(line: String, showsDetails: Bool) -> Bool {
    showsDetails || !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// One keystroke, one save. AppKit may hand one Return both to a text field's action and to
  /// the default button, and a held Return repeats; a refused save must still be retried by the
  /// next Return, so a flag cannot do this.
  struct ReturnGate {
    /// Seconds within which a second request is the same keystroke handed over twice. A person
    /// presses Return again no sooner than a fifth of a second later.
    static let window: TimeInterval = 0.15
    private(set) var lastAdmitted: TimeInterval?

    /// `now`: `ProcessInfo.processInfo.systemUptime`; `isRepeat`: the key event is an
    /// auto-repeat of a held key (false for a click, or a save asked by code).
    mutating func admits(now: TimeInterval, isRepeat: Bool) -> Bool {
      guard !isRepeat else { return false }
      if let lastAdmitted, now - lastAdmitted < Self.window, now >= lastAdmitted { return false }
      lastAdmitted = now
      return true
    }
  }
}

enum DetailsPanelKey {
  case down, up, escape

  func outcome(showing: Bool) -> (showing: Bool, handled: Bool) {
    switch self {
    case .down: (true, true)
    case .up, .escape: showing ? (false, true) : (false, false)
    }
  }
}

/// The preview above the entry line.
enum EntryPreview {
  /// The currency the save gives a line, for the preview above it. With the line's panel it is
  /// the panel's own answer (`EntryDraftModel.currencyOnSaving`), which follows the save step by
  /// step. Without one — before the line made its panel — a fresh draft would save: the one
  /// typed; else the main currency of the account the line names; else the one the line reads
  /// an amount without a code in — the currency of the account whose screen is open, or the
  /// default one.
  @MainActor static func currency(
    of parsed: ParsedInput, model: EntryDraftModel?, in environment: AppEnvironment
  ) -> CurrencyCode {
    if let model { return model.currencyOnSaving(parsed) }
    if let typed = parsed.currency { return typed }
    if let named = parsed.paymentMethodId,
      let account = ((try? environment.references?.paymentMethods()) ?? nil)?
        .first(where: { $0.id == named })
    {
      return account.mainCurrency
    }
    return Templates.lineCurrency(in: environment)
  }
}
