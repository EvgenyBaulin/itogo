import AppKit
import XCTest

@testable import Itogo

/// «О программе» ends with a way to thank the author: «Нравится Итого? Поддержать автора →»,
/// a link the default browser opens.
@MainActor
final class AboutPanelTests: XCTestCase {
  private func linkAndText(_ choice: AppLanguage.Choice) throws -> (URL, String) {
    let language = AppLanguage()
    language.choice = choice
    let credits = AboutPanel.credits(language)
    var link: URL?
    credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) {
      value, _, _ in
      if let url = value as? URL { link = url }
    }
    return (try XCTUnwrap(link, "no link in «\(credits.string)»"), credits.string)
  }

  func testTheCreditsLinkToTheSupportPageInRussian() throws {
    let (link, text) = try linkAndText(.russian)
    XCTAssertEqual(link, AboutPanel.supportURL)
    XCTAssertEqual(text, "Нравится Итого? Поддержать автора →")
  }

  func testTheCreditsLinkToTheSupportPageInEnglish() throws {
    let (link, text) = try linkAndText(.english)
    XCTAssertEqual(link, AboutPanel.supportURL)
    XCTAssertEqual(text, "Like Itogo? Support the author →")
  }

  func testTheSupportPageIsTheAuthorsOne() {
    XCTAssertEqual(AboutPanel.supportURL.absoluteString, "https://pay.cloudtips.ru/p/4b507463")
  }

  /// The item of the application menu opens the panel the app gives the credits to, not the
  /// standard one without them.
  func testTheMenuHasOneAboutItem() throws {
    let menu = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu, "no application menu")
    let about = menu.items.filter {
      $0.title.hasPrefix("About") || $0.title.hasPrefix("О программе")
    }
    XCTAssertEqual(about.count, 1, "\(menu.items.map(\.title))")
  }
}
