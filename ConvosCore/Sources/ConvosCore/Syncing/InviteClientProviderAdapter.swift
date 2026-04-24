import ConvosInvites
import Foundation
// FIXME(stage4): `@preconcurrency import XMTPiOS` remains because this
// file adapts the legacy `XMTPClientProvider` to
// `ConvosInvites.InviteClientProvider`, whose protocol surface is
// defined in XMTPiOS-native types (`XMTPiOS.Conversation`, `Dm`,
// `ConsentState`, etc.). ConvosInvites is a sibling SwiftPM package;
// migrating its protocol surface is Stage 4e territory (blocked on the
// circular import — see directive).
@preconcurrency import XMTPiOS

/// Adapts ConvosCore's `XMTPClientProvider` to ConvosInvites' `InviteClientProvider`.
struct InviteClientProviderAdapter: InviteClientProvider {
    private let provider: any XMTPClientProvider

    init(_ provider: any XMTPClientProvider) {
        self.provider = provider
    }

    var inviteInboxId: String { provider.inboxId }

    func findConversation(conversationId: String) async throws -> XMTPiOS.Conversation? {
        try await provider.conversationsProvider.findConversation(conversationId: conversationId)
    }

    func findOrCreateDm(with inboxId: String) async throws -> XMTPiOS.Dm {
        try await provider.conversationsProvider.findOrCreateDm(with: inboxId)
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
