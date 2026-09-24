import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

@Suite("Operations survive a round trip through SQLite")
struct RepositoryTests {
  @Test func savingAndReadingBackKeepsEveryField() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let entry = try TestSupport.makeEntry()

    try repository.save(entry)
    let loaded = try repository.entry(id: entry.id)

    #expect(loaded?.transaction.amountE4 == entry.transaction.amountE4)
    #expect(loaded?.transaction.kind == .expense)
    #expect(loaded?.transaction.note == "coffee")
    #expect(loaded?.parts.count == 1)
    #expect(loaded?.isBalanced == true)
  }

  @Test func unbalancedPartsAreRefused() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    var entry = try TestSupport.makeEntry(amount: 1_000_000)
    entry.parts[0].amountE4 = AmountE4(raw: 400_000)

    #expect(throws: DatabaseError.unbalancedParts) {
      try repository.save(entry)
    }
  }

  /// Every operation has at least one part. A zero operation with no parts adds up —
  /// nothing equals nothing — but it is not an operation the reports can count.
  @Test func anOperationWithoutPartsIsRefused() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    var entry = try TestSupport.makeEntry(amount: 0)
    entry.parts = []

    #expect(!entry.isBalanced)
    #expect(throws: DatabaseError.unbalancedParts) {
      try repository.save(entry)
    }
    #expect(try repository.count() == 0)
  }

  @Test func deletingIsSoftAndUndoBringsTheOperationBack() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let entry = try TestSupport.makeEntry()
    try repository.save(entry)

    try repository.softDelete(id: entry.id)
    #expect(try repository.count() == 0)
    #expect(try repository.entry(id: entry.id)?.transaction.isDeleted == true)

    try repository.restore(id: entry.id)
    #expect(try repository.count() == 1)
  }

  /// Rule 2 of the qualities only needs the operations I rated by hand, and a deleted one
  /// no longer counts.
  @Test func onlyOperationsRatedByHandAreReadForTheQualityHistory() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    var rated = try TestSupport.makeEntry(note: "taxi")
    rated.parts[0].quality = .bad
    rated.parts[0].qualitySource = .manual
    var fromCategory = try TestSupport.makeEntry(note: "coffee")
    fromCategory.parts[0].quality = .neutral
    fromCategory.parts[0].qualitySource = .category
    var deleted = try TestSupport.makeEntry(note: "bar")
    deleted.parts[0].quality = .bad
    deleted.parts[0].qualitySource = .manual
    for entry in [rated, fromCategory, deleted] { try repository.save(entry) }
    try repository.softDelete(id: deleted.id)

    let read = try repository.entriesRatedByHand()
    #expect(read.map(\.transaction.note) == ["taxi"])
    #expect(read.first?.parts.map(\.quality) == [.bad])
  }

  /// The ↓ panel asks for the history at every change of a picker: it is read from the
  /// database once and kept until an operation or a part is written — by any repository on
  /// the database, a rating given, changed or deleted alike.
  @Test func theQualityHistoryIsReadOnceUntilAnOperationIsWritten() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    var taxi = try TestSupport.makeEntry(note: "taxi")
    taxi.parts[0].quality = .bad
    taxi.parts[0].qualitySource = .manual
    try repository.save(taxi)

    #expect(try repository.manualQualityHistory().quality(for: "taxi") == .bad)
    for _ in 0..<5 { _ = try repository.manualQualityHistory() }
    #expect(repository.manualRatings.reads == 1)

    // Written through another repository, as the store and the entry line each hold one.
    let other = TransactionRepository(writer: stack.writer)
    var bar = try TestSupport.makeEntry(note: "bar")
    bar.parts[0].quality = .good
    bar.parts[0].qualitySource = .manual
    try other.save(bar)
    #expect(try repository.manualQualityHistory().quality(for: "bar") == .good)
    #expect(repository.manualRatings.reads == 2)

    taxi.parts[0].quality = .neutral
    try other.save(taxi)
    #expect(try repository.manualQualityHistory().quality(for: "taxi") == .neutral)
    try other.softDelete(id: taxi.id)
    #expect(try repository.manualQualityHistory().quality(for: "taxi") == nil)
    #expect(repository.manualRatings.reads == 4)
  }

  @Test func entriesAreListedNewestFirst() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    let older = try TestSupport.makeEntry(
      occurredAt: Date(timeIntervalSince1970: 1_788_000_000), note: "older")
    let newer = try TestSupport.makeEntry(
      occurredAt: Date(timeIntervalSince1970: 1_789_000_000), note: "newer")
    try repository.save(older)
    try repository.save(newer)

    let listed = try repository.recentEntries()
    #expect(listed.map(\.transaction.note) == ["newer", "older"])
  }

  @Test func currenciesAreCappedAtTen() throws {
    let stack = try TestSupport.makeStack()
    let settings = SettingsRepository(writer: stack.writer)
    let twelve = (1...12).map { CurrencyCode("C\($0)") }

    try settings.setEnabledCurrencies(twelve)
    #expect(try settings.enabledCurrencies().count == CurrencyCode.maxEnabled)
  }

  @Test func settingsAreKeyValue() throws {
    let stack = try TestSupport.makeStack()
    let settings = SettingsRepository(writer: stack.writer)
    try settings.set("app.language", to: "ru")
    try settings.set("app.language", to: "en")
    #expect(try settings.string("app.language") == "en")
    #expect(try settings.string("missing") == nil)
  }

  @Test func ratesFallBackToTheLastPublishedDay() throws {
    let stack = try TestSupport.makeStack()
    let rates = RateRepository(writer: stack.writer)
    let friday = Rate(
      date: DateOnly(year: 2026, month: 9, day: 18), currency: .usd,
      rubPerUnit: Decimal(string: "81.43")!)
    try rates.save([friday])

    let saturday = try rates.rate(for: .usd, on: DateOnly(year: 2026, month: 9, day: 19))
    #expect(saturday?.date == friday.date)
    #expect(saturday?.rubPerUnit == Decimal(string: "81.43")!)
  }

  @Test func categorySeedingRunsOnlyOnce() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let parent = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    let child = CoreKit.Category(parentId: parent.id, kind: .expense, name: "Market")

    try references.seedCategoriesIfEmpty([parent, child])
    try references.seedCategoriesIfEmpty([CoreKit.Category(kind: .expense, name: "Other")])

    let all = try references.categories()
    #expect(all.count == 2)
    #expect(all.contains { $0.name == "Market" && $0.parentId == parent.id })
  }
}

