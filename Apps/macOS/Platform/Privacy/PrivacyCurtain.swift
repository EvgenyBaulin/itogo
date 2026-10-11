import AppKit
import SwiftUI

/// The cover of a locked window: nothing of the books under it is drawn, read by VoiceOver or
/// reachable by a click or a key — the toolbar included —; the app's password, Touch ID or the
/// password of the Mac take it away (`LockCover`). Every scene of the app wears it at its root (`ItogoApp`); a sheet or
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

/// What a locked window shows: the padlock, «Итого заблокировано», and the way in — the app's
/// password (Return unlocks) beside «Touch ID», or Touch ID and the password of the Mac alone when
/// the app has no password of its own. After «Забыли пароль?» it asks for a new password.
struct LockCover: View {
  let lock: PrivacyLock
  let language: AppLanguage

  @State private var password = ""
  @FocusState private var fieldFocused: Bool

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
        if lock.isChoosingNewPassword {
          newPassword
        } else if lock.hasPassword {
          passwordEntry
        } else {
          Text(verbatim: language("privacy.locked.hint"))
            .foregroundStyle(.secondary)
          touchIDButton(prominent: true)
        }
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

  /// The app's password, «Разблокировать», «Touch ID», «Забыли пароль?», and what went wrong —
  /// with the seconds of a pause counted down.
  private var passwordEntry: some View {
    VStack(spacing: 12) {
      Text(verbatim: language("privacy.locked.passwordHint"))
        .foregroundStyle(.secondary)
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        let left = lock.secondsOfPauseLeft(at: lock.currentDate)
        VStack(spacing: 10) {
          SecureField(text: $password) {
            Text(verbatim: language("privacy.password"))
          }
          .textFieldStyle(.roundedBorder)
          .frame(width: 240)
          .focused($fieldFocused)
          .onSubmit(submit)
          .disabled(left > 0 || lock.isCheckingPassword)
          .accessibilityIdentifier("privacy.password")
          HStack(spacing: 10) {
            Button(action: submit) {
              Text(verbatim: language("privacy.unlock"))
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(left > 0 || lock.isCheckingPassword || password.isEmpty)
            .accessibilityIdentifier("privacy.unlock.password")
            touchIDButton(prominent: false)
          }
          if left > 0 {
            Label {
              Text(verbatim: language.format("privacy.password.pausedFor", counts: left))
            } icon: {
              Image(systemName: "hourglass")
            }
            .foregroundStyle(.secondary)
            .font(.callout)
            .accessibilityIdentifier("privacy.password.pause")
          } else if let key = PrivacyCurtain.problemKey(lock.passwordProblem) {
            Label {
              Text(verbatim: Self.problemText(lock.passwordProblem, key: key, language: language))
            } icon: {
              Image(systemName: "exclamationmark.octagon")
            }
            .foregroundStyle(.red)
            .font(.callout)
          }
        }
      }
      Button {
        password = ""
        Task { await lock.forgotPassword(reason: language("privacy.forgot.reason")) }
      } label: {
        Text(verbatim: language("privacy.password.forgot"))
      }
      .buttonStyle(.link)
      .disabled(lock.isAuthenticating)
      .accessibilityIdentifier("privacy.password.forgot")
    }
    .onAppear { fieldFocused = true }
  }

  /// After «Забыли пароль?»: a new password typed twice, or «Позже».
  private var newPassword: some View {
    VStack(spacing: 12) {
      Text(verbatim: language("privacy.password.chooseNew"))
        .foregroundStyle(.secondary)
      LockPasswordFields(
        language: language, problem: lock.passwordProblem, isBusy: lock.isCheckingPassword,
        saveTitleKey: "privacy.password.saveAndUnlock"
      ) { password in
        await lock.chooseNewPassword(password)
      }
      .frame(width: 280)
      Button {
        lock.putOffNewPassword()
      } label: {
        Text(verbatim: language("privacy.password.later"))
      }
      .buttonStyle(.link)
      .accessibilityIdentifier("privacy.password.later")
    }
  }

  /// Touch ID, or the password of the Mac where there is none: the main button when the app has
  /// no password of its own, the second one beside the password otherwise.
  @ViewBuilder
  private func touchIDButton(prominent: Bool) -> some View {
    let button = Button {
      Task { await lock.unlock(reason: language("privacy.unlock.reason")) }
    } label: {
      Label {
        Text(verbatim: language(prominent ? "privacy.unlock" : "privacy.unlock.touchID"))
      } icon: {
        Image(systemName: "touchid")
      }
    }
    .disabled(lock.isAuthenticating)
    if prominent {
      button
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("privacy.unlock")
    } else {
      button
        .buttonStyle(.bordered)
        .accessibilityIdentifier("privacy.unlock.touchID")
    }
  }

  private func submit() {
    guard !password.isEmpty else { return }
    let typed = password
    Task {
      let attempt = await lock.unlock(password: typed)
      if attempt != .ignored { password = "" }
      fieldFocused = true
    }
  }

  /// What the cover says after an attempt that did not pass; nothing after a cancel.
  static func refusalKey(_ refusal: LockAuthentication) -> String? {
    switch refusal {
    case .failed: "privacy.unlock.failed"
    case .unavailable: "privacy.unlock.unavailable"
    case .cancelled, .passed: nil
    }
  }

  /// The words of a problem of the password, with the attempts left where it has them.
  static func problemText(
    _ problem: PrivacyLock.PasswordProblem?, key: String, language: AppLanguage
  ) -> String {
    if case .wrong(let left) = problem { return language.format(key, counts: left) }
    return language(key)
  }
}

extension PrivacyCurtain {
  /// The key of what went wrong with a password; nothing when nothing did.
  static func problemKey(_ problem: PrivacyLock.PasswordProblem?) -> String? {
    switch problem {
    case .wrong: "privacy.password.wrong"
    case .paused: "privacy.password.paused"
    case .keychain: "privacy.password.keychain"
    case .tooShort: "privacy.password.tooShort"
    case nil: nil
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
