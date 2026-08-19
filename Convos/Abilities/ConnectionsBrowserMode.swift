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
/// - **`.composerModal(...)`**: the agent composer's powerplug (quick icon
///   or `+` menu row) presents the screen full-screen from
///   `ConversationView`. The screen wraps itself in its own
///   `NavigationStack` with a Done dismiss control; ability detail pushes
///   run inside that stack. Carries the launching DM's context for future
///   scoped affordances; the content itself stays account-level.
///
/// Both modes render the same sections from the same view model; only the
/// wrapper differs.
enum ConnectionsBrowserMode: Hashable, Identifiable {
    case appSettings
    case composerModal(conversationId: String, agentInboxId: String)

    /// The modal presentation wraps the list in its own `NavigationStack`
    /// and shows the Done dismiss control; the settings push rides the
    /// presenting stack and shows neither.
    var showsDismissChrome: Bool {
        if case .composerModal = self { return true }
        return false
    }

    /// The agent DM the modal was launched from; nil for the settings push.
    var conversationId: String? {
        if case .composerModal(let conversationId, _) = self { return conversationId }
        return nil
    }

    /// The agent whose composer launched the modal; nil for the settings push.
    var agentInboxId: String? {
        if case .composerModal(_, let agentInboxId) = self { return agentInboxId }
        return nil
    }

    var id: String {
        switch self {
        case .appSettings:
            "appSettings"
        case let .composerModal(conversationId, agentInboxId):
            "composerModal-\(conversationId)-\(agentInboxId)"
        }
    }
}
