import AppCore
import XCTest

@testable import Itogo

/// How the cards of Overview put the core's numbers into words: percents from
/// basis points, differences with their sign, whole rubles rounded half away from zero, and
/// no percent where there was nothing to compare with. Numbers are written one way in both
/// languages — comma thousands, a point before the fraction; only the words around them and
/// the space before «%» follow the language. The formatter is a plain value, so these run off
/// the main actor.
final class MoneyWordsTests: XCTestCase {
  private let russian = MoneyFormatter(locale: Locale(identifier: "ru"))
  private let english = MoneyFormatter(locale: Locale(identifier: "en"))
  /// The space before «₽» in both languages, and before «%» in Russian.
  private let space = "\u{00A0}"
  private let minus = "\u{2212}"

  /// Through `money(_:)` of the golden set, so a typo is a failed test that names it.
  private func rubles(_ text: String) -> AmountE4 {
    money(text)
  }

  func testASharePrintsWithOneDecimalInTheWindowsLanguage() {
    XCTAssertEqual(russian.percent(basisPoints: 3_333), "33.3\(space)%")
    XCTAssertEqual(english.percent(basisPoints: 3_333), "33.3%")
    XCTAssertEqual(russian.percent(basisPoints: 10_000), "100.0\(space)%")
    XCTAssertEqual(english.percent(basisPoints: 4), "0.0%")
    XCTAssertEqual(english.percent(basisPoints: 2_573, fractionDigits: 2), "25.73%")
    XCTAssertEqual(english.percent(basisPoints: 2_573, fractionDigits: 0), "26%")
  }

  /// A tie goes away from zero, on both sides — never to the even neighbour.
  func testTiesRoundAwayFromZero() {
    XCTAssertEqual(english.percent(basisPoints: 3_325), "33.3%")
    XCTAssertEqual(english.signedPercent(basisPoints: -3_325), "\(minus)33.3%")
    XCTAssertEqual(english.rounded(rubles("2.5")), "3\(space)₽")
    XCTAssertEqual(english.signedRounded(rubles("1234.5")), "+1,235\(space)₽")
    XCTAssertEqual(english.signedRounded(rubles("-1234.5")), "\(minus)1,235\(space)₽")
    XCTAssertEqual(russian.signedRounded(rubles("-3400")), "\(minus)3,400\(space)₽")
  }

  /// The sign is that of the figure as it is shown: forty kopecks down read as no change.
  func testTheSignIsThatOfTheRoundedFigure() {
    XCTAssertEqual(english.signedRounded(rubles("-0.4")), "0\(space)₽")
    XCTAssertEqual(english.signedRounded(.zero), "0\(space)₽")
    XCTAssertEqual(english.signedPercent(basisPoints: 834), "+8.3%")
    XCTAssertEqual(russian.signedPercent(basisPoints: -5_340), "\(minus)53.4\(space)%")
    XCTAssertEqual(english.signedPercent(basisPoints: 0), "0.0%")
    XCTAssertEqual(english.signedPercent(basisPoints: -4), "0.0%")
  }

  func testAChangeWithABaseHasBothHalves() {
    let text = russian.change(Change(current: rubles("19200"), previous: rubles("41200")))
    XCTAssertEqual(text.direction, .down)
    XCTAssertEqual(text.delta, "\(minus)22,000\(space)₽")
    XCTAssertEqual(text.percent, "\(minus)53.4\(space)%")
  }

  /// Nothing the period before: no percent at all, only the rubles.
  func testAChangeFromNothingHasNoPercent() {
    let text = english.change(Change(current: rubles("500"), previous: .zero))
    XCTAssertEqual(text.direction, .up)
    XCTAssertEqual(text.delta, "+500\(space)₽")
    XCTAssertNil(text.percent)
  }

  func testAChangeSmallerThanARubleIsFlat() {
    let text = english.change(Change(current: rubles("100.4"), previous: rubles("100")))
    XCTAssertEqual(text.direction, .flat)
    XCTAssertEqual(text.delta, "0\(space)₽")
    XCTAssertEqual(Palette.changeSymbol(text.direction), "equal")
  }

