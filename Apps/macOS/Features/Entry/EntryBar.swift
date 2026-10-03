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
  /// How a new operation is filled in (`EntryStyle`): the floating line with the ↓ panel above
  /// it, or the form of every field in a column of its own — no line, no suggestions, the panel
  /// always open and saved with its own button.
  var style: EntryStyle = .line
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
  /// A field of the form has the keyboard: «Save» answers Return then, and only then — the rest
  /// of the time Return belongs to whatever else in the window has the focus.
  @State private var formFocused = false
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
  /// «Такая же операция уже записана — добавить ещё?», waiting for the owner's answer.
  @State private var repeatQuestion: RepeatQuestion?
  /// «Запись или план?» for an operation dated after today, waiting for the owner's answer.
  @State private var aheadQuestion: AheadQuestion?
  /// The transfer sheet «Перевести…» of the panel opened, while it is open.
  @State private var transfer: TransferRequest?
  /// The chips under the line.
  @State private var templates = TemplatesModel()
  @Namespace private var glass

  private var interpreter: any LineInterpreter {
    CoreLineInterpreter(vocabulary: environment.vocabulary, calendar: environment.calendar)
  }

  var body: some View {
    Group {
      switch style {
      case .line: lineBody
      case .form: formBody
      }
    }
    .onAppear {
      focused = style == .line
      prepareModel()
      templates.attach(environment.references)
      if opensDetails || style == .form { showsDetails = true }
    }
    .onReceive(NotificationCenter.default.publisher(for: .focusEntryLine)) { _ in
      startNewOperation()
    }
    // ↑ on the newest row of the list, or Esc in it: the keyboard comes back to the line.
    .onReceive(NotificationCenter.default.publisher(for: .returnToEntryLine)) { _ in
      focused = style == .line
    }
    // Goals and debts made in Planning or Debts belong in the pickers of the ↓ panel at once
    // (review of the app, 19.09): read again when the panel opens and after each write. The
    // defaults are laid as it opens too: an operation entered in the panel alone never passes
    // through the line, and is not saved without the default payment method.
    .onChange(of: showsDetails) { _, shown in
      guard shown else { return }
      model?.prepareForPanel(today: environment.today)
      readTheLineIntoThePanel()
    }
    // The open panel shows what the line says as it is typed, not only after Enter. The notice
    // that an operation became a plan has said what it had to: the next line starts clean.
    .onChange(of: text) { _, _ in
      if case .planned = message { message = nil }
      readTheLineIntoThePanel()
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
    // «Перевести…» of the panel: the sheet of a transfer started with what the panel holds. Once
    // a transfer is written the line and the panel start over; cancelled, they stay as they were.
    .sheet(item: $transfer) { request in
      TransferSheet(form: request.form) { written in
        transfer = nil
        if written, let model { finishSaving(model) }
      }
      .handingOver(dependencies)
    }
    // Two questions before a new operation is written, each on a view of its own: a record or a
    // plan, for a date after today; and «такая же уже записана», for a repeat of the last minutes.
    .background {
      Color.clear.confirmationDialog(
        aheadQuestion.map { $0.title(environment) } ?? "",
        isPresented: Binding(
          get: { aheadQuestion != nil }, set: { if !$0 { aheadQuestion = nil } }),
        titleVisibility: .visible, presenting: aheadQuestion
      ) { question in
        Button(environment.language("entry.ahead.record", table: "Entry")) { recordAhead() }
        Button(environment.language(question.planKey, table: "Entry")) { makeAPlan(of: question) }
        Button(environment.language("action.cancel"), role: .cancel) {}
      } message: { _ in
        Text(verbatim: environment.language("entry.ahead.message", table: "Entry"))
      }
    }
    .background {
      Color.clear.confirmationDialog(
        environment.language("entry.repeat.title", table: "Entry"),
        isPresented: Binding(
          get: { repeatQuestion != nil }, set: { if !$0 { repeatQuestion = nil } }),
        titleVisibility: .visible, presenting: repeatQuestion
      ) { _ in
        Button(environment.language("entry.repeat.add", table: "Entry")) { addTheRepeat() }
        Button(environment.language("entry.repeat.skip", table: "Entry"), role: .cancel) {}
      } message: { question in
        Text(verbatim: question.message(environment))
      }
    }
  }

  /// «Очистить» of the form: what was typed is dropped and the defaults are laid again.
  private func clearTheForm() {
    guard let model else { return }
    model.reset()
    model.reload()
    model.prepareForPanel(today: environment.today)
    message = nil
    model.focusRequest = .first
  }

  /// «Перевести…»: the transfer sheet with what the panel holds — the amount, its currency, the
  /// account, the day and the note (`TransferForm.init(fromThePanel:…)`).
  private func startTransfer() {
    guard let model else { return }
    transfer = TransferRequest(
      form: TransferForm(
        fromThePanel: model.draft, account: model.selectedAccount,
        accounts: model.paymentMethods, calendar: environment.calendar))
  }

  /// «Записать как есть»: the operation dated ahead is written on its date; the question is not
  /// asked again for it.
  private func recordAhead() {
    guard let model else { return }
    AppLog.info("entry.aheadRecorded", .ui, "an operation dated ahead was recorded as it is")
    model.aheadAnswered = true
    continueSaving(model)
  }

  /// The plan the question offered, written instead of the operation — one step of ⌘Z — and the
  /// line cleared; a plan that was not written leaves the line as it was.
  private func makeAPlan(of question: AheadQuestion) {
    guard let model, let dependencies else { return }
    let actions = PlanningActions(dependencies)
    let saved: Bool
    switch question.plan {
    case .payment:
      let name =
        model.planName ?? environment.language("entry.ahead.payment", table: "Entry")
      saved = actions.save(model.plannedPayment(named: name), previous: nil)
    case .income:
      let name =
        model.planName ?? environment.language("entry.ahead.income", table: "Entry")
      saved = actions.save(model.plannedIncome(named: name))
    }
    guard saved else {
      message = .error("entry.error.notSaved")
      return
    }
    AppLog.info(
      "entry.aheadPlanned", .ui, "an operation dated ahead became a plan",
      [LogPair("plan", .token("\(question.plan)"))])
    finishSaving(model, then: .planned(question.plan, question.day))
  }

  /// «Добавить»: the repeat is written; the question is not asked again for it.
  private func addTheRepeat() {
    guard let model else { return }
    AppLog.info("entry.repeatAdded", .ui, "a repeat of an operation just written was added")
    model.repeatConfirmed = true
    continueSaving(model)
  }

  /// The save goes on after the dialog that asked has gone: the next question it may ask — the
  /// counts of the day — is presented by a window that has just closed one, and a window takes
  /// the next only once the first is gone.
  private func continueSaving(_ model: EntryDraftModel) {
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(300))
      commit(model)
    }
  }

  /// The floating glass capsule with the chips above it and the ↓ panel over them.
  private var lineBody: some View {
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
            // ↓ walks the list of operations from the newest, and only while the line has
            // focus: a window-wide shortcut would swallow arrow keys meant for the list.
            // It opens nothing — the panel opens with Tab and the chevron.
            .onKeyPress(.downArrow) { press(.down) }
            .onKeyPress(.upArrow) { press(.up) }
            // Esc closes the panel and keeps the draft. With the panel closed it is not
            // ours, so it goes on to whatever else wants it.
            .onKeyPress(.escape) { press(.escape) }
            // Tab opens the panel and goes to the first field of the owner's order, and with the
            // panel open it goes there too, Shift-Tab to the last; with the panel closed
            // Shift-Tab is the window's.
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
  }

  /// The form at the side of the window (`EntryStyle.form`): every field of the panel, always
  /// open, with a button of its own to save and one to clear. No line, no chips, no suggestions.
  private var formBody: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(verbatim: environment.language("entry.form.title", table: "Entry"))
          .font(.headline)
        Spacer()
        Button(environment.language("entry.form.clear", table: "Entry"), action: clearTheForm)
          .buttonStyle(.borderless)
          .accessibilityIdentifier("entry.form.clear")
      }
      if let model {
        ScrollView {
          DetailsPanel(
            model: model, submit: save, onTransfer: startTransfer, focusedInside: $formFocused
          )
          .padding(.trailing, 4)
        }
      } else {
        Spacer()
      }
      caption
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack {
        Spacer()
        Button(environment.language("entry.save", table: "Entry"), action: save)
          .buttonStyle(.borderedProminent)
          // Return saves from any field of the form — a menu, the date, a checkbox — while the
          // focus is in it; with the focus in the list beside it Return is the list's.
          .keyboardShortcut(formFocused ? .defaultAction : nil)
          .accessibilityIdentifier("entry.form.save")
      }
    }
    .padding(14)
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
          DetailsPanel(model: model, submit: save, onTransfer: startTransfer)
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
        Image(systemName: message.symbol)
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
    // The form is always open: a new operation puts the keyboard on its first field.
    if style == .form {
      model?.focusRequest = .first
      return
    }
    if !showsDetails { withAnimation(.snappy) { showsDetails = true } }
    focused = true
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(150))
      focused = true
    }
  }

  /// Tab and Shift-Tab of the line: into the panel. Tab opens a closed panel on its first field;
  /// Shift-Tab with the panel closed is not ours.
  private func tab(_ key: KeyPress) -> KeyPress.Result {
    let backwards = key.key == PanelTabOrder.backTab || key.modifiers.contains(.shift)
    if !showsDetails {
      guard !backwards else { return .ignored }
      prepareModel()
      withAnimation(.snappy) { showsDetails = true }
    }
    guard let model else { return .ignored }
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
    // ↓ is the list's: it walks the operations from the newest and leaves the panel as it is.
    if key == .down {
      NotificationCenter.default.post(name: .walkOperationsList, object: nil)
      return .handled
    }
    let outcome = key.outcome(showing: showsDetails)
    guard outcome.handled else { return .ignored }
    if !outcome.showing { closeDetails() }
    return .handled
  }

  /// Closing only hides the panel: the draft stays for the next ↓, and typing goes on in
  /// the line.
  private func closeDetails() {
    // The form has no line to go back to, and nothing to close.
    guard style == .line else { return }
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

  /// The line read into the open panel at every change of it: the amount, the currency, the
  /// date, the place and the words show there, and the chips under «Категория» follow them —
  /// before Enter, which reads the line again and saves. What the owner chose in the panel
  /// itself stays over the line (`EntryDraftModel.apply`). A line that cannot be read yet — an
  /// unfinished formula, a day the calendar does not have — leaves the panel as it is: Enter says
  /// what is wrong with it.
  private func readTheLineIntoThePanel() {
    guard showsDetails, let model else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    let parsed = interpreter.interpret(trimmed, today: environment.today, kind: model.draft.kind)
    guard parsed.dateProblem == nil else { return }
    var amount = model.draft.amount
    if let typed = parsed.amount {
      guard let read = try? AmountE4(decimal: typed) else { return }
      amount = read
    }
    model.apply(parsed, amount: amount, today: environment.today, text: trimmed)
  }

  private func prepareModel() {
    guard model == nil else { return }
    let model = EntryDraftModel(environment: environment)
    model.assisted = style.assists
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
    // A date after today: a record, or a plan of Planning's? Asked once.
    if askingForGaps, let plan = model.planAhead(today: environment.today) {
      aheadQuestion = AheadQuestion(
        plan: plan, day: environment.calendar.day(of: model.draft.occurredAt))
      AppLog.info(
        "entry.aheadAsked", .ui, "an operation dated ahead was asked about",
        [LogPair("plan", .token("\(plan)"))])
      return
    }
    // What was written a moment ago with the same amount is shown before it is written again.
    if askingForGaps, let same = model.repeatedOperation() {
      repeatQuestion = RepeatQuestion(entry: same)
      AppLog.info("entry.repeatAsked", .ui, "a repeat of an operation just written was asked about")
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
  private func finishSaving(_ model: EntryDraftModel, then notice: EntryLineMessage? = nil) {
    model.reset()
    // A rating just given by hand is history now (rule 2 of the qualities): the next
    // operation described the same way should find it.
    model.reload()
    text = ""
    message = notice
    // The form stays open over a fresh draft, with the defaults laid as they are when a panel
    // opens; the line's panel closes.
    if style == .form {
      model.prepareForPanel(today: environment.today)
    } else {
      withAnimation(.snappy) { showsDetails = false }
    }
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
/// without a window: ↓ is the list's — it walks the operations from the newest and leaves the
/// panel as it is —, ↑ and Esc close an open panel (the draft stays), and with the panel closed
/// ↑ and Esc are not ours and go on to whatever else wants them. The × of the panel and Esc
/// inside it close it the same way (`closeDetails`).
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
    case .down: (showing, true)
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
