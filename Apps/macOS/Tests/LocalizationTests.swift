import AppCore
import XCTest

@testable import Itogo

/// The language switch resolves strings against an explicitly chosen `.lproj` bundle, so
/// these tests check the mechanism the interface actually uses — not a copy of it.
@MainActor
final class LocalizationTests: XCTestCase {
  private var language: AppLanguage!

  override func setUp() async throws {
    language = AppLanguage()
  }

  func testEnglishIsTheBaseLanguage() {
    language.choice = .english
    XCTAssertEqual(language("app.name"), "Itogo")
    XCTAssertEqual(language("kind.expense"), "Expense")
    XCTAssertEqual(language("entry.placeholder", table: "Entry"), "coffee 250")
  }

  func testRussianComesFromItsOwnBundle() {
    language.choice = .russian
    XCTAssertEqual(language("app.name"), "Итого")
    XCTAssertEqual(language("kind.expense"), "Расход")
    XCTAssertEqual(language("entry.placeholder", table: "Entry"), "кофе 250")
    XCTAssertEqual(language("quality.bad"), "Плохие")
  }

  func testSwitchingBackAndForthKeepsWorking() {
    language.choice = .russian
    XCTAssertEqual(language("section.overview"), "Обзор")
    language.choice = .english
    XCTAssertEqual(language("section.overview"), "Overview")
  }

  /// «Перезапустить» is offered only when a restart would change something: the menu bar of
  /// macOS keeps the language of the launch. The language in use chosen again, or chosen back
  /// after another, offers nothing.
  func testTheRestartIsOfferedOnlyForALanguageOtherThanTheLaunchs() {
    let launch = language.resolvedCode
    XCTAssertFalse(language.needsRestart)
    language.choice = language.choice
    XCTAssertFalse(language.needsRestart, "the language in use chosen again offered a restart")
    language.choice = launch == "ru" ? .english : .russian
    XCTAssertTrue(language.needsRestart)
    language.choice = launch == "ru" ? .russian : .english
    XCTAssertFalse(language.needsRestart, "the language of the launch chosen back")
  }

  func testLocaleFollowsTheChoiceSoNumbersAndDatesMatch() {
    language.choice = .russian
    XCTAssertEqual(language.locale.identifier, "ru")
    XCTAssertEqual(language.resolvedCode, "ru")

    let money = MoneyFormatter(locale: language.locale)
    // A Russian locale groups thousands with a space and uses a comma for the fraction.
    let formatted = money.exact(AmountE4(raw: 12_345_500))
    XCTAssertTrue(formatted.contains("234"), formatted)
    XCTAssertTrue(formatted.contains("₽"), formatted)
  }

  /// «Системный» after an explicit choice follows the Mac again. Every choice wrote
  /// `AppleLanguages` into the app's own domain, «System» too, and «System» resolved through
  /// `Locale.preferredLanguages` — which reads that very key first. After English → Russian →
  /// System on an English Mac the app stayed Russian, wrote `["ru"]` back, and never followed
  /// a change of the Mac's language again.
  func testChoosingSystemAfterAnExplicitLanguageForgetsTheOverride() throws {
    let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
    let mac = Self.languageOfTheMac
    // The language the Mac is not in, so that staying in it is seen.
    let other: AppLanguage.Choice = mac == "ru" ? .english : .russian
    language.choice = other
    XCTAssertEqual(Self.override(in: domain), [other.rawValue])

    language.choice = .system

    XCTAssertNil(Self.override(in: domain), "«System» left the language of the earlier choice")
    XCTAssertEqual(language.resolvedCode, mac)
    XCTAssertEqual(AppLanguage().resolvedCode, mac, "the next launch")
  }

  /// A leftover of the defect above: «System» stored, and an explicit language still in the
  /// app's domain. «System» is the Mac's language, whatever the app wrote there before.
  func testSystemIsTheLanguageOfTheMacWhateverTheAppWroteBefore() throws {
    let mac = Self.languageOfTheMac
    let other = mac == "ru" ? "en" : "ru"
    UserDefaults.standard.set("system", forKey: AppDefaultsGuard.languageKey)
    UserDefaults.standard.set([other], forKey: AppDefaultsGuard.appleLanguagesKey)

    XCTAssertEqual(AppLanguage().resolvedCode, mac)
  }