  /// A negative figure has the typographic minus wherever it is written — a day total, an
  /// exact amount, a bar, an axis — the same «−» as `signedRounded`, never the hyphen of the
  /// locale beside it.
  func testANegativeFigureHasTheTypographicMinusEverywhere() {
    XCTAssertEqual(russian.rounded(rubles("-3400")), "\(minus)3,400\(space)₽")
    XCTAssertEqual(english.rounded(rubles("-2.5")), "\(minus)3\(space)₽")
    XCTAssertEqual(russian.exact(rubles("-250")), "\(minus)250\(space)₽")
    XCTAssertEqual(english.rubles(-50), "\(minus)50\(space)₽")
    XCTAssertEqual(english.axis(-2_500_000), "\(minus)2.5M\(space)₽")
    XCTAssertEqual(russian.axis(-1_234_567), "\(minus)1.2\(space)млн\(space)₽")
    XCTAssertEqual(english.percent(basisPoints: -250), "\(minus)2.5%")
  }

  /// An axis label chooses millions or billions by the figure it prints: 999 950 000 rounds
  /// to a thousand millions, and that is one billion.
  func testAnAxisLabelThatRoundsToAThousandMillionsIsABillion() {
    XCTAssertEqual(russian.axis(999_950_000), "1\(space)млрд\(space)₽")
    XCTAssertEqual(english.axis(999_950_000), "1B\(space)₽")
    XCTAssertEqual(english.axis(-999_960_000), "\(minus)1B\(space)₽")
    XCTAssertEqual(english.axis(999_949_999), "999.9M\(space)₽")
    XCTAssertEqual(english.axis(1_000_000_000), "1B\(space)₽")
    XCTAssertEqual(english.axis(999_999), "999,999\(space)₽")
  }

  /// The exact amount of a list: a whole amount without a fraction, kopecks always
  /// as two digits, and the third and fourth digit of E4 only when there are any.
  func testAnExactAmountHasNoFractionOrAtLeastTwoDigits() {
    XCTAssertEqual(russian.exact(rubles("250")), "250\(space)₽")
    XCTAssertEqual(russian.exact(rubles("1234.5")), "1,234.50\(space)₽")
    XCTAssertEqual(english.exact(rubles("1234.5")), "1,234.50\(space)₽")
    XCTAssertEqual(russian.exact(rubles("0.07")), "0.07\(space)₽")
    XCTAssertEqual(russian.exact(rubles("12.345")), "12.345\(space)₽")
    XCTAssertEqual(english.exact(rubles("-0.0001")), "\(minus)0.0001\(space)₽")
    XCTAssertEqual(english.exact(rubles("-99.9"), currency: .usd), "\(minus)99.90\(space)$")
  }

  /// Whole rubles of a chart are written from the number itself. The largest of them have
  /// no E4 — `Int64.max` units round up to a ruble ten thousand units past it — so going
  /// back through `AmountE4` wrapped the sign in `rubles` and trapped in `AmountE4(whole:)`.
  func testTheLargestWholeRublesAreWrittenAsTheyAre() {
    let largest = AmountE4(raw: .max).wholeRubles
    XCTAssertEqual(largest, 922_337_203_685_478)
    XCTAssertEqual(english.rubles(largest), "922,337,203,685,478\(space)₽")
    XCTAssertEqual(english.rubles(-largest), "\(minus)922,337,203,685,478\(space)₽")
    XCTAssertEqual(english.signedRubles(largest), "+922,337,203,685,478\(space)₽")
    XCTAssertEqual(english.signedRubles(-largest), "\(minus)922,337,203,685,478\(space)₽")
    XCTAssertEqual(russian.signedRubles(-3_400), "\(minus)3,400\(space)₽")
    XCTAssertEqual(english.signedRubles(0), "0\(space)₽")
    XCTAssertEqual(english.axis(.min), "\(minus)9,223,372,036.9B\(space)₽")
  }
}