@Suite("Merging duplicates moves the operations")
struct MergeTests {
  @Test func mergingPeopleMovesPartsAndKeepsTheOldNameAsAnAlias() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let transactions = TransactionRepository(writer: stack.writer)

    let keep = Person(name: "Alex", aliases: ["Al"])
    let duplicate = Person(name: "Alex K.", aliases: ["AK"])
    try references.save(keep)
    try references.save(duplicate)

    var draft = TransactionDraft(amount: AmountE4(whole: 500))
    draft.parts = [
      PartDraft(
        amount: AmountE4(whole: 500), forWhom: .friends, forPersonId: duplicate.id,
        reimbursable: true, debtorPersonId: duplicate.id)
    ]
    let entry = try draft.materialize()
    try transactions.save(entry)

    try references.mergePerson(duplicate.id, into: keep.id)

    let moved = try #require(try transactions.entry(id: entry.id))
    #expect(moved.parts[0].forPersonId == keep.id)
    #expect(moved.parts[0].debtorPersonId == keep.id)

    let people = try references.people()
    #expect(people.count == 1)
    let survivor = try #require(people.first)
    #expect(survivor.id == keep.id)
    #expect(survivor.aliases.contains("Alex K."))
    #expect(survivor.aliases.contains("AK"))
  }

  @Test func mergingPlacesMovesOperations() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let transactions = TransactionRepository(writer: stack.writer)

    let keep = Place(name: "Green Market")
    let duplicate = Place(name: "green market")
    try references.save(keep)
    try references.save(duplicate)

    var draft = TransactionDraft(amount: AmountE4(whole: 100), placeId: duplicate.id)
    draft.normalizeSinglePart()
    let entry = try draft.materialize()
    try transactions.save(entry)

    try references.mergePlace(duplicate.id, into: keep.id)

    let moved = try #require(try transactions.entry(id: entry.id))
    #expect(moved.transaction.placeId == keep.id)
    #expect(try references.places().count == 1)
  }

  /// The planning book points at people, cards and events too. A merge that left a
  /// subscription's debtor on the archived duplicate would undo itself with the next charge,
  /// which is written for the payment's person.
  @Test func mergingMovesThePlanningAndTheImportMappingsToo() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let planning = PlanningRepository(writer: stack.writer)

    let keep = Person(name: "Maria")
    let duplicate = Person(name: "Masha")
    let card = PaymentMethod(name: "Tinkoff", kind: .card, currency: .rub)
    let sameCard = PaymentMethod(name: "Tinkoff Black", kind: .card, currency: .rub)
    let days = (DateOnly(year: 2026, month: 10, day: 1), DateOnly(year: 2026, month: 10, day: 5))
    let trip = Event(name: "Trip", kind: .trip, startDate: days.0, endDate: days.1)
    let sameTrip = Event(name: "Trip to Kazan", kind: .trip, startDate: days.0, endDate: days.1)
    for person in [keep, duplicate] { try references.save(person) }
    for method in [card, sameCard] { try references.save(method) }
    for event in [trip, sameTrip] { try references.save(event) }

    let payment = ScheduledPayment(
      name: "Cinema", kind: .subscription, amountE4: AmountE4(whole: 499),
      paymentMethodId: sameCard.id, forWhom: .partner, forPersonId: duplicate.id,
      reimbursable: true, debtorPersonId: duplicate.id, day: 12)
    let income = ExpectedIncome(name: "Help", personId: duplicate.id, totalE4: AmountE4(whole: 100))
    _ = try planning.apply(
      PlanningChange(upsert: PlanningRows(scheduled: [payment], expected: [income])))
    let mappingId = UUID()
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO import_mappings (id, source_kind, source_category, target_for_person_id,
            target_event_id)
          VALUES (?, 'expense', 'Trips', ?, ?)
          """,
        arguments: [mappingId.uuidString, duplicate.id.uuidString, sameTrip.id.uuidString])
    }

    try references.mergePerson(duplicate.id, into: keep.id)
    try references.mergePaymentMethod(sameCard.id, into: card.id)
    try references.mergeEvent(sameTrip.id, into: trip.id)

    let movedPayment = try #require(try planning.scheduled().first)
    #expect(movedPayment.forPersonId == keep.id)
    #expect(movedPayment.debtorPersonId == keep.id)
    #expect(movedPayment.paymentMethodId == card.id)
    #expect(try planning.expected().first?.personId == keep.id)
    let mapping = try stack.writer.read { db in
      try Row.fetchOne(
        db,
        sql: "SELECT target_for_person_id, target_event_id FROM import_mappings WHERE id = ?",
        arguments: [mappingId.uuidString])
    }
    #expect(mapping?["target_for_person_id"] == keep.id.uuidString)
    #expect(mapping?["target_event_id"] == trip.id.uuidString)
  }

  /// A merge moves what the list names; the schema is what points. A foreign key a later
  /// migration adds to people, places, cards or events must join the list, or the merge
  /// leaves it on the archived duplicate.
  @Test func theMergeKnowsEveryColumnThatPointsAtADictionary() throws {
    let stack = try TestSupport.makeStack()
    let dictionaries = Set(ReferenceRepository.mergedColumns.keys)
    let pointing = try stack.writer.read { db in
      var found: [String: Set<String>] = [:]
      let tables = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
      for table in tables {
        for key in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))") {
          let parent: String = key["table"]
          guard dictionaries.contains(parent) else { continue }
          found[parent, default: []].insert("\(table).\(key["from"] as String)")
        }
      }
      return found
    }

    let listed = ReferenceRepository.mergedColumns.mapValues {
      Set($0.map { "\($0.table).\($0.column)" })
    }
    #expect(listed == pointing)
  }

  @Test func mergingIntoItselfDoesNothing() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let person = Person(name: "Sam")
    try references.save(person)

    try references.mergePerson(person.id, into: person.id)
    #expect(try references.people().count == 1)
  }
}
