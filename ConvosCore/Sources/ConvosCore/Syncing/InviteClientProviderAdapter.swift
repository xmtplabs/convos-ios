import ConvosInvites
import Foundation
@preconcurrency import XMTPiOS

/// Adapts ConvosCore's `XMTPClientProvider` protocol to ConvosInvites'
/// `InviteClientProvider`, allowing a single `InviteCoordinator` to be
/// used throughout the app.
struct InviteClientProviderAdapter: InviteClientProvider, @unchecked Sendable {
    private let provider: any XMTPClientProvider

    init(_ provider: any XMTPClientProvider) {
        self.provider = provider
    }

    var inviteInboxId: String { provider.inboxId }

    func findConversation(conversationId: String) async throws -> XMTPiOS.Conversation? {
        try await provider.conversationsProvider.findConversation(conversationId: conversationId)
    }

    func findOrCreateDm(with inboxId: String) async throws -> XMTPiOS.Dm {
        // only used by sendJoinRequest (joiner side); ConvosCore handles
        // joining through ConversationStateMachine instead
        throw InviteCreationError.encodingFailed
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
        try provider.conversationsProvider.listDms(
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