/// The layout rules and the words of the cards.
@MainActor
final class OverviewCardsTests: XCTestCase {
  func testTheGridHasThreeTwoOrOneColumnsByWidth() {
    XCTAssertEqual(OverviewCard.columns(forWidth: 1_200), 3)
    XCTAssertEqual(OverviewCard.columns(forWidth: 840), 3)
    XCTAssertEqual(OverviewCard.columns(forWidth: 839), 2)
    XCTAssertEqual(OverviewCard.columns(forWidth: 560), 2)
    XCTAssertEqual(OverviewCard.columns(forWidth: 559), 1)
    XCTAssertEqual(OverviewCard.columns(forWidth: 0), 1)
  }

  /// The cards keep their designed order in every width: the six of the first layout, the
  /// five of planning that took the place of the line «Появится позже», and the anomalies.
  func testTheCardsFillTheRowsInTheirOrder() {
    XCTAssertEqual(
      OverviewCard.rows(columns: 3),
      [
        [.monthToDate, .topCategories, .qualities], [.canSave, .forecast, .limits],
        [.upcoming, .expected, .owed], [.event, .reconciliation, .anomalies],
      ])
    XCTAssertEqual(OverviewCard.rows(columns: 2).count, 6)
    XCTAssertEqual(OverviewCard.rows(columns: 1).flatMap { $0 }, OverviewCard.allCases)
  }

  /// The bars: a share of the row for each weight, 2 pt between the visible segments, and
  /// no width — and no gap — for a bucket without a share.
  func testTheBarsShareTheRowByTheirWeights() {
    XCTAssertEqual(
      ProportionalRow.widths(of: 100, weights: [2_500, 2_500, 5_000], spacing: 2), [24, 24, 48])
    XCTAssertEqual(
      ProportionalRow.widths(of: 102, weights: [0, 3_000, 7_000], spacing: 2), [0, 30, 70])
    XCTAssertEqual(
      ProportionalRow.widths(of: 100, weights: [-500, 10_000], spacing: 2), [0, 100])
    XCTAssertEqual(ProportionalRow.widths(of: 100, weights: [0, 0, 0], spacing: 2), [0, 0, 0])
  }

  /// A card reads its part of a step: only `ready` goes through, and may turn into «Мало
  /// данных»; «Считается» and a failure with its message stay as they are.
  func testACardTakesItsStateFromItsStep() {
    let empty: (Int, Date) -> BlockState<Int> = { value, at in
      value == 0 ? .notEnoughData : .ready(value * 2, at: at)
    }
    let at = Date(timeIntervalSince1970: 0)
    XCTAssertEqual(BlockState.ready(3, at: at).flatMap(empty).value, 6)
    XCTAssertEqual(BlockState.ready(0, at: at).flatMap(empty).phase, .notEnoughData)
    XCTAssertEqual(BlockState<Int>.calculating.flatMap(empty).phase, .calculating)
    guard case .failed(let key) = BlockState<Int>.failed(messageKey: "k").flatMap(empty) else {
      return XCTFail("a failure stays a failure")
    }
    XCTAssertEqual(key, "k")
  }

  func testTheComparisonSaysThereWasNothingToCompareWith() {
    let environment = AppEnvironment()
    let span = DayRange(
      DateOnly(year: 2026, month: 8, day: 1), DateOnly(year: 2026, month: 8, day: 18))
    let fromNothing = Change(current: AmountE4(whole: 500), previous: .zero)
    let fromSomething = Change(current: AmountE4(whole: 1_100), previous: AmountE4(whole: 1_000))

    environment.language.choice = .english
    let english = OverviewText.comparison(
      environment.money.change(fromNothing), span: span, environment)
    XCTAssertTrue(english.hasSuffix("no data last month"), english)
    XCTAssertFalse(english.contains("%"), english)
    let englishBoth = OverviewText.comparison(
      environment.money.change(fromSomething), span: span, environment)
    XCTAssertTrue(englishBoth.contains("+10.0%"), englishBoth)
    XCTAssertTrue(englishBoth.contains("Aug"), englishBoth)

    environment.language.choice = .russian
    let russian = OverviewText.comparison(
      environment.money.change(fromNothing), span: span, environment)
    XCTAssertTrue(russian.hasSuffix("в прошлом месяце данных нет"), russian)
    let russianBoth = OverviewText.comparison(
      environment.money.change(fromSomething), span: span, environment)
    XCTAssertTrue(russianBoth.contains("+10.0\u{00A0}%"), russianBoth)
    XCTAssertTrue(russianBoth.contains("авг"), russianBoth)
  }

