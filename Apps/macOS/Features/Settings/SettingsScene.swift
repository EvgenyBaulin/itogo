import AppCore
import AppDatabase
import AppKit
import SwiftUI

/// ⌘, — the settings, as System Settings shows its own: the sections in a sidebar with their
/// symbols and a search field above them, the section chosen on the right in a grouped form.
///
/// The search finds a section by its name or by the caption of a setting it holds, in either
/// language (`SettingsSearch`); under a section found by a setting the captions that matched
/// are listed, and a click on one opens the section. Return opens the first section found.
///
/// Whatever the settings open — an editor, the rules of cashback, the password of the lock, the
/// starter set — is a sheet on this very window, never something behind it in the main one.
struct SettingsView: View {
  let deps: AppDependencies

  init(deps: AppDependencies) {
    self.deps = deps
  }

  private var environment: AppEnvironment { deps.environment }
  @State private var navigation = SettingsNavigation.shared
  /// «Выбрать стартовый набор…» of «Основные»: the set, on a sheet over the settings.
  @State private var starterSet = SettingsStarterSet.shared

  /// The smallest the window may be made: the sidebar and a section beside it whose grouped
  /// form still holds a row of the accent circles and a category per row with its quality.
  static let minimumSize = CGSize(width: 850, height: 460)
  /// The size it opens at.
  static let idealSize = CGSize(width: 910, height: 620)
  /// The sidebar of the sections: the longest name, «Справочники», «Планирование», with its
  /// symbol, in either language.
  static let sidebarWidth: (min: CGFloat, ideal: CGFloat, max: CGFloat) = (180, 200, 260)

  var body: some View {
    NavigationSplitView {
      SettingsSidebar(navigation: navigation, environment: environment)
        .navigationSplitViewColumnWidth(
          min: Self.sidebarWidth.min, ideal: Self.sidebarWidth.ideal, max: Self.sidebarWidth.max)
    } detail: {
      SettingsSectionContent(section: navigation.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(environment.language(navigation.section.titleKey, table: "Settings"))
    }
    // The sidebar stays: a settings window without its sections is a window without a way on.
    .toolbar(removing: .sidebarToggle)
    // Room for what the sections hold — the row of accent circles, a category per row with its
    // quality — and a window that can be made larger still: a list of categories read through
    // a slot of 420 points is a list nobody reads.
    .frame(
      minWidth: Self.minimumSize.width, idealWidth: Self.idealSize.width, maxWidth: .infinity,
      minHeight: Self.minimumSize.height, idealHeight: Self.idealSize.height,
      maxHeight: .infinity
    )
    .background(ResizableSettingsWindow(minimum: Self.minimumSize))
    // So a UI test can say the settings really opened when the gear of the toolbar is pressed.
    .accessibilityIdentifier("settings.window")
    // «Справка» → «Собрать отчёт о проблеме…»: the report itself, not a section to look for it
    // in. A sheet is laid out by a host of its own: the dependencies are handed over.
    .sheet(
      isPresented: Binding(
        get: { environment.showsProblemReport },
        set: { environment.showsProblemReport = $0 })
    ) {
      ProblemReportSheet(height: 380).appDependencies(deps)
    }
    // The starter set asked from «Основные» comes over the settings, where it was asked: the
    // main window's sheet stood behind this window, out of sight.
    .sheet(
      isPresented: environment.lock.presenting(
        Binding(get: { starterSet.isUp }, set: { if !$0 { starterSet.isUp = false } }))
    ) {
      StarterSetSheet().appDependencies(deps)
    }
  }
}

/// What a section shows: the views of the ten tabs the settings had, each as it was.
struct SettingsSectionContent: View {
  let section: SettingsSection

