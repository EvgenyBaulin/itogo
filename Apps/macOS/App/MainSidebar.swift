import SwiftUI

/// The sidebar of the main window: its sections, chosen by a click or by ⌘1 / ⌘2 / ⌘3, whose
/// menu items, and the limits card of Overview, post `.selectSection` with the number of the
/// section.
struct MainSidebar: View {
  @Dependency(\.environment) private var environment
  @Binding var section: MainWindow.Section

  var body: some View {
    List(MainWindow.Section.allCases, selection: $section) { item in
      Label {
        Text(verbatim: environment.language(item.titleKey))
      } icon: {
        Image(systemName: item.symbol)
      }
      .tag(item)
    }
    .onReceive(NotificationCenter.default.publisher(for: .selectSection)) { note in
      guard let index = note.object as? Int,
        let chosen = MainWindow.Section.allCases.first(where: { $0.shortcutIndex == index })
      else { return }
      section = chosen
    }
  }
}