  /// Money without a category is named, and an archived root says so.
  func testTheLinesOfTheTopAreNamed() {
    let environment = AppEnvironment()
    var hobby = CoreKit.Category(kind: .expense, name: "Hobby")
    hobby.archived = true
    let tree = CategoryTree([hobby])

    environment.language.choice = .russian
    XCTAssertEqual(OverviewText.name(of: .uncategorized, tree: tree, environment), "Без категории")
    XCTAssertEqual(
      OverviewText.name(of: .category(hobby.id), tree: tree, environment), "Hobby (архив)")
    environment.language.choice = .english
    XCTAssertEqual(OverviewText.name(of: .uncategorized, tree: tree, environment), "Uncategorized")
  }

  /// Every caption the cards show is in both languages: a key that resolves to itself would
  /// show up on the card as it is.
  func testEveryCaptionOfTheCardsIsTranslated() {
    let environment = AppEnvironment()
    let keys = [
      "overview.monthToDate", "overview.expenses", "overview.income", "overview.comparison",
      "overview.comparisonNoBase", "overview.topCategories", "overview.noSpendingYet",
      "overview.qualities", "overview.badChange", "overview.owedNobody", "overview.forecast",
      "overview.forecastRange", "overview.forecastPlannedAmount", "overview.forecastComputedAt",
      "overview.forecastComputedOn", "overview.reconciliation", "overview.reconciliationNone",
      "overview.noRecent", "overview.anomalies", "overview.anomaliesNone",
      "overview.anomaliesMore",
    ]
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for key in keys {
        XCTAssertNotEqual(environment.language(key, table: "Overview"), key, "\(key), \(choice)")
      }
      for key in [
        "overview.canSave", "overview.limits", "overview.upcoming", "overview.expected",
        "overview.event", "reconcile.open", "advice.disclaimer",
      ] {
        XCTAssertNotEqual(environment.language(key, table: "Planning"), key, "\(key), \(choice)")
      }
      XCTAssertNotEqual(environment.language("category.uncategorized"), "category.uncategorized")
      XCTAssertNotEqual(
        environment.language("selection.writing", table: "Transactions"), "selection.writing")
    }
    environment.language.choice = .russian
    XCTAssertEqual(environment.format("owed.count", table: "Entry", 2), "ждут возврата: 2")
    XCTAssertEqual(environment.format("owed.count", table: "Entry", 1), "ждёт возврата: 1")
  }

  /// «Стоит посмотреть» is about the last month, as its empty line says: an anomaly of months
  /// ago neither fills the card nor counts in «и ещё N». A reimbursement still waiting is a
  /// state that holds today, whenever the money was paid, so it stays.
  func testTheAnomaliesCardListsTheLastMonthAndWhatStillHolds() {
    let today = DateOnly(year: 2026, month: 9, day: 23)
    func found(
      _ rule: AnomalyRule, _ subject: String, daysAgo: Int, hidden: Bool = false
    )
      -> Anomaly
    {
      Anomaly(
        rule: rule, subject: subject, day: today.adding(days: -daysAgo),
        amount: AmountE4(whole: 1_000), isHidden: hidden)
    }
    let old = found(.largeExpense, "old", daysAgo: 90)
    let fresh = found(.largeExpense, "fresh", daysAgo: 5)
    let monthAgo = found(.categorySpike, "month-ago", daysAgo: 31)
    let waiting = found(.slowReimbursement, "waiting", daysAgo: 45)
    let waved = found(.possibleDuplicate, "waved", daysAgo: 2, hidden: true)

    let report = AnomalyReport(all: [waved, fresh, monthAgo, waiting, old])
    XCTAssertEqual(
      OverviewText.recentAnomalies(report, today: today).map(\.subject),
      ["fresh", "month-ago", "waiting"])
    XCTAssertEqual(
      OverviewText.recentAnomalies(AnomalyReport(all: [old]), today: today).map(\.subject), [],
      "an anomaly of three months ago kept «За последний месяц ничего необычного» away")
  }
}
