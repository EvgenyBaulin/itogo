import AppCore
import AppDatabase
import SwiftUI

/// People, places, payment methods and events — the dictionaries the entry line matches
/// names against, and everything the specification says each of them carries: aliases,
/// the relation of a person, the kind of a payment method and which one is the default,
/// the dates, budget and yearly repeat of an event.
///
/// Rows are archived rather than deleted, because operations point at them, and duplicates
/// are merged: the operations move to the row that stays and the old name becomes its alias.
/// A merge cannot be taken back, so it is asked first.
struct ReferenceBooksView: View {
  @Dependency(\.environment) private var environment

  @State private var book: Book = .people
  @State private var people: [Person] = []
  @State private var places: [Place] = []
  @State private var methods: [PaymentMethod] = []
  @State private var events: [Event] = []
  @State private var selection: UUID?
  @State private var newName = ""
  /// The merge the owner picked from a row's menu, waiting for the answer.
  @State private var merging: MergeQuestion?
  /// A write the database refused; the alert says so (`AppEnvironment.attempt`).
  @State private var refused = false

  enum Book: String, CaseIterable, Identifiable {
    case people, places, paymentMethods, events
    var id: String { rawValue }

    var titleKey: String {
      switch self {
      case .people: "settings.people"
      case .places: "settings.places"
      case .paymentMethods: "settings.paymentMethods"
      case .events: "settings.events"
      }
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker(selection: $book) {
        ForEach(Book.allCases) { item in
          Text(verbatim: environment.language(item.titleKey, table: "Settings")).tag(item)
        }
      } label: {
        EmptyView()
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      HStack(alignment: .top, spacing: 12) {
        list
          .frame(width: 220)
        Divider()
        detail
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      HStack {
        TextField(text: $newName) {
          Text(verbatim: environment.language("references.name", table: "Settings"))
        }
        .onSubmit(add)
        Button(environment.language("references.add", table: "Settings"), action: add)
          .disabled(!canAddNewName)
      }
      if isNewNameTaken {
        Text(verbatim: environment.language("references.nameTaken", table: "Settings"))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding()
    .onAppear(perform: reload)
    .refusedWriteAlert($refused, environment)
    .onChange(of: book) { _, _ in
      selection = nil
      reload()
    }
    .confirmationDialog(
      merging?.title(environment) ?? "", isPresented: isAskingToMerge,
      titleVisibility: .visible, presenting: merging
    ) { question in
      Button(question.confirm(environment), role: .destructive) { merge(question) }
      Button(environment.language("action.cancel"), role: .cancel) {}
    } message: { question in
      Text(verbatim: question.message(environment))
    }
  }

  private var isAskingToMerge: Binding<Bool> {
    Binding(
      get: { merging != nil },
      set: { isShown in
        if !isShown { merging = nil }
      })
  }

  /// A merge of one row into another, asked before it is made: the operations move and the
  /// row merged away goes to the archive, and nothing takes that back.
  struct MergeQuestion: Identifiable {
    let book: Book
    let source: UUID
    let sourceName: String
    let target: UUID
    let targetName: String

    var id: UUID { source }

    @MainActor
    func title(_ environment: AppEnvironment) -> String {
      environment.format("references.merge.title", table: "Settings", sourceName, targetName)
    }

    /// An event has no aliases: its old name does not stay anywhere.
    @MainActor
    func message(_ environment: AppEnvironment) -> String {
      environment.format(
        book == .events ? "references.merge.messageEvent" : "references.merge.message",
        table: "Settings", sourceName, targetName)
    }

    @MainActor
    func confirm(_ environment: AppEnvironment) -> String {
      environment.language("references.merge.confirm", table: "Settings")
    }

    /// Makes the merge the owner agreed to.
    func merge(_ references: ReferenceRepository) throws {
      switch book {
      case .people: try references.mergePerson(source, into: target)
      case .places: try references.mergePlace(source, into: target)
      case .paymentMethods: try references.mergePaymentMethod(source, into: target)
      case .events: try references.mergeEvent(source, into: target)
      }
    }
  }

  // MARK: List

  private var list: some View {
    List(selection: $selection) {
      ForEach(rows, id: \.0) { row in
        HStack {
          Text(verbatim: row.1)
          Spacer()
          if row.2 {
            Image(systemName: "star.fill")
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .tag(row.0)
        .contextMenu {
          if !mergeTargets(excluding: row.0).isEmpty {
            Menu(environment.language("references.merge", table: "Settings")) {
              ForEach(mergeTargets(excluding: row.0), id: \.0) { target in
                Button(target.1) {
                  merging = MergeQuestion(
                    book: book, source: row.0, sourceName: row.1, target: target.0,
                    targetName: target.1)
                }
              }
            }
          }
          Button(environment.language("references.archive", table: "Settings")) {
            archive(row.0)
          }
        }
      }
    }
    .frame(minHeight: 220)
  }

  /// id, title and whether the row is the default payment method.
  private var rows: [(UUID, String, Bool)] {
    switch book {
    case .people: people.map { ($0.id, $0.name, false) }
    case .places: places.map { ($0.id, $0.name, false) }
    case .paymentMethods: methods.map { ($0.id, $0.name, $0.isDefault) }
    case .events: events.map { ($0.id, $0.name, false) }
    }
  }

  private func mergeTargets(excluding id: UUID) -> [(UUID, String)] {
    rows.filter { $0.0 != id }.map { ($0.0, $0.1) }
  }

  // MARK: Detail

  @ViewBuilder
  private var detail: some View {
    if let selection {
      switch book {
      case .people:
        if let index = people.firstIndex(where: { $0.id == selection }) {
          personForm(index)
        }
      case .places:
        if let index = places.firstIndex(where: { $0.id == selection }) {
          placeForm(index)
        }
      case .paymentMethods:
        if let index = methods.firstIndex(where: { $0.id == selection }) {
          methodForm(index)
        }
      case .events:
        if let index = events.firstIndex(where: { $0.id == selection }) {
          eventForm(index)
        }
      }
    } else {
      Text(verbatim: environment.language("references.pick", table: "Settings"))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 40)
    }
  }

  private func personForm(_ index: Int) -> some View {
    Form {
      TextField(text: $people[index].name) { label("references.name") }
      Picker(selection: $people[index].relation) {
        ForEach(PersonRelation.allCases, id: \.self) { relation in
          Text(verbatim: environment.language("relation.\(relation.rawValue)", table: "Settings"))
            .tag(relation)
        }
      } label: {
        label("references.relation")
      }
      aliasesField(
        aliases: Binding(
          get: { people[index].aliases }, set: { people[index].aliases = $0 }))
      saveRow { try $0.save(people[index]) }
    }
    .formStyle(.grouped)
  }

  private func placeForm(_ index: Int) -> some View {
    Form {
      TextField(text: $places[index].name) { label("references.name") }
      aliasesField(
        aliases: Binding(
          get: { places[index].aliases }, set: { places[index].aliases = $0 }))
      saveRow { try $0.save(places[index]) }
    }
    .formStyle(.grouped)
  }

  private func methodForm(_ index: Int) -> some View {
    Form {
      TextField(text: $methods[index].name) { label("references.name") }
      Picker(selection: $methods[index].kind) {
        ForEach(PaymentMethodKind.allCases, id: \.self) { kind in
          Text(verbatim: environment.language("payment.\(kind.rawValue)", table: "Settings"))
            .tag(kind)
        }
      } label: {
        label("references.kind")
      }
      Picker(selection: currencyBinding(index)) {
        Text(verbatim: "—").tag(CurrencyCode?.none)
        ForEach(environment.vocabulary.enabledCurrencies, id: \.code) { currency in
          Text(verbatim: currency.code).tag(CurrencyCode?.some(currency))
        }
      } label: {
        label("entry.currency")
      }
      Toggle(isOn: defaultBinding(index)) { label("references.default") }
      aliasesField(
        aliases: Binding(
          get: { methods[index].aliases }, set: { methods[index].aliases = $0 }))
      saveRow { try Self.save(methods[index], references: $0) }
    }
    .formStyle(.grouped)
  }

  private func eventForm(_ index: Int) -> some View {
    Form {
      TextField(text: $events[index].name) { label("references.name") }
      Picker(selection: $events[index].kind) {
        ForEach(EventKind.allCases, id: \.self) { kind in
          Text(verbatim: environment.language("event.\(kind.rawValue)", table: "Settings"))
            .tag(kind)
        }
      } label: {
        label("references.kind")
      }
      DatePicker(selection: dayBinding(index, \.startDate), displayedComponents: .date) {
        label("references.start")
      }
      .environment(\.locale, environment.language.locale)
      DatePicker(
        selection: dayBinding(index, \.endDate),
        in: environment.calendar.startOfDay(events[index].startDate)...,
        displayedComponents: .date
      ) {
        label("references.end")
      }
      .environment(\.locale, environment.language.locale)
      LabeledContent {
        AmountField(amount: budgetBinding(index), locale: environment.language.locale)
          .frame(width: 140)
      } label: {
        label("references.budget")
      }
      Toggle(isOn: $events[index].recurringYearly) { label("references.yearly") }
      saveRow { try $0.save(events[index]) }
    }
    .formStyle(.grouped)
  }

  // MARK: Pieces

  private func label(_ key: String) -> some View {
    Text(verbatim: environment.language(key, table: "Settings"))
  }

  /// Aliases are edited as one line per alias, which is how they are stored.
  private func aliasesField(aliases: Binding<[String]>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      label("references.aliases")
        .font(.caption)
        .foregroundStyle(.secondary)
      TextEditor(
        text: Binding(
          get: { aliases.wrappedValue.joined(separator: "\n") },
          set: { text in
            aliases.wrappedValue =
              text
              .split(separator: "\n", omittingEmptySubsequences: true)
              .map { $0.trimmingCharacters(in: .whitespaces) }
              .filter { !$0.isEmpty }
          })
      )
      .frame(height: 70)
      .font(.body)
    }
  }

  /// A refused save keeps the form as the owner left it, so pressing Save again is the retry.
  private func saveRow(_ save: @escaping (ReferenceRepository) throws -> Void) -> some View {
    HStack {
      Spacer()
      Button(environment.language("action.save")) {
        guard environment.attempt("references.save", on: environment.references, save) else {
          refused = true
          return
        }
        finish()
      }
      .buttonStyle(.borderedProminent)
    }
  }

  private func currencyBinding(_ index: Int) -> Binding<CurrencyCode?> {
    Binding(
      get: { methods[index].currency },
      set: { methods[index].currency = $0 })
  }

  /// Exactly one payment method is the default, so switching one on switches the rest off —
  /// on screen at once, in the database with «Сохранить», like every other field of the form.
  /// Until 24.09 the others were written off at the switch and the chosen one only on
  /// «Сохранить»: leaving the tab in between left the book without a default method.
  private func defaultBinding(_ index: Int) -> Binding<Bool> {
    Binding(
      get: { methods[index].isDefault },
      set: { isOn in Self.chooseDefault(at: index, isOn: isOn, in: &methods) })
  }

  /// The switch on screen: the chosen method on or off, and the others off when it is on.
  static func chooseDefault(at index: Int, isOn: Bool, in methods: inout [PaymentMethod]) {
    if isOn {
      for other in methods.indices where other != index { methods[other].isDefault = false }
    }
    methods[index].isDefault = isOn
  }

  /// Saves a payment method from its form. Saved as the default, it takes the default away
  /// from every other method as it is stored — written after it, so a failure between the two
  /// leaves two defaults for a moment, never none.
  static func save(_ method: PaymentMethod, references: ReferenceRepository) throws {
    try references.save(method)
    guard method.isDefault else { return }
    for var other in try references.paymentMethods(includeArchived: true)
    where other.id != method.id && other.isDefault {
      other.isDefault = false
      try references.save(other)
    }
  }

  private func dayBinding(_ index: Int, _ key: WritableKeyPath<Event, DateOnly>) -> Binding<Date> {
    Binding(
      get: { environment.calendar.startOfDay(events[index][keyPath: key]) },
      set: {
        events[index] = Self.event(
          events[index], setting: key, to: environment.calendar.day(of: $0))
      })
  }

  /// An event ends on or after the day it starts, or it covers no day at all. A start moved
  /// past the end takes the end along and the event keeps its length; an end is never set
  /// before the start (its picker offers no such day either).
  static func event(
    _ event: Event, setting key: WritableKeyPath<Event, DateOnly>, to day: DateOnly
  ) -> Event {
    var event = event
    if key == \Event.startDate {
      let length = max(0, event.startDate.days(to: event.endDate))
      event.startDate = day
      if event.endDate < day { event.endDate = day.adding(days: length) }
    } else {
      event[keyPath: key] = max(day, event.startDate)
    }
    return event
  }

  private func budgetBinding(_ index: Int) -> Binding<AmountE4> {
    Binding(
      get: { events[index].budgetE4 ?? .zero },
      set: { events[index].budgetE4 = $0.isZero ? nil : $0 })
  }

  // MARK: Data

  private func reload() {
    guard let references = environment.references else { return }
    people = (try? references.people()) ?? []
    places = (try? references.places()) ?? []
    methods = (try? references.paymentMethods()) ?? []
    events = (try? references.events()) ?? []
  }

  private var canAddNewName: Bool {
    Self.canAdd(newName, to: book, people: people, places: places, methods: methods)
  }

  /// The name is not empty and still cannot be added: say why the button is grey.
  private var isNewNameTaken: Bool {
    !ReferenceNames.folded(newName).isEmpty && !canAddNewName
  }

  /// A refused add keeps the name in the field. A payment method and an event are made the way
  /// «Add…» of the ↓ panel makes them (`NewReference`).
  private func add() {
    guard canAddNewName else { return }
    let name = newName.trimmingCharacters(in: .whitespaces)
    let written = environment.attempt("references.add", on: environment.references) {
      references in
      switch book {
      case .people:
        try references.save(Person(name: name))
      case .places:
        try references.save(Place(name: name))
      case .paymentMethods:
        try references.save(NewReference.paymentMethod(named: name, among: methods))
      case .events:
        let today = environment.today
        try references.save(NewReference.event(named: name, from: today, to: today))
      }
    }
    guard written else {
      refused = true
      return
    }
    newName = ""
    finish()
  }

  private func merge(_ question: MergeQuestion) {
    merging = nil
    guard
      environment.attempt(
        "references.merge", on: environment.references, { try question.merge($0) })
    else {
      refused = true
      return
    }
    selection = nil
    finish()
  }

  private func archive(_ id: UUID) {
    let written = environment.attempt("references.archive", on: environment.references) {
      references in
      switch book {
      case .people:
        if var row = people.first(where: { $0.id == id }) {
          row.archived = true
          try references.save(row)
        }
      case .places:
        if var row = places.first(where: { $0.id == id }) {
          row.archived = true
          try references.save(row)
        }
      case .paymentMethods:
        if var row = methods.first(where: { $0.id == id }) {
          row.archived = true
          try references.save(row)
        }
      case .events:
        if var row = events.first(where: { $0.id == id }) {
          row.archived = true
          try references.save(row)
        }
      }
    }
    guard written else {
      refused = true
      return
    }
    selection = nil
    finish()
  }

  private func finish() {
    reload()
    environment.refreshVocabulary()
    environment.scheduleBackup()
  }
}

extension ReferenceBooksView {
  /// Whether a new row of `book` may be called `name`. A person, a place or a payment method
  /// whose name or alias is already another row's adds nothing: two rows with one name are
  /// two rows the entry line cannot tell apart. Events are the exception —
  /// a yearly event is made again under the same name every year, so a shared name is how
  /// they are meant to be, and the entry line tells them apart by their dates.
  static func canAdd(
    _ name: String, to book: Book, people: [Person], places: [Place], methods: [PaymentMethod]
  ) -> Bool {
    guard !ReferenceNames.folded(name).isEmpty else { return false }
    switch book {
    case .people: return !ReferenceNames.isTaken(name, among: people.map(ReferenceNames.spellings))
    case .places: return !ReferenceNames.isTaken(name, among: places.map(ReferenceNames.spellings))
    case .paymentMethods:
      return !ReferenceNames.isTaken(name, among: methods.map(ReferenceNames.spellings))
    case .events: return true
    }
  }
}

/// The one rule of «this name is taken», shared by the reference books and the General tab.
///
/// It compares names the way the entry line reads them: case, «ё» against «е» and the spaces
/// around a name do not count. Only the rows the entry line knows are asked — the live ones;
/// an archived row is out of the vocabulary and out of sight, so refusing a name because of
/// it would grey the button for a reason the owner cannot see.
enum ReferenceNames {
  static func folded(_ name: String) -> String {
    String(name.trimmingCharacters(in: .whitespaces).lowercased().map { $0 == "ё" ? "е" : $0 })
  }

  static func spellings(_ person: Person) -> [String] { [person.name] + person.aliases }
  static func spellings(_ place: Place) -> [String] { [place.name] + place.aliases }
  static func spellings(_ method: PaymentMethod) -> [String] { [method.name] + method.aliases }

  /// Whether `name` is already one of the spellings of a row; each row is its name and aliases.
  static func isTaken(_ name: String, among rows: [[String]]) -> Bool {
    let wanted = folded(name)
    guard !wanted.isEmpty else { return false }
    return rows.contains { spellings in spellings.contains { folded($0) == wanted } }
  }
}
