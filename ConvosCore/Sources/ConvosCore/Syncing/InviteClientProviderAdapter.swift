import ConvosInvites
import Foundation
// FIXME(stage4): `@preconcurrency import XMTPiOS` remains because this
// adapter exists specifically to bridge `MessagingClient` to
// `ConvosInvites.InviteClientProvider`, whose protocol surface is
// defined in XMTPiOS-native types (`XMTPiOS.Conversation`, `Dm`,
// `ConsentState`, etc.). ConvosInvites is a sibling SwiftPM package
// that ConvosCore depends on; migrating its protocol surface to
// `Messaging*` is Stage 4e territory (blocked on the circular import —
// see directive).
//
// Stage 6e Phase B-2: switched the input from `any XMTPClientProvider`
// to `any MessagingClient`. The adapter downcasts to
// `XMTPiOSMessagingClient` and reaches for the underlying
// `XMTPiOS.Client` because the InviteClientProvider surface is
// fundamentally XMTPiOS-typed. DTU-backed clients cannot conform —
// the adapter throws an init failure for them.
@preconcurrency import XMTPiOS

/// Adapts ConvosCore's `MessagingClient` to ConvosInvites' `InviteClientProvider`.
struct InviteClientProviderAdapter: InviteClientProvider {
    private let xmtpClient: XMTPiOS.Client

    init(_ client: any MessagingClient) {
        // Stage 6e Phase B-2: ConvosInvites' protocol surface is
        // XMTPiOS-typed (Conversation/Dm/ConsentState). Only the
        // XMTPiOS-backed MessagingClient can drive it; the DTU adapter
        // intentionally has no equivalent today (the DTU integration
        // tests already skip invite-flow tests).
        if let xmtpiOS = client as? XMTPiOSMessagingClient {
            self.xmtpClient = xmtpiOS.xmtpClient
        } else {
            preconditionFailure(
                "InviteClientProviderAdapter requires an XMTPiOSMessagingClient; non-XMTPiOS clients (DTU) cannot drive the XMTPiOS-typed InviteClientProvider surface."
            )
        }
    }

    var inviteInboxId: String { xmtpClient.inboxID }

    func findConversation(conversationId: String) async throws -> XMTPiOS.Conversation? {
        try await xmtpClient.conversations.findConversation(conversationId: conversationId)
    }

    func findOrCreateDm(with inboxId: String) async throws -> XMTPiOS.Dm {
        try await xmtpClient.conversations.findOrCreateDm(
            with: inboxId,
            disappearingMessageSettings: nil
        )
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
        try xmtpClient.conversations.listDms(
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