  var body: some View {
    switch section {
    case .general: GeneralSettingsView()
    case .appearance: AppearanceSettingsView()
    case .currencies: CurrenciesSettingsView()
    case .accounts: AccountsSettingsView()
    case .categories: CategoriesSettingsView()
    case .references: ReferenceBooksView()
    case .entry: EntrySettingsView()
    case .templates: TemplatesSettingsView()
    case .planning: PlanningSettingsView()
    case .backups: BackupSettingsView()
    }
  }
}

/// The sections, and the search field above them. While a query is typed only the sections it
/// finds stay, each with the captions of the settings that matched.
struct SettingsSidebar: View {
  @Bindable var navigation: SettingsNavigation
  let environment: AppEnvironment
  /// The words of both languages, read once for the sidebar.
  @State private var words = SettingsSearch.catalogWords()

  var body: some View {
    let found = SettingsSearch.find(navigation.query, words: words)
    List(
      selection: Binding(
        get: { navigation.section },
        set: { if let section = $0 { navigation.section = section } })
    ) {
      ForEach(found, id: \.section) { found in
        Label {
          Text(verbatim: environment.language(found.section.titleKey, table: "Settings"))
        } icon: {
          Image(systemName: found.section.symbol)
        }
        .tag(found.section)
        .accessibilityIdentifier("settings.section.\(found.section.rawValue)")
        ForEach(found.captions, id: \.self) { caption in
          Button {
            navigation.section = found.section
          } label: {
            Text(verbatim: environment.language(caption.key, table: caption.table))
              .appFont(.callout)
              .foregroundStyle(.secondary)
              .lineLimit(2)
              .padding(.leading, 26)
              .frame(maxWidth: .infinity, alignment: .leading)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("settings.found.\(caption.key)")
        }
      }
      if found.isEmpty {
        Text(verbatim: environment.language("settings.search.nothing", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .listStyle(.sidebar)
    .searchable(
      text: $navigation.query, placement: .sidebar,
      prompt: Text(verbatim: environment.language("settings.search.prompt", table: "Settings"))
    )
    .onSubmit(of: .search) {
      if let first = found.first { navigation.section = first.section }
    }
    .accessibilityIdentifier("settings.sidebar")
  }
}

/// The starter set asked from Settings → «Основные»: a sheet of the settings window. Apart from
/// `StarterSetOffer`, which the main window reads for the sheet it asks on a new database.
@MainActor
@Observable
final class SettingsStarterSet {
  static let shared = SettingsStarterSet()
  var isUp = false

  /// «Выбрать стартовый набор…»: the set over the settings, the main window's offer untouched.
  func open() {
    isUp = true
  }
}

/// The corner of the settings window, to drag it larger. The Settings scene gives its window no
/// resizable frame, whatever `windowResizability` says — the window keeps the size of the tab
/// it opened on — so the window is reached from a view inside it and given one, with the
/// smallest size the tabs are laid out for. Nothing is measured and nothing is fed back into
/// the layout: the frame of the tabs follows the window, as in any other window.
private struct ResizableSettingsWindow: NSViewRepresentable {
  let minimum: CGSize

  func makeNSView(context: Context) -> NSView { Anchor(minimum: minimum) }
  func updateNSView(_ view: NSView, context: Context) {}

  private final class Anchor: NSView {
    let minimum: CGSize
    /// SwiftUI sets the frame of its settings window again whenever it updates the scene, and
    /// takes the corner away each time; it is given back at once.
    private var watch: NSKeyValueObservation?

    init(minimum: CGSize) {
      self.minimum = minimum
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      watch = nil
      guard let window else { return }
      Self.resizable(window, minimum: minimum)
      let minimum = minimum
      watch = window.observe(\.styleMask) { window, _ in
        MainActor.assumeIsolated { Self.resizable(window, minimum: minimum) }
      }
    }

    private static func resizable(_ window: NSWindow, minimum: CGSize) {
      if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
      let floor = window.contentMinSize
      if floor.width < minimum.width || floor.height < minimum.height {
        window.contentMinSize = CGSize(
          width: max(floor.width, minimum.width), height: max(floor.height, minimum.height))
      }
    }
  }
}

struct GeneralSettingsView: View {
  @Dependency(\.environment) private var environment
  /// A write the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false
  /// The people of the book, archived ones too, read when the tab appears and after each one
  /// is added.
  @State private var people: [Person] = []
  @State private var newPerson = ""
  #if !APPSTORE
    /// Read once when the tab is made; the switch is the only thing that changes it.
    @State private var automaticUpdates = AutomaticUpdates().isOn
  #endif

  var body: some View {
    @Bindable var language = environment.language
    Form {
      Picker(selection: $language.choice) {
        ForEach(AppLanguage.Choice.allCases, id: \.self) { choice in
          Text(verbatim: environment.language(choice.settingsKey, table: "Settings"))
            .tag(choice)
        }
      } label: {
        Text(verbatim: environment.language("settings.language", table: "Settings"))
      }
      .pickerStyle(.inline)

      // «Стартовый набор»: categories, limits and tiles for the way the owner lives; only adds.
      Section {
        Button(environment.language("settings.starter.open", table: "Settings")) {
          SettingsStarterSet.shared.open()
        }
        .accessibilityIdentifier("settings.starter.open")
      } header: {
        Text(verbatim: environment.language("settings.starter", table: "Settings"))
      } footer: {
        Text(verbatim: environment.language("settings.starter.hint", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      // The tips on the spot (`GuideTips`): on this Mac only, never in the data.
      Section {
        Toggle(
          isOn: Binding(get: { GuideStore.shared.tipsOff }, set: { GuideTips.setOff($0) })
        ) {
          Text(verbatim: environment.language("settings.tips.off", table: "Settings"))
        }
        .accessibilityIdentifier("settings.tips.off")
      }

      // Hiding the amounts and the lock: switches of this Mac, never in the archive.
      PrivacySettingsSection()

      Section {
        Toggle(
          isOn: Binding(
            get: { environment.assignsEventAutomatically },
            set: { if !environment.setAssignsEventAutomatically($0) { refused = true } })
        ) {
          Text(verbatim: environment.language("settings.events.automatic", table: "Settings"))
        }
      } footer: {
        Text(verbatim: environment.language("settings.events.automaticHint", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      Section {
        ForEach(ForWhom.allCases, id: \.self) { value in
          LabeledContent {
            TextField(
              text: Binding(
                get: { environment.label(for: value) },
                set: { if !environment.setLabel($0, for: value) { refused = true } })
            ) {
              EmptyView()
            }
            .labelsHidden()
          } label: {
            Text(verbatim: environment.language("forWhom.\(value.rawValue)"))
          }
        }
      } header: {
        Text(verbatim: environment.language("settings.forWhomLabels", table: "Settings"))
      } footer: {
        Text(verbatim: environment.language("settings.forWhom.fixedHint", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      // The five values above are fixed by the specification and can only be renamed. What
      // «для кого» can really be extended with is a person — the other half of the same
      // dimension, and a free list — and until 21.09 nothing on this screen said so or
      // offered to add one.
      Section {
        ForEach(people.filter { !$0.archived }, id: \.id) { person in
          Text(verbatim: person.name)
        }
        HStack {
          TextField(text: $newPerson) {
            // A person has a name, not a «Название»: the shared key of the reference books
            // reads wrong under a section headed «Люди».
            Text(verbatim: environment.language("settings.forWhom.personName", table: "Settings"))
          }
          .onSubmit(addPerson)
          .accessibilityIdentifier("settings.forWhom.newPerson")
          Button(environment.language("references.add", table: "Settings"), action: addPerson)
            .disabled(!canAddPerson)
        }
        if !ReferenceNames.folded(newPerson).isEmpty, !canAddPerson {
          Text(verbatim: environment.language("references.nameTaken", table: "Settings"))
            .appFont(.callout)
            .foregroundStyle(.secondary)
        }
      } header: {
        Text(verbatim: environment.language("settings.forWhom.people", table: "Settings"))
      } footer: {
        Text(verbatim: environment.language("settings.forWhom.peopleHint", table: "Settings"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      #if !APPSTORE
        updatesSection
      #endif

      // «Собрать отчёт о проблеме…» — the specification asks for it here as well as in the
      // menu.
      ProblemReportView()

      if language.needsRestart {
        LabeledContent {
          Button(environment.language("settings.language.restart", table: "Settings")) {
            AppRestart.relaunch()
          }
        } label: {
          Text(verbatim: environment.language("settings.language.restartHint", table: "Settings"))
            .appFont(.callout)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .padding()
    .onAppear(perform: reloadPeople)
    .refusedWriteAlert($refused, environment)
  }

  #if !APPSTORE
    /// «Обновления: автоматические вкл/выкл (по умолчанию вкл)». A build
    /// that cannot verify an update keeps the switch in view, greyed, and says why.
    private var updatesSection: some View {
      Section {
        Toggle(
          isOn: Binding(
            get: { automaticUpdates },
            set: { isOn in
              AutomaticUpdates().isOn = isOn
              automaticUpdates = isOn
            })
        ) {
          Text(verbatim: environment.language("settings.updates.automatic", table: "Settings"))
        }
        .disabled(!AutomaticUpdates.isChangeable)
      } header: {
        Text(verbatim: environment.language("settings.updates", table: "Settings"))
      } footer: {
        Text(
          verbatim: environment.language(
            AutomaticUpdates.isChangeable
              ? "settings.updates.automaticHint" : "settings.updates.unavailableHint",
            table: "Settings")
        )
        .appFont(.callout)
        .foregroundStyle(.secondary)
      }
    }
  #endif

  private func reloadPeople() {
    people = (try? environment.references?.people(includeArchived: true)) ?? []
  }

  /// A name already in the book — a name or an alias, by the rule the reference books use —
  /// adds nothing, and a button that stays live while nothing happens is worse than one that
  /// explains itself by being grey.
  private var canAddPerson: Bool {
    Self.person(toAdd: newPerson, among: people) != nil
  }

  /// The row «Добавить» brings for `name`, or nil when it adds nothing: an empty name, or one
  /// a live person already answers to, as a name or an other name, by the rule the reference
  /// books use (`ReferenceNames`: case, «ё»/«е» and the spaces around do not count) — two
  /// people with one name are two rows the entry line cannot tell apart. A name the archive
  /// has — his name first, else one of his other names — brings that person back with the
  /// relation and the other names he had, as `ReferenceRepository.revive` does on the write.
  static func person(toAdd name: String, among people: [Person]) -> Person? {
    let name = name.trimmingCharacters(in: .whitespaces)
    let live = people.filter { !$0.archived }
    guard ReferenceBooksView.canAdd(name, to: .people, people: live, places: []) else {
      return nil
    }
    let wanted = ReferenceNames.folded(name)
    let archived = people.filter(\.archived)
    guard
      var back = archived.first(where: { ReferenceNames.folded($0.name) == wanted })
        ?? archived.first(where: { $0.aliases.contains { ReferenceNames.folded($0) == wanted } })
    else { return Person(name: name) }
    back.archived = false
    return back
  }

  /// A new person, or the one the archive holds under this name or an other name of his —
  /// with the relation and the other names he had — by the rule of the reference books
  /// (`NewReference.add`), rather than a second row with the same name.
  private func addPerson() {
    guard canAddPerson else { return }
    let today = environment.today
    guard
      environment.attempt(
        "references.add", on: environment.references,
        { _ = try NewReference.add(newPerson, to: .people, from: today, to: today, references: $0) }
      )
    else {
      refused = true
      return
    }
    newPerson = ""
    reloadPeople()
    environment.refreshVocabulary()
    environment.scheduleBackup()
  }
}

struct CurrenciesSettingsView: View {
  @Dependency(\.environment) private var environment
  @State private var enabled: [CurrencyCode] = []
  /// The currency of everything new (`currencies.default`).
  @State private var defaultCurrency: CurrencyCode = .rub
  /// The live accounts, for the currencies they hold.
  @State private var accounts: [PaymentMethod] = []
  /// What the latest table of the bank in the cache lacks (`CurrencyCheck`); empty while the
  /// cache holds none — the check of the first launch fills it.
  @State private var notPublished: Set<CurrencyCode> = []
  /// A write the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false

  /// The currencies of the bank a checkbox is offered for: everything the Bank of Russia
  /// publishes, plus the ruble — the ones on a fresh install first — and any other code of the
  /// bank switched on elsewhere. As many as the owner likes can be on.
  private var offered: [CurrencyCode] {
    Self.offered(enabled: enabled, catalog: environment.currencyCatalog)
  }

  /// The codes the Bank of Russia publishes in its daily table besides the ten of a fresh
  /// install, the usual ones first.
  static let published: [CurrencyCode] = [
    "GBP", "JPY", "CHF", "PLN", "UAH", "BYN", "KGS", "UZS", "AZN", "RSD", "AUD", "DZD", "BHD",
    "BGN", "BOB", "BRL", "HUF", "VND", "HKD", "DKK", "EGP", "INR", "IDR", "IRR", "CAD", "QAR",
    "CUP", "MDL", "MNT", "NGN", "NZD", "NOK", "OMR", "SAR", "RON", "XDR", "SGD", "TJS", "BDT",
    "TMT", "CZK", "SEK", "ETB", "ZAR", "KRW", "MMK",
  ].map(CurrencyCode.init)

  /// What the checkboxes offer: the currencies of a fresh install, the others the bank
  /// publishes, then any code of the bank switched on that is in neither list. A custom
  /// currency is never a checkbox: it has a section of its own.
  static func offered(enabled: [CurrencyCode], catalog: CurrencyCatalog) -> [CurrencyCode] {
    var seen = Set<CurrencyCode>()
    var all: [CurrencyCode] = []
    for code in CurrencyCode.defaultEnabled + published + enabled
    where !catalog.isCustom(code) && seen.insert(code).inserted {
      all.append(code)
    }
    return all
  }

  /// Why a currency that is on stays on.
  enum Lock: Equatable {
    /// The ruble: every total, limit and report is in it.
    case base
    /// The currency of everything new.
    case defaultCurrency
    /// Live accounts hold it, named here.
    case held([String])
  }

  /// Why `currency` cannot be switched off, or nil when it can. A currency that is off has
  /// nothing to lose, the ruble aside, which is always on.
  static func lock(
    for currency: CurrencyCode, isOn: Bool, defaultCurrency: CurrencyCode,
    accounts: [PaymentMethod]
  ) -> Lock? {
    if currency == .rub { return .base }
    guard isOn else { return nil }
    if currency == defaultCurrency { return .defaultCurrency }
    let holders = accounts.filter { !$0.archived && $0.holds(currency) }.map(\.name)
    return holders.isEmpty ? nil : .held(holders)
  }

  var body: some View {
    Form {
      Section {
        Picker(selection: defaultBinding) {
          ForEach(environment.currencyCatalog.choices(enabled: enabled), id: \.code) { currency in
            Text(verbatim: "\(currency.code)  \(environment.money.symbol(for: currency))")
              .tag(currency)
          }
        } label: {
          Text(verbatim: t("settings.currencies.default"))
        }
      } footer: {
        Text(verbatim: t("settings.currencies.defaultHint"))
          .appFont(.callout)
          .foregroundStyle(.secondary)
      }

      Section {
        ForEach(offered, id: \.code) { currency in
          let lock = Self.lock(
            for: currency, isOn: enabled.contains(currency), defaultCurrency: defaultCurrency,
            accounts: accounts)
          Toggle(isOn: binding(for: currency)) {
            HStack(spacing: 8) {
              Text(verbatim: currency.code)
              Text(verbatim: environment.money.symbol(for: currency))
                .appFont(.callout)
                .foregroundStyle(.secondary)
              if let lock, let caption = caption(lock) {
                Label {
                  Text(verbatim: caption)
                } icon: {
                  Image(systemName: "lock")
                }
                .appFont(.callout)
                .foregroundStyle(.secondary)
              }
              if notPublished.contains(currency) {
                // The daily table of the bank does not carry this currency, so an
                // operation in it will have to use a rate typed by hand.
                Label {
                  Text(verbatim: t("currencies.notAtCBR"))
                } icon: {
                  Image(systemName: "exclamationmark.triangle")
                }
                .appFont(.callout)
                .foregroundStyle(.orange)
              }
            }
          }
          .toggleStyle(.checkbox)
          .disabled(lock != nil)
          .help(lock.map(tooltip) ?? "")
        }
      } header: {
        Text(verbatim: t("settings.currencies.enabled"))
      } footer: {
        Text(
          verbatim: environment.format(
            "settings.currencies.countOn", table: "Settings",
            counts: enabled.filter { !environment.currencyCatalog.isCustom($0) }.count)
        )
        .appFont(.callout)
        .foregroundStyle(.secondary)
      }

      CustomCurrenciesSection()
    }
    .formStyle(.grouped)
    .padding()
    .onAppear(perform: reload)
    .refusedWriteAlert($refused, environment)
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Settings") }

  /// The word beside a locked currency: the tooltip says the rest. The ruble needs none.
  private func caption(_ lock: Lock) -> String? {
    switch lock {
    case .base: nil
    case .defaultCurrency: t("currencies.caption.default")
    case .held(let names) where names.count == 1:
      environment.format("currencies.caption.heldOne", table: "Settings", names[0])
    case .held(let names):
      environment.format(
        "currencies.caption.heldMany", table: "Settings", names.joined(separator: ", "))
    }
  }

  private func tooltip(_ lock: Lock) -> String {
    switch lock {
    case .base: t("currencies.lock.base")
    case .defaultCurrency: t("currencies.lock.default")
    case .held: t("currencies.lock.held")
    }
  }

  /// A new default is one of the enabled currencies.
  private var defaultBinding: Binding<CurrencyCode> {
    Binding(
      get: { defaultCurrency },
      set: { currency in
        guard currency != defaultCurrency else { return }
        if !Self.chooseDefault(currency, in: environment) { refused = true }
        reload()
      })
  }

  private func binding(for currency: CurrencyCode) -> Binding<Bool> {
    Binding(
      get: { enabled.contains(currency) },
      set: { isOn in
        if !Self.switchCurrency(currency, on: isOn, enabled: enabled, in: environment) {
          refused = true
        }
        reload()
      })
  }

  /// Makes `currency` the currency of everything new. The window reads the account settings
  /// again at once, so the next thing made takes it. False when the database refused.
  static func chooseDefault(_ currency: CurrencyCode, in environment: AppEnvironment) -> Bool {
    let written = environment.attempt(
      "currencies.default", on: environment.settings, { try $0.setDefaultCurrency(currency) })
    environment.refreshAccountSettings()
    environment.refreshVocabulary()
    return written
  }

  /// Switches `currency` on — last — or off; there is no limit to how many are on. The ruble always
  /// stays; the default currency and a currency a live account holds stay too: the database
  /// refuses to drop them (`SettingsWriteError.currencyInUse`), whatever the checkbox did. True
  /// when there was nothing to do or the write landed.
  static func switchCurrency(
    _ currency: CurrencyCode, on isOn: Bool, enabled: [CurrencyCode],
    in environment: AppEnvironment
  ) -> Bool {
    var updated = enabled.filter { $0 != currency }
    if isOn {
      updated.append(currency)
    }
    // The ruble is the base currency and cannot be switched off.
    if !updated.contains(.rub) {
      updated.insert(.rub, at: 0)
    }
    let written = environment.attempt(
      "settings.currencies", on: environment.settings, { try $0.setEnabledCurrencies(updated) })
    environment.refreshAccountSettings()
    environment.refreshVocabulary()
    return written
  }

  private func reload() {
    enabled = (try? environment.settings?.enabledCurrencies()) ?? CurrencyCode.defaultEnabled
    defaultCurrency = environment.defaultCurrency
    accounts = (try? environment.accounts?.accounts()) ?? []
    notPublished = Set(
      CurrencyCheck.notPublished(offered, in: (try? environment.rates?.allRates()) ?? []))
  }
}
