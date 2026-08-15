import Foundation

/// The two transcripts the floating conversation sheet can host, in display
/// order: the group chat, and the user's private DM with the conversation's
/// agent.
///
/// The selected tab drives both the transcript inside the sheet and the bar
/// beneath it (the group composer or the agent-DM composer). The Home - the
/// conversation's Space web surface - is not a tab: it is always behind the
/// sheet, and how much of it you can see is the sheet's detent
/// (`ConversationSheetDetent`).
enum ConversationTab: String, CaseIterable, Identifiable, Hashable {
    case group
    case agent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .group: "Group"
        case .agent: "Agent"
        }
    }

    /// The transcript a conversation opens on. A tap that specifically asked
    /// for the agent DM (a DM notification, or a list row whose most recent
    /// unread is in the DM) gets it; everything else opens on the group.
    ///
    /// Whether that transcript is actually showing on arrival is the detent's
    /// business - see `ConversationSheetDetent.initial`.
    static func initial(
        available: [ConversationTab],
        agentDmRequested: Bool
    ) -> ConversationTab {
        if agentDmRequested, available.contains(.agent) {
            return .agent
        }
        return .group
    }
}
