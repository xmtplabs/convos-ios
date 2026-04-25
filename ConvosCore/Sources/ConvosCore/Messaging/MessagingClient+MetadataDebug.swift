import ConvosAppData
import ConvosMessagingProtocols
import Foundation

public struct ConversationMetadataDebugInfo: Sendable {
    public let conversationId: String
    public let clientConversationId: String
    public let xmtpInviteTag: String
    public let xmtpExpiresAtDescription: String
    public let snapshot: ConversationCustomMetadataDebugSnapshot

    public var debugText: String {
        [
            "conversationId: \(conversationId)",
            "clientConversationId: \(clientConversationId)",
            "xmtpInviteTag: \(xmtpInviteTag)",
            "xmtpExpiresAt: \(xmtpExpiresAtDescription)",
            "",
            snapshot.debugText
        ].joined(separator: "\n")
    }
}

public enum ConversationMetadataDebugError: Error {
    case conversationNotFound(id: String)
}

public extension MessagingClient {
    func conversationMetadataDebugInfo(
        conversationId: String,
        clientConversationId: String
    ) async throws -> ConversationMetadataDebugInfo {
        guard let conversation = try await messagingConversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationMetadataDebugError.conversationNotFound(id: conversationId)
        }
        let rawAppData = try await group.appData()
        let snapshot = ConversationCustomMetadataDebugSnapshot(rawAppData: rawAppData)
        let inviteTag = (try? await group.inviteTag()) ?? "<error>"
        let expiresAtDescription = (try? await group.expiresAt())?.description ?? "<nil>"

        return ConversationMetadataDebugInfo(
            conversationId: conversationId,
            clientConversationId: clientConversationId,
            xmtpInviteTag: inviteTag,
            xmtpExpiresAtDescription: expiresAtDescription,
            snapshot: snapshot
        )
    }
}
