import Foundation

public struct ConnectionEventSummary: Hashable, Codable, Sendable {
    public enum Outcome: String, Hashable, Codable, Sendable {
        case pending
        case success
        case failure
    }

    public enum Icon: String, Hashable, Codable, Sendable {
        case health
        case calendar
        case contacts
        case photos
        case music
        case home
        case generic
        case error
    }

    /// Marker for an actor placeholder the renderer needs to resolve from
    /// conversation context. `text` carries an actor-less phrase ("can read calendar
    /// events"); the renderer prepends the resolved name. `nil` means no actor is
    /// expected — render `text` verbatim (used for connection-disconnected events).
    public enum Actor: String, Hashable, Codable, Sendable {
        /// A specific agent identified by `grantedToInboxId`. The renderer looks the
        /// inbox id up against the conversation's members and prepends the agent's
        /// current display name; ProfileUpdate-driven renames propagate live, and
        /// the lookup is deterministic with N agents in a conversation.
        case grantedAgent = "granted_agent"
        /// The sender of the underlying message — resolved by the renderer via
        /// `msg.sender`.
        case messageSender = "message_sender"
    }

    public let text: String
    public let outcome: Outcome
    public let icon: Icon
    public let actor: Actor?
    /// Identifies the agent the event concerns. Required for `actor == .grantedAgent`,
    /// nil otherwise. Renderer prefers a live member-list lookup keyed off this id and
    /// falls back to bare text only when the agent is no longer in the conversation.
    public let grantedToInboxId: String?

    public init(
        text: String,
        outcome: Outcome,
        icon: Icon,
        actor: Actor? = nil,
        grantedToInboxId: String? = nil
    ) {
        self.text = text
        self.outcome = outcome
        self.icon = icon
        self.actor = actor
        self.grantedToInboxId = grantedToInboxId
    }
}

// MARK: - MessageContent

public enum MessageContent: Hashable, Codable, Sendable {
    case text(String),
         invite(MessageInvite),
         emoji(String), // all emoji, not a reaction
         attachment(HydratedAttachment),
         attachments([HydratedAttachment]),
         update(ConversationUpdate),
         linkPreview(LinkPreview),
         assistantJoinRequest(status: AssistantJoinStatus, requestedByInboxId: String),
         connectionGrantRequest(CloudConnectionGrantRequest),
         connectionEvent(summary: ConnectionEventSummary),
         connectionInvocation(summary: ConnectionEventSummary),
         connectionInvocationResult(summary: ConnectionEventSummary),
         connectionPayload(summary: ConnectionEventSummary)

    public var showsInMessagesList: Bool {
        switch self {
        case .update(let update):
            return update.showsInMessagesList
        default:
            return true
        }
    }

    public var isUpdate: Bool {
        switch self {
        case .update:
            true
        default:
            false
        }
    }

    public var isEmoji: Bool {
        switch self {
        case .emoji:
            true
        default:
            false
        }
    }

    public var showsSender: Bool {
        switch self {
        case .update,
             .assistantJoinRequest,
             .connectionGrantRequest,
             .connectionEvent,
             .connectionInvocation,
             .connectionInvocationResult,
             .connectionPayload:
            false
        default:
            true
        }
    }

    public var isAssistantJoinRequest: Bool {
        switch self {
        case .assistantJoinRequest:
            true
        default:
            false
        }
    }

    public var isConnectionGrantRequest: Bool {
        switch self {
        case .connectionGrantRequest:
            true
        default:
            false
        }
    }

    public var isAttachment: Bool {
        switch self {
        case .attachment, .attachments:
            true
        default:
            false
        }
    }

    public var isFullBleedAttachment: Bool {
        switch self {
        case .attachment(let attachment):
            attachment.mediaType.isFullBleed
        case .attachments(let attachments):
            attachments.first?.mediaType.isFullBleed ?? false
        default:
            false
        }
    }

    /// Returns the first audio attachment in this message if any.
    ///
    /// `MessagesRepository` hydrates stored attachments into `.attachments([...])`
    /// even when there is only one, so callers that specifically want "the voice
    /// memo" must look inside both the singular and plural cases. Use this helper
    /// instead of matching the cases directly so we don't silently miss the plural
    /// path again.
    public var primaryVoiceMemoAttachment: HydratedAttachment? {
        switch self {
        case .attachment(let attachment):
            return attachment.mediaType == .audio ? attachment : nil
        case .attachments(let attachments):
            return attachments.first(where: { $0.mediaType == .audio })
        default:
            return nil
        }
    }
}
