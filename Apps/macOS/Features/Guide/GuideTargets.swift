import AppCore
import SwiftUI

/// The places the guide points at: a view marks itself `.guideTarget("entry.line")`, and the
/// root of the window learns where it is. The tutorial frames the place of its current task;
/// «Показать, куда нажимать» darkens the window and names every place with its keys.
struct GuideTargetKey: PreferenceKey {
  static let defaultValue: [String: Anchor<CGRect>] = [:]
  static func reduce(
    value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { first, _ in first }
  }
}

extension View {
  /// Marks the place the guide may point at, by the id its tasks and labels use.
  func guideTarget(_ id: String) -> some View {
    anchorPreference(key: GuideTargetKey.self, value: .bounds) { [id: $0] }
  }

  /// The root of a window: the frame around the place of the current task, and the labels of
  /// «Показать, куда нажимать». `toolbar`: this root lies under the toolbar, and names its
  /// buttons in a strip along its top edge.
  func guideOverlay(_ guide: GuideStore, toolbar: Bool = false) -> some View {
    overlayPreferenceValue(GuideTargetKey.self) { anchors in
      GeometryReader { proxy in
        GuideOverlay(guide: guide, anchors: anchors, proxy: proxy, namesToolbar: toolbar)
      }
    }
  }
}

/// What «Показать, куда нажимать» names on the main window, with its keys on a Mac: the places
/// of the window by the frames of the views that mark them, and the buttons of the toolbar in a
/// strip under it — an item of the toolbar is drawn by AppKit and lends the window no place to
/// point at.
enum GuideLabels {
  struct Label {
    let target: String
    let key: String
    let keys: String?
  }

  static let main: [Label] = [
    Label(target: "entry.line", key: "guide.label.entry", keys: "⌘N"),
    Label(target: "entry.details.toggle", key: "guide.label.details", keys: "Tab"),
    Label(target: "sidebar.overview", key: "guide.label.overview", keys: "⌘1"),
    Label(target: "sidebar.planning", key: "guide.label.planning", keys: "⌘2"),
    Label(target: "sidebar.debts", key: "guide.label.debts", keys: "⌘3"),
    Label(target: "sidebar.spending", key: "guide.label.spending", keys: "↓"),
  ]

  static let toolbar: [Label] = [
    Label(target: "toolbar.transactions", key: "guide.label.transactions", keys: "⌘⇧T"),
    Label(target: "toolbar.reconcile", key: "guide.label.reconcile", keys: nil),
    Label(target: "toolbar.settings", key: "guide.label.settings", keys: "⌘,"),
  ]
}

private struct GuideOverlay: View {
  @Dependency(\.environment) private var environment
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let guide: GuideStore
  let anchors: [String: Anchor<CGRect>]
  let proxy: GeometryProxy
  let namesToolbar: Bool

  private func t(_ key: String) -> String { environment.language(key, table: "Guide") }

  var body: some View {
    ZStack(alignment: .topLeading) {
      if guide.showsWhereToClick {
        Color.black.opacity(0.45)
          .ignoresSafeArea()
          .contentShape(Rectangle())
          .onTapGesture { guide.showsWhereToClick = false }
          .accessibilityHidden(true)
        ForEach(GuideLabels.main, id: \.target) { label in
          if let anchor = anchors[label.target] {
            let frame = proxy[anchor]
            RoundedRectangle(cornerRadius: 8)
              .stroke(Color.white, lineWidth: 2)
              .frame(width: frame.width + 6, height: frame.height + 6)
              .position(x: frame.midX, y: frame.midY)
            labelView(label)
              .fixedSize()
              .position(
                x: min(max(frame.midX, 90), proxy.size.width - 90), y: max(frame.minY - 18, 14))
          }
        }
        if namesToolbar {
          HStack(spacing: 8) {
            Image(systemName: "arrow.up")
              .foregroundStyle(.white)
              .accessibilityHidden(true)
            ForEach(GuideLabels.toolbar, id: \.target) { label in labelView(label) }
          }
          .fixedSize()
          .padding(.top, 8)
          .padding(.trailing, 12)
          .frame(maxWidth: .infinity, alignment: .topTrailing)
        }
      } else if let task = guide.framedTask,
        let target = GuideCatalog.tutorial.tasks.first(where: { $0.id == task })?.hints.first?
          .target,
        let anchor = anchors[target]
      {
        let frame = proxy[anchor]
        RoundedRectangle(cornerRadius: 10)
          .stroke(Color.accentColor, lineWidth: 3)
          .frame(width: frame.width + 10, height: frame.height + 10)
          .position(x: frame.midX, y: frame.midY)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: guide.showsWhereToClick)
  }

  private func labelView(_ label: GuideLabels.Label) -> some View {
    HStack(spacing: 6) {
      Text(verbatim: t(label.key))
      if let keys = label.keys {
        Text(verbatim: keys)
          .font(.caption.monospaced())
          .padding(.horizontal, 5)
          .padding(.vertical, 1)
          .background(RoundedRectangle(cornerRadius: 4).fill(.background.secondary))
      }
    }
    .font(.callout)
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(RoundedRectangle(cornerRadius: 6).fill(.background))
    .accessibilityElement(children: .combine)
  }
}

/// Esc or a click anywhere closes «Показать, куда нажимать».
struct GuideWhereToClickKeys: ViewModifier {
  let guide: GuideStore

  func body(content: Content) -> some View {
    content.background {
      if guide.showsWhereToClick {
        Button("") { guide.showsWhereToClick = false }
          .keyboardShortcut(.cancelAction)
          .opacity(0)
          .accessibilityHidden(true)
      }
    }
  }
}
