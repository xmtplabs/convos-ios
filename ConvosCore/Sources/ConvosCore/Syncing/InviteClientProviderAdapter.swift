import ConvosInvites
import ConvosMessagingProtocols
import Foundation

/// Adapts ConvosCore's `MessagingClient` to ConvosInvites'
/// `InviteClientProvider`.
///
/// Forwards to `MessagingClient.conversations`, which is
/// backend-agnostic, so both XMTPiOS- and DTU-backed clients can drive
/// this adapter.
///
/// Caller surface (production users): creator-side flows
/// (`InviteJoinRequestsManager`'s `processJoinRequest` /
/// `processJoinRequests` / `hasOutgoingJoinRequest`, driven by
/// `StreamProcessor` and `MessagingService+PushNotifications`).
struct InviteClientProviderAdapter: InviteClientProvider {
    private let client: any MessagingClient

    init(_ client: any MessagingClient) {
        self.client = client
    }

    var inviteInboxId: String { client.inboxId }

    func findConversation(conversationId: String) async throws -> MessagingConversation? {
        try await client.conversations.find(conversationId: conversationId)
    }

    func findOrCreateDm(with inboxId: String) async throws -> any MessagingDm {
        try await client.conversations.findOrCreateDm(with: inboxId)
    }

    // swiftlint:disable:next function_parameter_count
    func listDms(
        createdAfterNs: Int64?,
        createdBeforeNs: Int64?,
        lastActivityBeforeNs: Int64?,
        lastActivityAfterNs: Int64?,
        limit: Int?,
        consentStates: [MessagingConsentState]?,
        orderBy: MessagingOrderBy
    ) async throws -> [any MessagingDm] {
        let query = MessagingConversationQuery(
            createdAfterNs: createdAfterNs,
            createdBeforeNs: createdBeforeNs,
            lastActivityAfterNs: lastActivityAfterNs,
            lastActivityBeforeNs: lastActivityBeforeNs,
            limit: limit,
            consentStates: consentStates,
            orderBy: orderBy
        )
        return try await client.conversations.listDms(query: query)
    }
}
