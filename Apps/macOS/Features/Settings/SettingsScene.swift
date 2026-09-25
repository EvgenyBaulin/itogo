import AppCore
import AppKit
import SwiftUI

/// ⌘, — settings, a tab for each part of them.
struct SettingsView: View {
  let deps: AppDependencies

  init(deps: AppDependencies) {
    self.deps = deps
  }

  private var environment: AppEnvironment { deps.environment }

  /// The smallest the window may be made: the eight tabs of the toolbar in either language.
  static let minimumSize = CGSize(width: 680, height: 460)
  /// The size it opens at.
  static let idealSize = CGSize(width: 760, height: 620)

  var body: some View {
    TabView {
      GeneralSettingsView()
        .tabItem {
          Label {
            Text(verbatim: environment.language("settings.tab.general", table: "Settings"))
          } icon: {
            Image(systemName: "gearshape")
          }
        }
      AppearanceSettingsView()
        .tabItem {
          Label {
            Text(verbatim: environment.language("settings.tab.appearance", table: "Settings"))
          } icon: {
            Image(systemName: "paintpalette")
          }
        }
      CurrenciesSettingsView()
        .tabItem {
          Label {
            Text(verbatim: environment.language("settings.tab.currencies", table: "Settings"))
          } icon: {
            Image(systemName: "banknote")
          }
        }
      CategoriesSettingsView()
        .tabItem {
          Label {
            Text(verbatim: environment.language("settings.tab.categories", table: "Settings"))
          } icon: {
            Image(systemName: "folder")
          }
        }
      ReferenceBooksView()
        .tabItem {
          Label {
            Text(verbatim: environment.language("settings.tab.references", table: "Settings"))
          } icon: {
            Image(systemName: "books.vertical")
          }
        }
      TemplatesSettingsView()
        .tabItem {
          Label {
            Text(verbatim: environment.language("settings.templates", table: "Settings"))
          } icon: {
            Image(systemName: "square.grid.2x2")
          }
        }
      PlanningSettingsView()
        .tabItem {
          Label {
            Text(verbatim: environment.language("settings.tab.planning", table: "Settings"))
          } icon: {
            Image(systemName: "calendar")
          }
        }
      BackupSettingsView()
        .tabItem {
          Label {
            Text(verbatim: environment.language("settings.tab.backups", table: "Settings"))
          } icon: {
            Image(systemName: "externaldrive")
          }
        }
    }
    // Room for what the tabs hold now — the row of accent circles, a category per row with its
    // quality — and a window that can be made larger still: the tabs scroll, but a list of
    // categories read through a slot of 420 points is a list nobody reads.
    .frame(
      minWidth: Self.minimumSize.width, idealWidth: Self.idealSize.width, maxWidth: .infinity,
      minHeight: Self.minimumSize.height, idealHeight: Self.idealSize.height,
      maxHeight: .infinity
    )
    .background(ResizableSettingsWindow(minimum: Self.minimumSize))
    // So a UI test can say the settings really opened when the gear of the toolbar is pressed.
    .accessibilityIdentifier("settings.window")
    // «Справка» → «Собрать отчёт о проблеме…»: the report itself, not a tab to look for it
    // in. A sheet is laid out by a host of its own: the dependencies are handed over.
    .sheet(
      isPresented: Binding(
        get: { environment.showsProblemReport },
        set: { environment.showsProblemReport = $0 })
    ) {
      ProblemReportSheet(height: 380).appDependencies(deps)
    }
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
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } header: {
        Text(verbatim: environment.language("settings.forWhom.people", table: "Settings"))
      } footer: {
        Text(verbatim: environment.language("settings.forWhom.peopleHint", table: "Settings"))
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

  /// The row «Добавить» writes for `name`, or nil when it adds nothing: an empty name, or one
  /// a live person already answers to, as a name or an alias, by the rule the reference books
  /// use (`ReferenceNames`: case, «ё»/«е» and the spaces around do not count) — two people
  /// with one name are two rows the entry line cannot tell apart. A name the archive has
  /// brings that person back, with the relation and the aliases he had, rather than making a
  /// second row with the same name.
  static func person(toAdd name: String, among people: [Person]) -> Person? {
    let name = name.trimmingCharacters(in: .whitespaces)
    let live = people.filter { !$0.archived }
    guard
      ReferenceBooksView.canAdd(name, to: .people, people: live, places: [], methods: [])
    else { return nil }
    let wanted = ReferenceNames.folded(name)
    guard
      var archived = people.first(where: {
        $0.archived && ReferenceNames.folded($0.name) == wanted
      })
    else { return Person(name: name) }
    archived.archived = false
    return archived
  }

  /// A new person — or one back from the archive — from the screen the owner was looking at.
  private func addPerson() {
    guard let person = Self.person(toAdd: newPerson, among: people) else { return }
    guard
      environment.attempt("references.add", on: environment.references, { try $0.save(person) })
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
  /// What the latest table of the bank in the cache lacks (`CurrencyCheck`); empty while the
  /// cache holds none — the check of the first launch fills it.
  @State private var notPublished: Set<CurrencyCode> = []
  /// A write the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false

  /// Everything the Bank of Russia publishes, plus the ruble. The list is short on purpose:
  /// the specification caps the enabled currencies at ten.
  private var offered: [CurrencyCode] {
    let extras = ["GBP", "JPY", "CHF", "PLN", "UAH", "BYN", "KGS", "UZS", "AZN", "RSD"]
    return CurrencyCode.defaultEnabled + extras.map(CurrencyCode.init)
  }

  var body: some View {
    Form {
      Section {
        ForEach(offered, id: \.code) { currency in
          Toggle(isOn: binding(for: currency)) {
            HStack(spacing: 8) {
              Text(verbatim: currency.code)
              Text(verbatim: environment.money.symbol(for: currency))
                .foregroundStyle(.secondary)
              if notPublished.contains(currency) {
                // The daily table of the bank does not carry this currency, so an
                // operation in it will have to use a rate typed by hand.
                Label {
                  Text(verbatim: environment.language("currencies.notAtCBR", table: "Settings"))
                } icon: {
                  Image(systemName: "exclamationmark.triangle")
                }
                .font(.caption)
                .foregroundStyle(.orange)
              }
            }
          }
          .toggleStyle(.checkbox)
          .disabled(currency == .rub || (!enabled.contains(currency) && isFull))
        }
      } header: {
        Text(verbatim: environment.language("settings.currencies.enabled", table: "Settings"))
      } footer: {
        Text(
          verbatim: environment.format(
            "settings.currencies.count", table: "Settings", enabled.count,
            CurrencyCode.maxEnabled)
        )
        .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .padding()
    .onAppear(perform: reload)
    .refusedWriteAlert($refused, environment)
  }

  private var isFull: Bool { enabled.count >= CurrencyCode.maxEnabled }

  private func binding(for currency: CurrencyCode) -> Binding<Bool> {
    Binding(
      get: { enabled.contains(currency) },
      set: { isOn in
        var updated = enabled.filter { $0 != currency }
        if isOn {
          guard updated.count < CurrencyCode.maxEnabled else { return }
          updated.append(currency)
        }
        // The ruble is the base currency and cannot be switched off.
        if !updated.contains(.rub) {
          updated.insert(.rub, at: 0)
        }
        if !environment.attempt(
          "settings.currencies", on: environment.settings, { try $0.setEnabledCurrencies(updated) })
        {
          refused = true
        }
        environment.refreshVocabulary()
        reload()
      })
  }

  private func reload() {
    enabled = (try? environment.settings?.enabledCurrencies()) ?? CurrencyCode.defaultEnabled
    notPublished = Set(
      CurrencyCheck.notPublished(offered, in: (try? environment.rates?.allRates()) ?? []))
  }
}
