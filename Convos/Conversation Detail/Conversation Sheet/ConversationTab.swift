import Foundation

/// The three peer surfaces inside a conversation, in display order: its
/// desktop, the group chat, and the user's private DM with an agent.
///
/// The selected tab drives the full-screen content and the bar beneath it.
/// Desktop has no composer, Group hosts the group composer, and Agent hosts
/// the private agent composer.
enum ConversationTab: String, CaseIterable, Identifiable, Hashable {
    case desktop
    case group
    case agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .desktop: "Desktop"
        case .group: "Group"
        case .agent: "Agent"
        }
    }

    /// Desktop and Group belong to the shared Convo shell. The private Agent
    /// lane deliberately omits group identity/settings and invite controls.
    var showsGroupControls: Bool {
        self != .agent
    }

    /// The transcript a conversation opens on. A tap that specifically asked
    /// for the agent DM (a DM notification, or a list row whose most recent
    /// unread is in the DM) gets it; everything else opens on the group.
    ///
    /// A regular Convo tap always lands in Group. Agent is reserved for an
    /// explicit agent-lane action or agent-DM notification.
    static func initial(
        available: [ConversationTab],
        agentDmRequested: Bool
    ) -> ConversationTab {
        guard available.contains(.agent) else { return .group }
        if agentDmRequested {
            return .agent
        }
        return .group
    }
}
