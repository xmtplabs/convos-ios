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

        let rawAppData = try group.appData()
        let snapshot = ConversationCustomMetadataDebugSnapshot(rawAppData: rawAppData)
        let xmtpInviteTag = (try? group.inviteTag) ?? "<error>"
        let xmtpExpiresAtDescription = (try? group.expiresAt)?.description ?? "<nil>"

        return ConversationMetadataDebugInfo(
            conversationId: conversationId,
            clientConversationId: clientConversationId,
            xmtpInviteTag: xmtpInviteTag,
            xmtpExpiresAtDescription: xmtpExpiresAtDescription,
            snapshot: snapshot
        )
    }
}
