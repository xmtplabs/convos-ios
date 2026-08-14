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

    /// The tab a conversation opens on.
    ///
    /// A conversation with nothing waiting to be read opens on Home, where the
    /// space itself is the point; anything unread opens on the transcript
    /// holding it, so a backlog is never buried behind another tab. A tap that
    /// specifically asked for the agent DM (a DM notification, or a list row
    /// whose most recent unread is in the DM) wins outright.
    ///
    /// Home is offered on every conversation, including one whose space has
    /// not been published yet - it opens there and shows the preparing state.
    /// `available` still gates it so a caller that drops the tab is honored.
    static func initial(
        available: [ConversationTab],
        hasUnread: Bool,
        agentDmRequested: Bool
    ) -> ConversationTab {
        if agentDmRequested, available.contains(.agent) {
            return .agent
        }
        if !hasUnread, available.contains(.home) {
            return .home
        }
        return .group
    }
}
