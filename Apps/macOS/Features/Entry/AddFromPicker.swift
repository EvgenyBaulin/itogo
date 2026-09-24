import AppCore
import SwiftUI

/// «Add…», the last item of every menu of the ↓ panel that lists a dictionary: the category
/// and the subcategory, the person «для кого», the place, the event, the payment method and
/// the debtor of a part paid for someone. Choosing it chooses nothing — the menu keeps what it
/// showed — and opens a sheet that makes a record of its kind; saved there, the record is
/// chosen in the menu it was asked for from.
///
/// Menus of fixed values — the type, the quality, «для кого» itself, the currency, the month
/// of an income — have nothing to add to. A goal and a debt are not added here either: each
/// needs more than a name, and Planning and Debts ask for it.
enum AddFromPicker {
  /// The tag of the item in the menu. No record has it: a random identifier is never of
  /// version 0.
  static let tag = UUID(uuidString: "00000000-0000-0000-0000-00000000ADD0")!

  /// What the sheet makes, and where in the draft the new record goes.
  enum Kind: Hashable, Identifiable {
    /// A top-level category of the kind of the operation, for the part at this index.
    case category(part: Int)
    /// A subcategory of the category that part has.
    case subcategory(part: Int)
    /// The person «для кого» of the part.
    case person(part: Int)
    /// Who gives back a part paid for someone.
    case debtor(part: Int)
    case place
    case event(part: Int)
    case paymentMethod

    var id: Self { self }
  }

  /// The choice of a menu with «Add…» at its end: that item calls `adding` and leaves the
  /// choice as it was; every other item is chosen as it always is.
  @MainActor
  static func selection(
    _ choice: Binding<UUID?>, adding: @escaping @MainActor () -> Void
  ) -> Binding<UUID?> {
    Binding(
      get: { choice.wrappedValue },
      set: { value in
        if value == tag {
          adding()
        } else {
          choice.wrappedValue = value
        }
      })
  }
}

/// What the sheet of «Add…» asks for, and what «Save» does with it.
@MainActor
struct NewRecordForm {
  let kind: AddFromPicker.Kind
  /// As typed; saved without the spaces around it.
  var name: String
  /// The days of an event: today, until moved.
  private(set) var start: DateOnly
  private(set) var end: DateOnly
  /// The kind of a payment method.
  var paymentKind: PaymentMethodKind = .card

  /// A place or a person starts from the name the entry line read and could not match.
  init(kind: AddFromPicker.Kind, model: EntryDraftModel, today: DateOnly) {
    self.kind = kind
    switch kind {
    case .place: name = model.suggestedPlaceName ?? ""
    case .person, .debtor: name = model.suggestedPersonName ?? ""
    case .category, .subcategory, .event, .paymentMethod: name = ""
    }
    start = today
    end = today
  }

  var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

  /// A new start takes the end along when it passes it, and an end never comes before the
  /// start: the rule the reference book of events keeps.
  mutating func setStart(_ day: DateOnly) { move(\.startDate, to: day) }
  mutating func setEnd(_ day: DateOnly) { move(\.endDate, to: day) }

  private mutating func move(_ key: WritableKeyPath<Event, DateOnly>, to day: DateOnly) {
    let moved = ReferenceBooksView.event(
      Event(name: name, startDate: start, endDate: end), setting: key, to: day)
    start = moved.startDate
    end = moved.endDate
  }

  /// Why «Save» would add nothing, as the key of the words that say so (table «Entry»); nil
  /// when it would. A name has to say something. A person, a place or a payment method whose
  /// name or alias is already another's is refused, as the reference books refuse it: the
  /// entry line could not tell the two apart. A category is taken by one of the same kind
  /// under the same parent. Events may share a name: a yearly event is made again every year.
  func refusalKey(in model: EntryDraftModel) -> String? {
    let name = trimmedName
    guard !ReferenceNames.folded(name).isEmpty else { return "entry.add.nameMissing" }
    let taken: Bool
    switch kind {
    case .category:
      taken = Self.isTaken(category: name, under: nil, in: model)
    case .subcategory(let part):
      taken = Self.isTaken(
        category: name, under: model.categoryOfPart(model.part(at: part)), in: model)
    case .person, .debtor:
      taken = !ReferenceBooksView.canAdd(
        name, to: .people, people: model.people, places: [], methods: [])
    case .place:
      taken = !ReferenceBooksView.canAdd(
        name, to: .places, people: [], places: model.places, methods: [])
    case .paymentMethod:
      taken = !ReferenceBooksView.canAdd(
        name, to: .paymentMethods, people: [], places: [], methods: model.paymentMethods)
    case .event:
      taken = false
    }
    guard taken else { return nil }
    switch kind {
    case .category, .subcategory: return "entry.add.categoryTaken"
    default: return "entry.add.nameTaken"
    }
  }

  private static func isTaken(
    category name: String, under parent: UUID?, in model: EntryDraftModel
  ) -> Bool {
    let wanted = ReferenceNames.folded(name)
    return model.categories.contains { category in
      category.parentId == parent && category.kind == model.draft.kind.categoryKind
        && ReferenceNames.folded(category.name) == wanted
    }
  }

  /// Writes the record the way the panel writes one and chooses it in the menu the sheet was
  /// opened from. False when nothing was written: a refusal, a part that is no longer there,
  /// or a write the database refused (the model's `creationFailureKey` says so).
  func save(into model: EntryDraftModel, today: DateOnly) -> Bool {
    guard refusalKey(in: model) == nil else { return false }
    let name = trimmedName
    switch kind {
    case .category(let part):
      guard model.draft.parts.indices.contains(part),
        let id = model.createCategory(named: name, under: nil)
      else { return false }
      model.setCategory(id, forPartAt: part)
    case .subcategory(let part):
      guard model.canAddSubcategory(forPartAt: part),
        let parent = model.categoryOfPart(model.part(at: part)),
        let id = model.createCategory(named: name, under: parent)
      else { return false }
      model.setSubcategory(id, forPartAt: part)
    case .person(let part):
      guard model.draft.parts.indices.contains(part), let id = model.createPerson(named: name)
      else { return false }
      model.draft.parts[part].forPersonId = id
    case .debtor(let part):
      guard model.createDebtor(named: name, forPartAt: part) else { return false }
    case .place:
      guard let id = model.createPlace(named: name) else { return false }
      model.draft.placeId = id
    case .event(let part):
      guard model.draft.parts.indices.contains(part),
        let id = model.createEvent(named: name, from: start, to: end)
      else { return false }
      model.draft.parts[part].eventId = id
    case .paymentMethod:
      guard let id = model.createPaymentMethod(named: name, kind: paymentKind) else {
        return false
      }
      model.setPaymentMethod(id)
    }
    // What the new record brings: a place its payment method, a category its quality.
    model.applyDefaults(today: today)
    return true
  }
}
