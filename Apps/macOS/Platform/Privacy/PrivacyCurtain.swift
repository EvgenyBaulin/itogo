import AppKit
import SwiftUI

/// The cover of a locked window: nothing of the books under it is drawn, read by VoiceOver or
/// reachable by a click or a key — the toolbar included —, and one button asks for Touch ID or
/// the password of the Mac. Every scene of the app wears it at its root (`ItogoApp`); a sheet or
/// a popover open when the lock comes is covered by `PrivacySheetCovers`.
struct PrivacyCurtain: ViewModifier {
  let lock: PrivacyLock
  let language: AppLanguage

  func body(content: Content) -> some View {
    let locked = lock.isLocked
    content
      .disabled(locked)
      .accessibilityHidden(locked)
      .overlay {
        if locked {
          LockCover(lock: lock, language: language)
        }
      }
      .onAppear {
        lock.startWatching()
        PrivacySheetCovers.update(locked: lock.isLocked)
      }
      .onChange(of: locked) { _, now in PrivacySheetCovers.update(locked: now) }
  }
}

extension View {
  /// Covers the window while `lock` is locked.
  func privacyCurtain(_ lock: PrivacyLock, language: AppLanguage) -> some View {
    modifier(PrivacyCurtain(lock: lock, language: language))
  }

  /// The cover of every scene: the lock of the app, in its language.
  @MainActor
  func privacyCurtain(_ environment: AppEnvironment) -> some View {
    privacyCurtain(environment.lock, language: environment.language)
  }
}

/// What a locked window shows: the padlock, «Итого заблокировано» and «Разблокировать».
struct LockCover: View {
  let lock: PrivacyLock
  let language: AppLanguage

  var body: some View {
    ZStack {
      Rectangle().fill(.background)
      VStack(spacing: 14) {
        Image(systemName: "lock.fill")
          .font(.system(size: 44))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
        Text(verbatim: language("privacy.locked.title"))
          .font(.title2.weight(.semibold))
        Text(verbatim: language("privacy.locked.hint"))
          .foregroundStyle(.secondary)
        Button {
          Task { await lock.unlock(reason: language("privacy.unlock.reason")) }
        } label: {
          Label {
            Text(verbatim: language("privacy.unlock"))
          } icon: {
            Image(systemName: "touchid")
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(lock.isAuthenticating)
        .accessibilityIdentifier("privacy.unlock")
        if let refusal = lock.lastRefusal, let key = Self.refusalKey(refusal) {
          Label {
            Text(verbatim: language(key))
          } icon: {
            Image(systemName: "exclamationmark.octagon")
          }
          .foregroundStyle(.red)
          .font(.callout)
        }
      }
      .padding(24)
    }
    .ignoresSafeArea()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("privacy.cover")
  }

  /// What the cover says after an attempt that did not pass; nothing after a cancel.
  static func refusalKey(_ refusal: LockAuthentication) -> String? {
    switch refusal {
    case .failed: "privacy.unlock.failed"
    case .unavailable: "privacy.unlock.unavailable"
    case .cancelled, .passed: nil
    }
  }
}

/// Sheets, popovers and other windows attached to a window of the app float above the cover of
/// their parent. While the app is locked each gets a plain cover of its own, an AppKit view on top
/// of its content, and loses it when the app is unlocked; the button to unlock stays on the
/// window underneath.
@MainActor
enum PrivacySheetCovers {
  static let identifier = NSUserInterfaceItemIdentifier("privacy.sheetCover")

  static func update(locked: Bool) {
    for window in NSApp.windows where window.sheetParent != nil || window.parent != nil {
      guard let content = window.contentView else { continue }
      let existing = content.subviews.filter { $0.identifier == identifier }
      if locked {
        guard existing.isEmpty else { continue }
        // dependencies: none — the cover reads nothing but a symbol.
        let cover = NSHostingView(rootView: SheetCover())
        cover.identifier = identifier
        cover.frame = content.bounds
        cover.autoresizingMask = [.width, .height]
        content.addSubview(cover, positioned: .above, relativeTo: nil)
      } else {
        existing.forEach { $0.removeFromSuperview() }
      }
    }
  }

  /// A cover with nothing to read on it but the padlock.
  private struct SheetCover: View {
    var body: some View {
      ZStack {
        Rectangle().fill(.background)
        Image(systemName: "lock.fill")
          .font(.system(size: 28))
          .foregroundStyle(.secondary)
      }
      .accessibilityHidden(true)
    }
  }
}
