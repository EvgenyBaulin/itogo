import AppCore
import AppDatabase
import AppKit
import XCTest

@testable import Itogo

/// «Перевести…» in the ↓ panel: the transfer sheet opens with the amount the panel holds, and
/// the editor of a saved operation does not offer it.
@MainActor
final class EntryTransferTests: XCTestCase {
  private var host: EntryHost?

  override func tearDown() async throws {
    if let sheet = host?.window.attachedSheet { host?.window.endSheet(sheet) }
    host?.close()
    host = nil
  }

  private func attribute(_ object: NSObject, _ name: String) -> Any? {
    guard object.responds(to: NSSelectorFromString(name)) else { return nil }
    return object.value(forKey: name)
  }

  /// The element of the window an identifier names, found the way VoiceOver finds it: a button
  /// of SwiftUI is no `NSButton` of the view tree.
  private func element(identified identifier: String, in window: NSWindow) -> NSObject? {
    var found: NSObject?
    func walk(_ element: Any) {
      guard found == nil, let object = element as? NSObject else { return }
      if attribute(object, "accessibilityIdentifier") as? String == identifier {
        found = object
        return
      }
      for child in attribute(object, "accessibilityChildren") as? [Any] ?? [] { walk(child) }
    }
    if let root = window.contentView { walk(root) }
    return found
  }

  func testThePanelOffersTheTransferAndTheSheetStartsWithItsAmount() async throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let host = try await EntryHost()
    self.host = host
    try host.type("250", into: try host.field(prompt: "0"))
    let button = try XCTUnwrap(
      element(identified: "entry.transfer", in: host.window), "the panel has no «Перевести…»")
    _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))

    let deadline = Date().addingTimeInterval(3)
    while host.window.attachedSheet == nil, Date() < deadline { host.settle(0.05) }
    let sheet = try XCTUnwrap(host.window.attachedSheet, "the sheet of the transfer was not shown")
    host.settle(0.5)
    XCTAssertTrue(
      host.textFields(in: sheet.contentView).contains { $0.stringValue == "250" },
      "the amount of the panel is what leaves")
  }
}
