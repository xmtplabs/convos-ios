import Foundation

/// Drives the chrome `AbilitiesListScreen` wraps the Connections browser in,
/// based on where the browser was opened from. Mirrors `ContactDetailMode`
/// and `ContactsPickerMode`'s "one view, multiple entry points" pattern -
/// see `CLAUDE.md`'s "View Modes for Multi-Entry-Point Surfaces" section
/// for the convention.
///
/// Entry-point mapping:
/// - **`.appSettings`**: the App Settings connections row
///   (`AppSettingsView.connectionsDestination`) pushes the screen inside
///   the settings `NavigationStack`. No chrome of its own - the stack
///   supplies the back button.
/// - **`.composerModal(...)`**: the agent composer's `+` menu powerplug
///   row presents the screen full-screen from
///   `ConversationView`. The screen wraps itself in its own
///   `NavigationStack` with a Done dismiss control; ability detail pushes
///   run inside that stack. Carries the launching DM's context: the
///   Connected section scopes its per-chat toggles to that conversation
///   and agent.
///
/// Both modes render the same sections from the same view model; only the
/// wrapper differs.
enum ConnectionsBrowserMode: Hashable, Identifiable {
    case appSettings
    case composerModal(conversationId: String, agentInboxId: String, agentDisplayName: String)

    /// The modal presentation wraps the list in its own `NavigationStack`
    /// and shows the Done dismiss control; the settings push rides the
    /// presenting stack and shows neither.
    var showsDismissChrome: Bool {
        if case .composerModal = self { return true }
        return false
    }

    /// The agent DM the modal was launched from; nil for the settings push.
    var conversationId: String? {
        if case .composerModal(let conversationId, _, _) = self { return conversationId }
        return nil
    }

    /// The agent whose composer launched the modal; nil for the settings push.
    var agentInboxId: String? {
        if case .composerModal(_, let agentInboxId, _) = self { return agentInboxId }
        return nil
    }

    /// The agent whose composer launched the modal, for the toggle rows
    /// that scope to it; nil for the settings push.
    var agentDisplayName: String? {
        if case .composerModal(_, _, let agentDisplayName) = self { return agentDisplayName }
        return nil
    }

    /// Deliberately excludes `agentDisplayName`: the modal is presented
    /// with `fullScreenCover(item:)`, so folding a renameable value into
    /// identity would tear the modal down and re-present it the moment the
    /// agent renames mid-session.
    var id: String {
        switch self {
        case .appSettings:
            "appSettings"
        case let .composerModal(conversationId, agentInboxId, _):
            "composerModal-\(conversationId)-\(agentInboxId)"
        }
    }
}
