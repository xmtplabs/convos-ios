import ConvosAppData
import Foundation
import XMTPiOS

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

public extension XMTPClientProvider {
    func conversationMetadataDebugInfo(
        conversationId: String,
        clientConversationId: String
    ) async throws -> ConversationMetadataDebugInfo {
        guard let xmtpConversation = try await conversation(with: conversationId),
              case .group(let group) = xmtpConversation else {
            throw XMTPClientProviderError.conversationNotFound(id: conversationId)
        }

        // Stage 3 migration: the XMTPiOS.Group custom-metadata shim is
        // gone — read via the MessagingGroup adapter.
        let messagingGroup: any MessagingGroup = XMTPiOSMessagingGroup(xmtpGroup: group)
        let rawAppData = try group.appData()
        let snapshot = ConversationCustomMetadataDebugSnapshot(rawAppData: rawAppData)
        let xmtpInviteTag = (try? await messagingGroup.inviteTag()) ?? "<error>"
        let xmtpExpiresAtDescription = (try? await messagingGroup.expiresAt())?.description ?? "<nil>"

        return ConversationMetadataDebugInfo(
            conversationId: conversationId,
            clientConversationId: clientConversationId,
            xmtpInviteTag: xmtpInviteTag,
            xmtpExpiresAtDescription: xmtpExpiresAtDescription,
            snapshot: snapshot
        )
    }
}
