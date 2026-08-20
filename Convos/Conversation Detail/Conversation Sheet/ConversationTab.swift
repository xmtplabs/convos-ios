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

    /// The label this lane wears in a given conversation.
    ///
    /// The personal Space is a conversation whose only other member is the
    /// user's own agent, so its group lane *is* the agent. Calling it "Group"
    /// would name a room that has one other member in it and no way to add a
    /// second.
    func title(isPersonalSpace: Bool) -> String {
        guard isPersonalSpace, self == .group else { return title }
        return ConversationTab.agent.title
    }

    /// The transcript a conversation opens on. A tap that specifically asked
    /// for the agent DM (a DM notification, or a list row whose most recent
    /// unread is in the DM) gets it; everything else opens on the group.
    ///
    /// Whether that transcript is actually showing on arrival is the detent's
    /// business - see `ConversationSheetDetent.initial`.
    /// - Parameter agentDmHoldsTheUnread: the DM lane is the one with something
    ///   waiting and the group is not. Opening onto the group would show a read
    ///   transcript while the dot sat on the other tab, so the unread lane gets
    ///   the open. When both lanes have something, the group wins - it is the
    ///   conversation the row was for.
    static func initial(
        available: [ConversationTab],
        agentDmRequested: Bool,
        agentDmHoldsTheUnread: Bool = false
    ) -> ConversationTab {
        guard available.contains(.agent) else { return .group }
        if agentDmRequested || agentDmHoldsTheUnread {
            return .agent
        }
        return .group
    }
}
