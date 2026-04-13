import ConvosInvites
import Foundation
@preconcurrency import XMTPiOS

struct VaultInviteClientAdapter: InviteClientProvider {
    let client: Client

    var inviteInboxId: String { client.inboxID }

    func findConversation(conversationId: String) async throws -> XMTPiOS.Conversation? {
        try await client.conversations.findConversation(conversationId: conversationId)
    }

    func findOrCreateDm(with inboxId: String) async throws -> XMTPiOS.Dm {
        try await client.conversations.findOrCreateDm(with: inboxId)
    }

    // swiftlint:disable:next function_parameter_count
    func listDms(
        createdAfterNs: Int64?,
        createdBeforeNs: Int64?,
        lastActivityBeforeNs: Int64?,
        lastActivityAfterNs: Int64?,
        limit: Int?,
        consentStates: [XMTPiOS.ConsentState]?,
        orderBy: XMTPiOS.ConversationsOrderBy
    ) throws -> [XMTPiOS.Dm] {
        try client.conversations.listDms(
            createdAfterNs: createdAfterNs,
            createdBeforeNs: createdBeforeNs,
            lastActivityBeforeNs: lastActivityBeforeNs,
            lastActivityAfterNs: lastActivityAfterNs,
            limit: limit,
            consentStates: consentStates,
            orderBy: orderBy
        )
    }
}
