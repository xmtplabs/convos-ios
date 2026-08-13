import Foundation

/// The conversation screen's primary surfaces, one per tab of the floating
/// conversation sheet, in display order: the Home (the conversation's
/// Space web surface), the group chat, and the user's private DM with the
/// conversation's agent.
///
/// The selected tab drives both the backing view rendered behind the sheet
/// and the bar the sheet hosts above its tab bar (the group composer, the
/// agent-DM composer, or nothing for the Home).
enum ConversationTab: String, CaseIterable, Identifiable, Hashable {
    case home
    case group
    case agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .group: "Group"
        case .agent: "Agent"
        }
    }
}
