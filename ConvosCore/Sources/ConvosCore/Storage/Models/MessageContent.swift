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

    public let text: String
    public let outcome: Outcome
    public let icon: Icon

    public init(text: String, outcome: Outcome, icon: Icon) {
        self.text = text
        self.outcome = outcome
        self.icon = icon
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
         connectionInvocationResult(summary: ConnectionEventSummary)

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
        case .update, .assistantJoinRequest, .connectionGrantRequest, .connectionEvent, .connectionInvocation, .connectionInvocationResult:
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
