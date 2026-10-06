import AppKit
import SwiftUI

/// Transactions, Analytics and Reports open as tabs of the main window rather than as windows
/// of their own.
///
/// Each is still a scene of its own — its state, toolbar and minimum size are its own — but its
/// window joins the tab group of the main window as soon as it is on screen. In full screen a
/// window of its own took a Space of its own and carried the owner away from the main window;
/// as a tab it opens in the main window's Space. With no main window on screen the window
/// opens on its own, as before. The Settings window carries no mark and is never a tab.
@MainActor
enum WindowTabs {
  /// What a window is to the tabs.
  enum Role: Equatable {
    /// The window the others become tabs of.
    case main
    /// A window that becomes a tab of the main one; `scene` is the id of its scene.
    case secondary(scene: String)
  }

  /// A main window as the decision sees it.
  struct Host<Key: Hashable>: Equatable {
    var key: Key
    /// On screen: not closed, not in the Dock.
    var isVisible: Bool
    var isKey: Bool
    var isFullScreen: Bool
  }

  enum Decision<Key: Hashable>: Equatable {
    /// No main window to join: the window stays a window of its own.
    case alone
    /// The window is a tab of a main window already.
    case alreadyTabbed
    /// The window becomes a tab of this main window.
    case join(Key)
  }

  /// Which main window a secondary one joins. `mains` are front to back; `tabbedWith` are the
  /// windows of the secondary one's tab group; `isFullScreen` says whether the secondary window
  /// is in full screen by itself — a Space of its own the owner made, which is left alone.
  ///
  /// A main window in full screen is joined like any other: the tab opens in its Space.
  nonisolated static func decide<Key: Hashable>(
    tabbedWith: Set<Key>, mains: [Host<Key>], isFullScreen: Bool = false
  ) -> Decision<Key> {
    if mains.contains(where: { tabbedWith.contains($0.key) }) { return .alreadyTabbed }
    guard !isFullScreen else { return .alone }
    let visible = mains.filter(\.isVisible)
    guard let host = visible.first(where: \.isKey) ?? visible.first else { return .alone }
    return .join(host.key)
  }

  /// Shared by every window of the app that may be a tab, so «Merge All Windows» of the Window
  /// menu and the system's own tabbing put them together.
  static let tabbingIdentifier = "io.github.EvgenyBaulin.itogo.windows"

  private static let mains = NSHashTable<NSWindow>.weakObjects()
  private static let secondaries = NSMapTable<NSString, NSWindow>.strongToWeakObjects()

  static func mark(_ window: NSWindow, as role: Role) {
    window.tabbingIdentifier = tabbingIdentifier
    switch role {
    case .main: mains.add(window)
    case .secondary(let scene): secondaries.setObject(window, forKey: scene as NSString)
    }
  }

  /// Puts a secondary window among the tabs of the main window, when there is one on screen,
  /// and shows it there. Returns what was decided.
  @discardableResult
  static func join(_ window: NSWindow) -> Decision<ObjectIdentifier> {
    let order = NSApp.orderedWindows.map(ObjectIdentifier.init)
    func rank(_ window: NSWindow) -> Int {
      order.firstIndex(of: ObjectIdentifier(window)) ?? order.count
    }
    let candidates = mains.allObjects.filter { $0 !== window }.sorted { rank($0) < rank($1) }
    let decision = decide(
      tabbedWith: Set((window.tabbedWindows ?? []).map(ObjectIdentifier.init)),
      mains: candidates.map {
        Host(
          key: ObjectIdentifier($0), isVisible: $0.isVisible && !$0.isMiniaturized,
          isKey: $0.isKeyWindow, isFullScreen: $0.styleMask.contains(.fullScreen))
      },
      isFullScreen: window.styleMask.contains(.fullScreen))
    switch decision {
    case .join(let key):
      guard let host = candidates.first(where: { ObjectIdentifier($0) == key }) else { break }
      host.addTabbedWindow(window, ordered: .above)
      host.tabGroup?.selectedWindow = window
      AppLog.info("windows.tabJoined", .ui, "a secondary window became a tab of the main one")
    case .alreadyTabbed:
      window.tabGroup?.selectedWindow = window
    case .alone:
      break
    }
    return decision
  }

  /// Opens a secondary window the way its menu item and its toolbar button do. One that is open
  /// already, but out of the tabs — opened with no main window, or dragged out — comes back
  /// among them; a new one joins them by its mark (`windowTab`).
  static func open(_ scene: String, with openWindow: OpenWindowAction) {
    openWindow(id: scene)
    Task { @MainActor in
      // After SwiftUI has ordered the window in.
      await Task.yield()
      if let window = secondaries.object(forKey: scene as NSString), window.isVisible {
        join(window)
      }
    }
  }

  /// Waits for a marked secondary window to come on screen, then joins it to the main one.
  fileprivate static func joinWhenShown(_ window: NSWindow) {
    Task { @MainActor [weak window] in
      // A window is ordered in shortly after its content moves into it; two seconds is
      // far more than SwiftUI takes, and a window never shown is not waited for longer.
      for _ in 0..<40 {
        guard let window else { return }
        if window.isVisible {
          join(window)
          return
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
  }
}

extension View {
  /// Marks the window this view is in for the tabs (`WindowTabs`).
  func windowTab(_ role: WindowTabs.Role) -> some View {
    background(WindowTabMark(role: role))
  }
}

private struct WindowTabMark: NSViewRepresentable {
  let role: WindowTabs.Role

  func makeNSView(context: Context) -> NSView { Anchor(role: role) }
  func updateNSView(_ view: NSView, context: Context) {}

  private final class Anchor: NSView {
    let role: WindowTabs.Role

    init(role: WindowTabs.Role) {
      self.role = role
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      WindowTabs.mark(window, as: role)
      if case .secondary = role { WindowTabs.joinWhenShown(window) }
    }
  }
}