  /// A launch settles only what the app's own domain holds. A UI test starts the app with
  /// `-app.language en`: the arguments of that launch must not become the owner's language.
  func testSettlingReadsTheDomainAndNotTheArgumentsOfTheLaunch() throws {
    let suite = "itogo.tests.settle.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    // A leftover of the defect: «System», and a language in the override.
    defaults.set("system", forKey: AppDefaultsGuard.languageKey)
    defaults.set(["ru"], forKey: AppDefaultsGuard.appleLanguagesKey)
    AppLanguage.settle(in: defaults, domain: suite)
    XCTAssertNil(defaults.persistentDomain(forName: suite)?[AppDefaultsGuard.appleLanguagesKey])

    // An explicit choice without its override (an archive imported before the fix).
    defaults.set("en", forKey: AppDefaultsGuard.languageKey)
    AppLanguage.settle(in: defaults, domain: suite)
    XCTAssertEqual(
      defaults.persistentDomain(forName: suite)?[AppDefaultsGuard.appleLanguagesKey] as? [String],
      ["en"])

    // Nothing chosen in the domain: nothing is written, whatever a lookup through the
    // arguments of the launch would answer.
    let empty = "itogo.tests.settle.\(UUID().uuidString)"
    let untouched = try XCTUnwrap(UserDefaults(suiteName: empty))
    defer { untouched.removePersistentDomain(forName: empty) }
    AppLanguage.settle(in: untouched, domain: empty)
    XCTAssertNil(untouched.persistentDomain(forName: empty))
  }

