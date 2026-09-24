import AppKit
import Foundation
import Observation
import SwiftUI

/// How the interface looks: light or dark, and the one accent colour of the app.
///
/// Unlike the language this needs no restart: both halves — the AppKit appearance and the SwiftUI
/// environment — take effect at once. It lives in `UserDefaults` and not in the `settings` table
/// for the same reason the language does: the first window is on screen before the database is open
/// (`AppEnvironment.start`), so there is nothing to read a theme from for the first frame.
@MainActor
@Observable
public final class AppTheme {
  /// Light, dark, or whatever the system says — the default.
  public enum Scheme: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var settingsKey: String { "settings.appearance.scheme.\(rawValue)" }

    /// `nil` means «do not override», for both halves below.
    public var colorScheme: ColorScheme? {
      switch self {
      case .system: nil
      case .light: .light
      case .dark: .dark
      }
    }

    /// What the AppKit half is set to: the alerts and the open/save panels the app puts up
    /// itself read `NSApp.effectiveAppearance` and nothing else.
    public var appearance: NSAppearance? {
      switch self {
      case .system: nil
      case .light: NSAppearance(named: .aqua)
      case .dark: NSAppearance(named: .darkAqua)
      }
    }
  }

  /// System colours only: they follow the dark theme and «Увеличить контраст» by themselves,
  /// and the app owns no hexadecimal value of its own.
  public enum Accent: String, CaseIterable, Sendable {
    case system
    /// The amber of the icon, as the system knows it.
    case amber
    case blue
    case teal
    case green
    case indigo
    case purple
    case pink
    case graphite

    public var settingsKey: String { "settings.appearance.accent.\(rawValue)" }

    /// The colour to paint with. `system` resolves to whatever the owner chose in System
    /// Settings, which is what `Color.accentColor` already means.
    public var color: Color {
      switch self {
      case .system: .accentColor
      case .amber: .orange
      case .blue: .blue
      case .teal: .teal
      case .green: .green
      case .indigo: .indigo
      case .purple: .purple
      case .pink: .pink
      case .graphite: .gray
      }
    }

    /// The same colour for `.tint(_:)`, where `nil` means «leave the system's alone»: a
    /// choice of `system` must not pin today's system accent into the view tree.
    public var tint: Color? { self == .system ? nil : color }
  }

  /// The two keys of `UserDefaults`. `nonisolated`, because an archive being imported writes
  /// them from off the main actor (`ArchiveImportFlow.applyPortableSettings`) and the test
  /// guard reads them before the first test.
  nonisolated static let schemeKey = "app.theme.scheme"
  nonisolated static let accentKey = "app.theme.accent"

  public var scheme: Scheme {
    didSet {
      guard scheme != oldValue else { return }
      UserDefaults.standard.set(scheme.rawValue, forKey: Self.schemeKey)
      applyAppearance()
    }
  }

  public var accent: Accent {
    didSet {
      guard accent != oldValue else { return }
      UserDefaults.standard.set(accent.rawValue, forKey: Self.accentKey)
    }
  }

  public init() {
    let defaults = UserDefaults.standard
    scheme = defaults.string(forKey: Self.schemeKey).flatMap(Scheme.init(rawValue:)) ?? .system
    accent = defaults.string(forKey: Self.accentKey).flatMap(Accent.init(rawValue:)) ?? .system
  }

  /// The AppKit half. It reaches the alerts and the open/save panels the app puts up itself
  /// (`FileCommands`, `ArchiveImportFlow`), the menu bar and every window at once;
  /// `preferredColorScheme` alone leaves a dark app with a light save panel.
  ///
  /// Not in the test host: there the app is somebody else's process to borrow, and a test
  /// that painted it dark would leave it dark (`AppEnvironment.isTestHost`).
  public func applyAppearance() {
    guard !AppEnvironment.isTestHost else { return }
    NSApp?.appearance = scheme.appearance
  }

  /// The SwiftUI half, handed down in `appDependencies(_:)`.
  public var colorScheme: ColorScheme? { scheme.colorScheme }
  public var accentColor: Color { accent.color }
  public var tint: Color? { accent.tint }
}
