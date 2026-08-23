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
    /// The quiet-but-listening mode: the agent keeps working but only speaks
    /// when it is addressed (an @mention or its name). Its wire value is
    /// `"mention"` and its user-facing name is "Listen mode" (see `title`) —
    /// they are the SAME mode. There is no separate `listen` wire value; if you
    /// see "listen" in a transcript, screenshot, or product copy, it means this
    /// case.
    case mentionsOnly = "mention"
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
        case .mentionsOnly, .paused: true
        }
    }

    /// User-visible name of the mode, as it reads in the participation menu.
    /// Note `.mentionsOnly` (wire value `"mention"`) reads as "Listen mode"
    /// here - the label and the wire vocabulary are deliberately different
    /// names for one mode.
    public var title: String {
        switch self {
        case .speakFreely: "Speak freely"
        case .mentionsOnly: "Listen mode"
        case .paused: "Pause"
        }
    }

    /// The mode's name as it reads in the transcript row a change leaves
    /// behind ("Shane set agents to Listen"). Shorter than `title`, which
    /// carries menu-length wording the sentence does not want.
    ///
    /// `.paused` renders its own full sentence rather than this label, so its
    /// value here is never the one a reader sees.
    public var transcriptTitle: String {
        switch self {
        case .speakFreely: "Chat"
        case .mentionsOnly: "Listen"
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
        case .paused: self = .paused
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }

    var proto: ParticipationMode {
        switch self {
        case .speakFreely: .speakFreely
        case .mentionsOnly: .mentionsOnly
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
