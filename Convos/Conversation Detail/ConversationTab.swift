import Foundation

/// The three surfaces a conversation hosts, in display order: the group chat,
/// the user's private DM with the conversation's agent, and the conversation's
/// Space web page.
///
/// The selected tab drives the whole screen - which page fills it, and which
/// composer sits at the bottom. Context has no composer: it is a web view and
/// nothing else.
///
/// Context used to not be a tab at all. It was the surface the conversation
/// sat on, with a floating sheet over it whose resting size decided how much
/// showed. That is gone: the Space is a peer of the two transcripts now, which
/// is what demoting it means.
enum ConversationTab: String, CaseIterable, Identifiable, Hashable {
    case group
    case agent
    case context

    var id: String { rawValue }

    var title: String {
        switch self {
        case .group: "Group"
        case .agent: "Agent"
        case .context: "Things"
        }
    }

    /// Whether this tab shows a message transcript, and so whether selecting it
    /// means the user is reading a lane.
    ///
    /// The read-state machinery keys off this rather than naming `.context`
    /// directly: claiming a reading lane, clearing an unread, sending read
    /// receipts and parking a transcript at its newest message are all things
    /// that only make sense over a transcript.
    var hostsTranscript: Bool {
        self != .context
    }

    /// Whether this tab hosts a composer. Context is a web view; there is
    /// nothing to type into.
    var hostsComposer: Bool {
        hostsTranscript
    }

    /// The tab a conversation opens on. A tap that specifically asked for the
    /// agent DM (a DM notification, or a list row whose most recent unread is
    /// in the DM) gets it; everything else opens on the group.
    ///
    /// Never Context. Opening a conversation is a request to see the
    /// conversation, and the Space is the surface being demoted - landing there
    /// unasked is what this change exists to stop.
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
