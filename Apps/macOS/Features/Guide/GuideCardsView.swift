import AppCore
import SwiftUI

/// The cards of the guide, one thought each: a picture, a title and a sentence or two. ← and →
/// or a swipe of the trackpad turn them, «Пропустить» is always there, the dots below say where
/// one is. With «Уменьшить движение» the cards change without sliding; VoiceOver reads a card
/// whole and the buttons by their names.
struct GuideCardsView: View {
  @Dependency(\.environment) private var environment
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let scenario: GuideScenario
  /// Closed: `true` when skipped before the last card.
  let finish: (_ skipped: Bool) -> Void

  @State private var index = 0
  @FocusState private var focused: Bool

  private var russian: Bool { environment.language.resolvedCode.hasPrefix("ru") }
  private func t(_ key: String) -> String { environment.language(key, table: "Guide") }

  private var isLast: Bool { index >= scenario.cards.count - 1 }

  var body: some View {
    VStack(spacing: 18) {
      HStack {
        Text(verbatim: title)
          .font(.headline)
          .foregroundStyle(.secondary)
        Spacer()
        Button(t("guide.skip")) { finish(!isLast) }
          .buttonStyle(.borderless)
          .keyboardShortcut(.cancelAction)
          .accessibilityIdentifier("guide.skip")
      }
      if scenario.cards.indices.contains(index) {
        card(scenario.cards[index])
          .id(index)
          .transition(
            reduceMotion
              ? .opacity : .asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
      }
      Spacer(minLength: 0)
      HStack(spacing: 12) {
        Button {
          turn(by: -1)
        } label: {
          Image(systemName: "chevron.left")
        }
        .disabled(index == 0)
        .accessibilityLabel(Text(verbatim: t("guide.previous")))
        dots
        Button {
          if isLast { finish(false) } else { turn(by: 1) }
        } label: {
          Text(verbatim: isLast ? t("guide.done") : t("guide.next"))
            .frame(minWidth: 90)
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier(isLast ? "guide.done" : "guide.next")
      }
    }
    .padding(24)
    .frame(width: 520, height: 400)
    .focusable()
    .focused($focused)
    .focusEffectDisabled()
    .onAppear { focused = true }
    .onKeyPress(.leftArrow) {
      turn(by: -1)
      return .handled
    }
    .onKeyPress(.rightArrow) {
      turn(by: 1)
      return .handled
    }
    // A swipe of two fingers on the trackpad, or a drag: left is the next card.
    .gesture(
      DragGesture(minimumDistance: 30).onEnded { value in
        if value.translation.width < -30 { turn(by: 1) }
        if value.translation.width > 30 { turn(by: -1) }
      }
    )
    .accessibilityIdentifier("guide.cards")
  }

  private var title: String {
    switch scenario.kind {
    case .firstLaunch: t("guide.firstLaunch.title")
    case .whatsNew(let version): String(format: t("guide.whatsNew.title"), "\(version)")
    case .tutorial: t("guide.tutorial.title")
    }
  }

  private func card(_ card: GuideCard) -> some View {
    VStack(spacing: 16) {
      Image(systemName: card.symbol)
        .font(.system(size: 54, weight: .regular))
        .foregroundStyle(.tint)
        .symbolEffect(.bounce, options: .nonRepeating, isActive: !reduceMotion)
        .accessibilityHidden(true)
        .frame(height: 70)
      Text(verbatim: card.title.text(russian: russian))
        .font(.title2.weight(.semibold))
        .multilineTextAlignment(.center)
      Text(verbatim: card.body.text(russian: russian))
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 420)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("guide.card.\(card.id)")
  }

  private var dots: some View {
    HStack(spacing: 6) {
      ForEach(scenario.cards.indices, id: \.self) { dot in
        Circle()
          .fill(dot == index ? Color.accentColor : Color.secondary.opacity(0.35))
          .frame(width: 7, height: 7)
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement()
    .accessibilityLabel(
      Text(
        verbatim: String(format: t("guide.position"), index + 1, scenario.cards.count)))
  }

  private func turn(by step: Int) {
    let next = min(max(index + step, 0), scenario.cards.count - 1)
    guard next != index else { return }
    if reduceMotion {
      index = next
    } else {
      withAnimation(.snappy) { index = next }
    }
  }
}