  /// The first language of the Mac itself — its global domain, never the app's — as the app
  /// can use it.
  private static var languageOfTheMac: String {
    let global = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)
    let first = (global?["AppleLanguages"] as? [String])?.first ?? "en"
    return first.hasPrefix("ru") ? "ru" : "en"
  }

  private static func override(in domain: String) -> [String]? {
    UserDefaults.standard.persistentDomain(forName: domain)?[AppDefaultsGuard.appleLanguagesKey]
      as? [String]
  }

  func testMissingKeysFallBackToTheKeyItself() {
    language.choice = .english
    XCTAssertEqual(language("no.such.key"), "no.such.key")
  }

  /// Nothing chosen yet means the language of the Mac: Russian on a Russian system, English
  /// on any other (README). The choice already stored by the other tests is
  /// put back afterwards.
  func testWithNothingChosenTheLanguageFollowsTheSystem() {
    let key = "app.language"
    let stored = UserDefaults.standard.object(forKey: key)
    defer { UserDefaults.standard.set(stored, forKey: key) }
    UserDefaults.standard.removeObject(forKey: key)

    let fresh = AppLanguage()
    XCTAssertEqual(fresh.choice, .system)
    let system = Locale.preferredLanguages.first ?? "en"
    XCTAssertEqual(fresh.resolvedCode, system.hasPrefix("ru") ? "ru" : "en")
  }

  /// Every caption the interface shows comes from the catalogue. A key that resolves to
  /// itself is a string somebody typed straight into a view.
  func testTheCaptionsOfTheEntryLineAreTranslatedInBothLanguages() {
    let keys = [
      "entry.error.rateMissing", "entry.error.notSaved", "entry.error.noDependencies",
      "entry.error.amountTooLarge", "entry.error.amountNegative",
      "templates.pin", "templates.unpin",
      "reimbursement.sharesExceedReceived", "reimbursement.shareExceedsPart",
      "reimbursement.partGone", "reimbursement.noSurcharges", "owed.writeOffFailed",
      "reimbursement.differentPeople", "entry.error.placeNotCreated",
      "entry.error.personNotCreated",
    ]
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys {
        let value = language(key, table: "Entry")
        XCTAssertNotEqual(value, key, "\(key) is missing in \(choice.rawValue)")
      }
    }
  }

  /// A failed step of the pipeline names what failed, like the forecast's «Не удалось
  /// посчитать прогноз», not the generic sentence of an unknown step; and its message, and
  /// the one of a skipped step, is a caption of the catalogue in both languages.
  func testEveryStepOfThePipelineSaysWhatFailedInBothLanguages() {
    let generic = ComputeStep.failureKey("no-such-step")
    let unnamed = ComputeStep.all.filter { ComputeStep.failureKey($0) == generic }
    XCTAssertEqual(unnamed.map(\.rawValue), [], "steps without a message of their own")
    let keys = ComputeStep.all.map(ComputeStep.failureKey) + [generic, ComputeStep.skippedKey]
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys {
        XCTAssertNotEqual(language(key), key, "\(key) is missing in \(choice.rawValue)")
      }
    }
  }

  /// Settings → Appearance: the tab, both pickers and both footers. The names
  /// of the themes and of the accent colours are checked beside the model they belong to
  /// (`AppThemeTests`), so a new option without a translation fails there.
  func testTheCaptionsOfAppearanceAreTranslatedInBothLanguages() {
    let keys = [
      "settings.tab.appearance", "settings.appearance.scheme", "settings.appearance.hint",
      "settings.appearance.accent", "settings.appearance.accentHint",
    ]
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys {
        let value = language(key, table: "Settings")
        XCTAssertNotEqual(value, key, "\(key) is missing in \(choice.rawValue)")
      }
    }
  }

  /// The Debug menu is not shipped, but it is read in the language the app speaks like
  /// everything else: keys, not literals. A count in a caption is a
  /// plural entry, so twelve and twenty-four months read right in Russian.
  func testTheCaptionsOfTheDebugMenuAreTranslatedInBothLanguages() {
    let keys = [
      "debug.menu", "debug.generate", "debug.pipeline", "debug.stepFailure", "debug.step.rates",
      "debug.step.data", "debug.step.forecast", "debug.openDataFolder",
    ]
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys {
        XCTAssertNotEqual(language(key), key, "\(key) is missing in \(choice.rawValue)")
      }
      for key in ["debug.generateMonths", "debug.generateLarge", "debug.slowDown"] {
        XCTAssertNotEqual(language(key), key, "\(key) is missing in \(choice.rawValue)")
      }
    }
    language.choice = .russian
    XCTAssertEqual(
      language.format("debug.generateMonths", 12), "Создать образец данных (12 месяцев)")
    XCTAssertEqual(
      language.format("debug.generateLarge", 24), "Создать большой образец (24 месяца)")
    XCTAssertEqual(language.format("debug.slowDown", 3), "Замедлить (3 секунды на шаг)")
    language.choice = .english
    XCTAssertEqual(language.format("debug.generateMonths", 12), "Generate sample data (12 months)")
  }

  /// Every string table the app ships, compiled into the bundle — never read from the
  /// repository: each key of the English table is in the Russian one and says
  /// something, plural forms included (one, few, many and other in Russian).
  func testEveryEnglishKeyIsTranslatedIntoRussian() throws {
    let english = try XCTUnwrap(Bundle.main.url(forResource: "en", withExtension: "lproj"))
    let russian = try XCTUnwrap(Bundle.main.url(forResource: "ru", withExtension: "lproj"))
    let tables = try FileManager.default.contentsOfDirectory(atPath: english.path)
      .filter { $0.hasSuffix(".strings") || $0.hasSuffix(".stringsdict") }
    XCTAssertTrue(tables.contains("Common.strings"), "\(tables)")
    XCTAssertTrue(tables.contains("Overview.strings"), "\(tables)")
    XCTAssertTrue(tables.contains("Analytics.strings"), "\(tables)")
    XCTAssertTrue(tables.contains("Analytics.stringsdict"), "\(tables)")
    XCTAssertTrue(tables.contains("Reports.strings"), "\(tables)")
    XCTAssertTrue(tables.contains("Planning.strings"), "\(tables)")
    XCTAssertTrue(tables.contains("Planning.stringsdict"), "\(tables)")
    XCTAssertTrue(tables.contains("Debts.strings"), "\(tables)")

    for table in tables {
      let source = try XCTUnwrap(
        NSDictionary(contentsOf: english.appendingPathComponent(table)) as? [String: Any], table)
      let translated =
        NSDictionary(contentsOf: russian.appendingPathComponent(table)) as? [String: Any] ?? [:]
      for key in source.keys {
        if table.hasSuffix(".stringsdict") {
          let plural = (translated[key] as? [String: Any])?.values
            .compactMap { $0 as? [String: Any] }
            .first { $0["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType" }
          for form in ["one", "few", "many", "other"] {
            let text = plural?[form] as? String ?? ""
            XCTAssertFalse(text.isEmpty, "\(table): \(key) has no Russian «\(form)»")
          }
        } else {
          let text = (translated[key] as? String ?? "").trimmingCharacters(in: .whitespaces)
          XCTAssertFalse(text.isEmpty, "\(table): \(key) has no Russian text")
        }
      }
    }
  }

  /// A Russian text is not the English one copied over: «Pinball loss P10 / P50 / P90» stood
  /// in the Russian table of Analytics as the only English caption of the Russian interface.
  /// A text with a Latin word the same in both languages is one of the few that are meant to
  /// be: the badge of a Debug build and the name of English written in English.
  func testNoRussianTextIsTheEnglishOneCopiedOver() throws {
    let meantToBeTheSame: Set<String> = ["common.debugBadge", "settings.language.en"]
    let word = try NSRegularExpression(pattern: "[A-Za-z]{3,}")
    let specifier = try NSRegularExpression(pattern: "%([0-9]+\\$)?(@|lld|ld|d|f)")
    let english = try XCTUnwrap(Bundle.main.url(forResource: "en", withExtension: "lproj"))
    let russian = try XCTUnwrap(Bundle.main.url(forResource: "ru", withExtension: "lproj"))
    let tables = try FileManager.default.contentsOfDirectory(atPath: english.path)
      .filter { $0.hasSuffix(".strings") }
    XCTAssertTrue(tables.contains("Analytics.strings"), "\(tables)")
    for table in tables {
      let source = try XCTUnwrap(
        NSDictionary(contentsOf: english.appendingPathComponent(table)) as? [String: String],
        table)
      let translated =
        NSDictionary(contentsOf: russian.appendingPathComponent(table)) as? [String: String]
        ?? [:]
      for (key, text) in source where translated[key] == text && !meantToBeTheSame.contains(key) {
        let bare = specifier.stringByReplacingMatches(
          in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        XCTAssertNil(
          word.firstMatch(in: bare, range: NSRange(bare.startIndex..., in: bare)),
          "\(table): «\(key)» is English in the Russian table — «\(text)»")
      }
    }
  }

  /// Nothing the owner can read names a milestone of this project. «Появится в M6» stood in
  /// the Analytics window and «плановые платежи — с M6» under the forecast long after both
  /// were built, and the owner found them himself on 21.09. A milestone is
  /// how the work was planned; it says nothing to whoever is using the app.
  func testNoCaptionNamesAMilestone() throws {
    let pattern = try NSRegularExpression(pattern: "(^|[^A-Za-z0-9])M[0-9]([^0-9]|$)")
    for code in ["en", "ru"] {
      let folder = try XCTUnwrap(Bundle.main.url(forResource: code, withExtension: "lproj"))
      let tables = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        .filter { $0.hasSuffix(".strings") }
      for table in tables {
        let strings = try XCTUnwrap(
          NSDictionary(contentsOf: folder.appendingPathComponent(table)) as? [String: Any], table)
        for (key, value) in strings {
          guard let text = value as? String else { continue }
          let range = NSRange(text.startIndex..., in: text)
          XCTAssertNil(
            pattern.firstMatch(in: text, range: range),
            "\(code)/\(table): «\(key)» names a milestone — «\(text)»")
        }
      }
    }
  }

  /// The catalogue walk above cannot see a milestone written straight into a view — and that
  /// is exactly what the owner found on 21.09: «Появится в M6» was `compute.plannedFor`
  /// composed at runtime with the Swift literal `stage: "M6"`. So the two lists that can
  /// produce such a caption are asserted empty here, beside the walk.
  func testNothingIsLeftToAnnounceAMilestoneWith() {
    XCTAssertTrue(
      ComputeStep.stubs.isEmpty,
      "a step of the pipeline is a placeholder again: \(ComputeStep.stubs)")
    for section in AnalyticsSection.allCases {
      XCTAssertNil(section.plannedFor, "\(section) announces a milestone")
    }
  }

  /// «Итого» is a total, «Разница» the difference of income and spending, and «Повторить»
  /// on a failed block is not «Redo».
  func testTotalNetAndRetryAreThreeDifferentWords() {
    language.choice = .russian
    XCTAssertEqual(language("common.total"), "Итого")
    XCTAssertEqual(language("common.net"), "Разница")
    XCTAssertEqual(language("action.retry"), "Повторить")
    language.choice = .english
    XCTAssertEqual(language("common.total"), "Total")
    XCTAssertEqual(language("common.net"), "Net")
    XCTAssertEqual(language("action.retry"), "Retry")
    XCTAssertEqual(language("action.redo"), "Redo")
  }

  /// The parts an expected income comes in are one phrase in every number: «В 1 часть», «В 2
  /// части», «В 5 частей» — not «1 частью» next to «В 2 части».
  func testThePartsOfAnExpectedIncomeAreOnePhraseInEveryNumber() {
    language.choice = .russian
    func parts(_ count: Int) -> String {
      language.format("form.expected.parts", table: "Planning", count)
    }
    XCTAssertEqual(parts(1), "В 1 часть")
    XCTAssertEqual(parts(2), "В 2 части")
    XCTAssertEqual(parts(5), "В 5 частей")
    XCTAssertEqual(parts(11), "В 11 частей")
    language.choice = .english
    XCTAssertEqual(parts(1), "In 1 part")
    XCTAssertEqual(parts(3), "In 3 parts")
  }

  /// The words that go with the symbol of a part paid for somebody else.
  func testTheReimbursementStatusesAreTranslatedInBothLanguages() {
    language.choice = .russian
    XCTAssertEqual(language(Palette.reimbursementKey(.expected)), "ждёт")
    XCTAssertEqual(language(Palette.reimbursementKey(.returned)), "вернули")
    XCTAssertEqual(language(Palette.reimbursementKey(.writtenOff)), "списано")
    language.choice = .english
    XCTAssertEqual(language(Palette.reimbursementKey(.writtenOff)), "written off")
  }

  /// The question before a category goes counts operations and subcategories, and Russian
  /// declines both the noun and the verb with the number: «лежит 1 операция», «лежат
  /// 2 операции», «лежат 5 операций», «лежит 21 операция».
  func testTheQuestionBeforeACategoryGoesDeclinesItsCounts() {
    let food = CoreKit.Category(kind: .expense, name: "Еда", sort: 100, quality: .neutral)
    func message(children: Int = 0, live: Int = 0, binned: Int = 0) -> String {
      CategoryDeletionText.message(
        .init(category: food, children: children, live: live, binned: binned), language)
    }
    language.choice = .russian
    let used = [
      1: "В «Еда» лежит 1 операция.", 2: "В «Еда» лежат 2 операции.",
      5: "В «Еда» лежат 5 операций.", 21: "В «Еда» лежит 21 операция.",
    ]
    for (count, sentence) in used {
      XCTAssertTrue(message(live: count).hasPrefix(sentence), message(live: count))
    }
    let blocked = [
      1: "На «Еда» ссылается 1 удалённая операция, а её перенести нечем.",
      3: "На «Еда» ссылаются 3 удалённые операции, а их перенести нечем.",
      5: "На «Еда» ссылаются 5 удалённых операций, а их перенести нечем.",
    ]
    for (count, sentence) in blocked {
      XCTAssertTrue(message(binned: count).hasPrefix(sentence), message(binned: count))
    }
    let children = [
      1: "«Еда» и 1 её подкатегория ничем не заняты.",
      2: "«Еда» и 2 её подкатегории ничем не заняты.",
      5: "«Еда» и 5 её подкатегорий ничем не заняты.",
    ]
    for (count, sentence) in children {
      XCTAssertTrue(message(children: count).hasPrefix(sentence), message(children: count))
    }

    language.choice = .english
    let english = [
      (message(live: 1), "1 operation is filed under «Еда»."),
      (message(live: 2), "2 operations are filed under «Еда»."),
      (message(binned: 1), "«Еда» is used by 1 operation in the bin, and it cannot be moved."),
      (message(binned: 2), "«Еда» is used by 2 operations in the bin, and those cannot be moved."),
      (message(children: 1), "«Еда» and its 1 subcategory are used by nothing."),
      (message(children: 2), "«Еда» and its 2 subcategories are used by nothing."),
    ]
    for (text, sentence) in english {
      XCTAssertTrue(text.hasPrefix(sentence), text)
    }
  }

  /// How often a template was used, under it in Settings → Шаблоны: «использован 2 раза»,
  /// never «использован раз: 2» or «used 1 times».
  func testTheUseCountOfATemplateIsDeclined() {
    func used(_ count: Int) -> String {
      language.format("templates.used", table: "Settings", count)
    }
    language.choice = .russian
    XCTAssertEqual(used(1), "использован 1 раз")
    XCTAssertEqual(used(2), "использован 2 раза")
    XCTAssertEqual(used(5), "использован 5 раз")
    XCTAssertEqual(used(22), "использован 22 раза")
    language.choice = .english
    XCTAssertEqual(used(1), "used 1 time")
    XCTAssertEqual(used(2), "used 2 times")
  }
}

/// The currency list is capped at ten and the ruble always stays enabled.
final class CurrencySettingsTests: XCTestCase {
  func testTheDefaultListIsExactlyTheOneTheSpecificationNames() {
    let codes = CurrencyCode.defaultEnabled.map(\.code)
    XCTAssertEqual(
      codes, ["RUB", "USD", "EUR", "KZT", "CNY", "TRY", "AED", "GEL", "AMD", "THB"])
    XCTAssertEqual(codes.count, CurrencyCode.maxEnabled)
  }

  func testCurrencyCodesAreCaseInsensitiveAndUppercase() {
    XCTAssertEqual(CurrencyCode("usd"), CurrencyCode("USD"))
    XCTAssertEqual(CurrencyCode("uSd").code, "USD")
  }
}
