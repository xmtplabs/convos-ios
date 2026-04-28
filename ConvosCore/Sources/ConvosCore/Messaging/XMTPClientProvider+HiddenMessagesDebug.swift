import ConvosConnectionsXMTP
import Foundation
@preconcurrency import XMTPiOS

public struct HiddenMessageDebugEntry: Sendable, Identifiable, Hashable {
    public enum Reason: String, Sendable, Hashable {
        case profileUpdate = "Profile update"
        case profileSnapshot = "Profile snapshot"
        case typingIndicator = "Typing indicator"
        case readReceipt = "Read receipt"
        case reaction = "Reaction"
        case capabilityRequest = "Capability request"
        case capabilityRequestResult = "Capability result"
        case connectionInvocation = "Connection invocation"
        case connectionInvocationResult = "Connection result"
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
        } else if contentType.authorityID == ContentTypeCapabilityRequest.authorityID,
                  contentType.typeID == ContentTypeCapabilityRequest.typeID {
            reason = .capabilityRequest
            summary = Self.capabilityRequestSummary(content: encodedContent)
        } else if contentType.authorityID == ContentTypeCapabilityRequestResult.authorityID,
                  contentType.typeID == ContentTypeCapabilityRequestResult.typeID {
            reason = .capabilityRequestResult
            summary = Self.capabilityRequestResultSummary(content: encodedContent)
        } else if contentType.authorityID == ContentTypeConnectionInvocation.authorityID,
                  contentType.typeID == ContentTypeConnectionInvocation.typeID {
            reason = .connectionInvocation
            summary = Self.connectionInvocationSummary(content: encodedContent)
        } else if contentType.authorityID == ContentTypeConnectionInvocationResult.authorityID,
                  contentType.typeID == ContentTypeConnectionInvocationResult.typeID {
            reason = .connectionInvocationResult
            summary = Self.connectionInvocationResultSummary(content: encodedContent)
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
        ContentTypeCloudConnectionGrantRequest,
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

    static func capabilityRequestSummary(content: EncodedContent) -> String {
        guard let request = try? CapabilityRequestCodec().decode(content: content) else {
            return "<decode failed>"
        }
        var parts: [String] = [
            "subject=\(request.subject.rawValue)",
            "verb=\(request.capability.rawValue)",
            "id=\(request.requestId)",
        ]
        if let preferred = request.preferredProviders, !preferred.isEmpty {
            parts.append("preferred=\(preferred.map(\.rawValue).joined(separator: ","))")
        }
        return parts.joined(separator: ", ")
    }

    static func capabilityRequestResultSummary(content: EncodedContent) -> String {
        guard let result = try? CapabilityRequestResultCodec().decode(content: content) else {
            return "<decode failed>"
        }
        var parts: [String] = [
            "status=\(result.status.rawValue)",
            "subject=\(result.subject.rawValue)",
            "verb=\(result.capability.rawValue)",
            "id=\(result.requestId)",
        ]
        if !result.providers.isEmpty {
            parts.append("providers=\(result.providers.map(\.rawValue).joined(separator: ","))")
        }
        if !result.availableActions.isEmpty {
            parts.append("actions=\(result.availableActions.count)")
        }
        return parts.joined(separator: ", ")
    }

    static func connectionInvocationSummary(content: EncodedContent) -> String {
        guard let invocation = try? ConnectionInvocationCodec().decode(content: content) else {
            return "<decode failed>"
        }
        return [
            "kind=\(invocation.kind.rawValue)",
            "action=\(invocation.action.name)",
            "id=\(invocation.invocationId)",
            "args=\(invocation.action.arguments.count)",
        ].joined(separator: ", ")
    }

    static func connectionInvocationResultSummary(content: EncodedContent) -> String {
        guard let result = try? ConnectionInvocationResultCodec().decode(content: content) else {
            return "<decode failed>"
        }
        var parts: [String] = [
            "status=\(result.status.rawValue)",
            "kind=\(result.kind.rawValue)",
            "action=\(result.actionName)",
            "id=\(result.invocationId)",
        ]
        if !result.result.isEmpty {
            parts.append("outputs=\(result.result.count)")
        }
        if let errorMessage = result.errorMessage, !errorMessage.isEmpty {
            parts.append("error=\(errorMessage)")
        }
        return parts.joined(separator: ", ")
    }
}
