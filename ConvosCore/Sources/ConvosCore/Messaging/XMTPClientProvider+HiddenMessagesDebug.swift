import Foundation
@preconcurrency import XMTPiOS

public struct HiddenMessageDebugEntry: Sendable, Identifiable, Hashable {
    public enum Reason: String, Sendable, Hashable {
        case profileUpdate = "Profile update"
        case profileSnapshot = "Profile snapshot"
        case typingIndicator = "Typing indicator"
        case readReceipt = "Read receipt"
        case reaction = "Reaction"
        case unknown = "Unknown"
    }

    public let id: String
    public let date: Date
    public let senderInboxId: String
    public let contentTypeDescription: String
    public let summary: String
    public let reason: Reason

    public init(
        id: String,
        date: Date,
        senderInboxId: String,
        contentTypeDescription: String,
        summary: String,
        reason: Reason
    ) {
        self.id = id
        self.date = date
        self.senderInboxId = senderInboxId
        self.contentTypeDescription = contentTypeDescription
        self.summary = summary
        self.reason = reason
    }
}

public extension XMTPClientProvider {
    func hiddenMessagesDebugInfo(
        conversationId: String,
        limit: Int = 500
    ) async throws -> [HiddenMessageDebugEntry] {
        guard let xmtpConversation = try await conversation(with: conversationId) else {
            throw XMTPClientProviderError.conversationNotFound(id: conversationId)
        }

        let messages: [DecodedMessage]
        switch xmtpConversation {
        case .group(let group):
            messages = try await group.messages(limit: limit)
        case .dm(let dm):
            messages = try await dm.messages(limit: limit)
        }

        return messages.compactMap(HiddenMessageDebugEntry.init(decodedMessage:))
    }
}

private extension HiddenMessageDebugEntry {
    init?(decodedMessage message: DecodedMessage) {
        guard let encodedContent = try? message.encodedContent else { return nil }
        let contentType = encodedContent.type

        let reason: Reason
        let summary: String

        if contentType == ContentTypeProfileUpdate {
            reason = .profileUpdate
            summary = Self.profileUpdateSummary(content: encodedContent)
        } else if contentType == ContentTypeProfileSnapshot {
            reason = .profileSnapshot
            summary = Self.profileSnapshotSummary(content: encodedContent)
        } else if contentType.authorityID == ContentTypeTypingIndicator.authorityID,
                  contentType.typeID == ContentTypeTypingIndicator.typeID {
            reason = .typingIndicator
            summary = Self.typingIndicatorSummary(content: encodedContent)
        } else if contentType.authorityID == ContentTypeReadReceipt.authorityID,
                  contentType.typeID == ContentTypeReadReceipt.typeID {
            reason = .readReceipt
            summary = "Read receipt"
        } else if contentType == ContentTypeReaction || contentType == ContentTypeReactionV2 {
            reason = .reaction
            summary = Self.reactionSummary(message: message)
        } else if Self.visibleContentTypes.contains(where: {
            $0.authorityID == contentType.authorityID && $0.typeID == contentType.typeID
        }) {
            return nil
        } else {
            reason = .unknown
            summary = "byte length: \(encodedContent.content.count)"
        }

        self.id = message.id
        self.date = message.sentAt
        self.senderInboxId = message.senderInboxId
        self.contentTypeDescription = "\(contentType.authorityID)/\(contentType.typeID):" +
            "\(contentType.versionMajor).\(contentType.versionMinor)"
        self.summary = summary
        self.reason = reason
    }

    static let visibleContentTypes: [ContentTypeID] = [
        ContentTypeText,
        ContentTypeReply,
        ContentTypeAttachment,
        ContentTypeMultiRemoteAttachment,
        ContentTypeRemoteAttachment,
        ContentTypeGroupUpdated,
        ContentTypeExplodeSettings,
        ContentTypeAssistantJoinRequest,
        ContentTypeConnectionGrantRequest,
    ]

    static func profileUpdateSummary(content: EncodedContent) -> String {
        guard let update = try? ProfileUpdateCodec().decode(content: content) else {
            return "<decode failed>"
        }
        var parts: [String] = []
        if update.hasName { parts.append("name=\"\(update.name)\"") }
        if update.hasEncryptedImage { parts.append("avatar") }
        if !update.profileMetadata.isEmpty { parts.append("metadata") }
        parts.append("kind=\(update.memberKind)")
        return parts.joined(separator: ", ")
    }

    static func profileSnapshotSummary(content: EncodedContent) -> String {
        guard let snapshot = try? ProfileSnapshotCodec().decode(content: content) else {
            return "<decode failed>"
        }
        return "profiles=\(snapshot.profiles.count)"
    }

    static func typingIndicatorSummary(content: EncodedContent) -> String {
        guard let indicator = try? TypingIndicatorCodec().decode(content: content) else {
            return "<decode failed>"
        }
        return "isTyping=\(indicator.isTyping)"
    }

    static func reactionSummary(message: DecodedMessage) -> String {
        let reaction: Reaction? = try? message.content()
        guard let reaction else {
            return "<decode failed>"
        }
        let referencePrefix = reaction.reference.prefix(8)
        return "\(reaction.action) \(reaction.content) → \(referencePrefix)"
    }
}
