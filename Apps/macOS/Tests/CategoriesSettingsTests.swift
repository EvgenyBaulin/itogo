import AppCore
import XCTest

@testable import Itogo

/// The row that adds a category in Settings → Categories (`categories` — два
/// уровня, категория → подкатегория, `kind` expense/income).
@MainActor
final class CategoriesSettingsTests: XCTestCase {
  private let home = CoreKit.Category(kind: .expense, name: "Home", quality: .neutral)
  private let salary = CoreKit.Category(kind: .income, name: "Salary")
  private let old = CoreKit.Category(
    kind: .expense, name: "Old", archived: true, quality: .neutral)
  private lazy var rent = CoreKit.Category(parentId: home.id, kind: .expense, name: "Rent")
  private lazy var all = [home, salary, old, rent]

  /// Chosen under «Расходы» and kept when the switch went to «Доходы», the parent was an
  /// expense root under which an income category was saved: listed under «Дом» with a quality
  /// picker, reported by the tree as an expense, offered by no form.
  func testANewCategoryIsFiledOnlyUnderALiveRootOfItsOwnKind() {
    XCTAssertTrue(CategoriesSettingsView.acceptsParent(nil, for: .income, in: all))
    XCTAssertTrue(CategoriesSettingsView.acceptsParent(home.id, for: .expense, in: all))
    XCTAssertTrue(CategoriesSettingsView.acceptsParent(salary.id, for: .income, in: all))

    XCTAssertFalse(
      CategoriesSettingsView.acceptsParent(home.id, for: .income, in: all),
      "an income category was filed under an expense root")
    XCTAssertFalse(
      CategoriesSettingsView.acceptsParent(salary.id, for: .expense, in: all),
      "an expense category was filed under an income root")
    XCTAssertFalse(
      CategoriesSettingsView.acceptsParent(old.id, for: .expense, in: all),
      "a category was filed under an archived root")
    XCTAssertFalse(
      CategoriesSettingsView.acceptsParent(rent.id, for: .expense, in: all),
      "a third level was made under a subcategory")
    XCTAssertFalse(
      CategoriesSettingsView.acceptsParent(UUID(), for: .expense, in: all),
      "a category was filed under a parent that is not there")
  }

  /// A contribution to a goal is always good, whatever its subcategory says:
  /// the picker of Goals and of every goal's subcategory is disabled rather
  /// than silently ignored. A debt's subcategory under Loans and «Не помню» keep theirs: the
  /// quality there is only a default («оценка по умолчанию neutral»).
  func testTheQualityOfEverythingUnderGoalsIsFixedAndOnlyThere() {
    let goals = CoreKit.Category(kind: .expense, name: "Goals", systemRole: .goals)
    let bicycle = CoreKit.Category(parentId: goals.id, kind: .expense, name: "A bicycle")
    let loans = CoreKit.Category(kind: .expense, name: "Loans", systemRole: .loans)
    let mortgage = CoreKit.Category(parentId: loans.id, kind: .expense, name: "Mortgage")
    let unknown = CoreKit.Category(kind: .expense, name: "Unknown", systemRole: .unknown)
    let tree = CategoryTree([goals, bicycle, loans, mortgage, unknown, home, rent])

    XCTAssertTrue(CategoriesSettingsView.qualityIsFixed(goals, in: tree))
    XCTAssertTrue(
      CategoriesSettingsView.qualityIsFixed(bicycle, in: tree),
      "a goal's subcategory offered a quality the rules ignore")
    for free in [loans, mortgage, unknown, home, rent] {
      XCTAssertFalse(CategoriesSettingsView.qualityIsFixed(free, in: tree), free.name)
    }
  }

  /// A name is saved trimmed, and only when it says something new: « Дом » is «Дом», an empty
  /// field keeps the name that is stored, and a name typed back to what it was writes nothing.
  func testARenameIsSavedTrimmedAndOnlyWhenItChangesTheName() {
    XCTAssertEqual(CategoriesSettingsView.renamed(home, to: "  Жильё \n")?.name, "Жильё")
    XCTAssertEqual(CategoriesSettingsView.renamed(home, to: "Жильё")?.id, home.id)
    XCTAssertNil(CategoriesSettingsView.renamed(home, to: "   "), "an empty name was saved")
    XCTAssertNil(
      CategoriesSettingsView.renamed(home, to: "Home"), "the same name was written again")
    XCTAssertNil(
      CategoriesSettingsView.renamed(home, to: " Home "), "the same name, padded, was written")
  }

  func testTheRefusalIsSaidInBothLanguages() {
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let key = "categories.add.parentRefused"
      XCTAssertNotEqual(environment.language(key, table: "Settings"), key, "\(choice)")
    }
  }
}
