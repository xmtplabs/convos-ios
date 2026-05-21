import SwiftUI

/// Root tab shell for the app. Hosts the existing `ConversationsView` under
/// the "Chats" tab, a placeholder `StuffTabView` under "Stuff", and an
/// iOS 26 `Tab(role: .search)` for the search affordance that floats at
/// the bottom trailing edge.
///
/// The app indicator (leading) and compose button (trailing) live inside
/// each tab's own top bar — not on this shell — because each tab's chrome
/// is contextual (Chats has compose, Stuff and Search don't). See
/// `ConversationsView` for the Chats top-bar wiring.
struct MainTabView: View {
    let conversationsViewModel: ConversationsViewModel
    let profileSettingsViewModel: ProfileSettingsViewModel

    var body: some View {
        TabView {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right.fill") {
                ConversationsView(
                    viewModel: conversationsViewModel,
                    profileSettingsViewModel: profileSettingsViewModel
                )
            }

            Tab("Stuff", systemImage: "square.grid.2x2.fill") {
                StuffTabView()
            }

            Tab(role: .search) {
                SearchTabView()
            }
        }
    }
}
