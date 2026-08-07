import ConvosAppData
import Foundation

// MARK: - ConversationParticipationMode

/// How much the agents in a conversation speak. The mode belongs to the
/// conversation, not to one agent: a room holding several agents has a single
/// mode that governs all of them, and an agent that joins later inherits it.
///
/// Carried in the group's appData (`ConversationCustomMetadata.participationMode`)
/// so it rides the group-metadata rails: a member who joins reads the current
/// mode straight from synced group state, and MLS metadata's last-writer-wins
/// resolution settles two members changing it at once. Synced state, so it is
/// persisted on `conversation` and never in `conversationLocalState`.
///
/// The raw values are the control plane's wire vocabulary, so the same string
/// travels over appData, the participation endpoints, and the server-side
/// mirror the agent runtime reads.
public enum ConversationParticipationMode: String, CaseIterable, Codable, Sendable {
    case speakFreely = "speak"
    case mentionsOnly = "mention"
    case listenOnly = "listen"
    case paused

    /// The mode a conversation is in until someone sets one. An unset
    /// conversation and an explicit Speak freely render identically because
    /// they behave identically.
    public static let `default`: ConversationParticipationMode = .speakFreely

    /// Whether the agents keep their own counsel at this mode. The quiet modes
    /// are the ones a member is told about in the transcript, and the ones the
    /// runtime gates a wake on.
    public var isQuiet: Bool {
        switch self {
        case .speakFreely: false
        case .mentionsOnly, .listenOnly, .paused: true
        }
    }

    /// User-visible name of the mode, as it reads in the participation menu and
    /// in the transcript row a change leaves behind.
    public var title: String {
        switch self {
        case .speakFreely: "Speak freely"
        case .mentionsOnly: "Listen mode"
        case .listenOnly: "Listen only"
        case .paused: "Pause"
        }
    }
}

// MARK: - appData wire mapping

public extension ConversationParticipationMode {
    /// The mode carried by a group's custom metadata, or nil when the field is
    /// unset or carries a mode this build does not know. Both cases mean the
    /// same thing to a reader: fall back to the default rather than inventing
    /// a mode the conversation was never put in.
    init?(proto: ParticipationMode) {
        switch proto {
        case .speakFreely: self = .speakFreely
        case .mentionsOnly: self = .mentionsOnly
        case .listenOnly: self = .listenOnly
        case .paused: self = .paused
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }

    var proto: ParticipationMode {
        switch self {
        case .speakFreely: .speakFreely
        case .mentionsOnly: .mentionsOnly
        case .listenOnly: .listenOnly
        case .paused: .paused
        }
    }
}

public extension ConversationCustomMetadata {
    /// The conversation's participation mode, or nil when no member has set one
    /// (or set one this build cannot read).
    var conversationParticipationMode: ConversationParticipationMode? {
        guard hasParticipationMode else { return nil }
        return ConversationParticipationMode(proto: participationMode)
    }
}
