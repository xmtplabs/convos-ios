import ConvosMessagingProtocols
// FIXME(stage6f-step8): `@preconcurrency import XMTPiOS` remains because
// `InviteCoordinator.swift`'s body still drives sends/decoding through
// XMTPiOS-native APIs (`dm.send(content:options:)`, `message.content()`,
// `message.encodedContent.type`). Stage 6f Step 7 lifted the
// `InviteClientProvider` protocol surface onto `Messaging*` types so the
// adapter (DTU) becomes structurally possible; the coordinator body
// migration is deferred to Step 8.
@preconcurrency import XMTPiOS

/// Minimal client interface needed by InviteCoordinator.
///
/// Stage 6f Step 7: surface migrated off raw `XMTPiOS.Conversation` /
/// `XMTPiOS.Dm` / `XMTPiOS.ConsentState` / `XMTPiOS.ConversationsOrderBy`
/// onto the backend-agnostic `Messaging*` types. Conformers
/// (`InviteClientProviderAdapter` for the XMTPiOS path, future DTU
/// adapter) bridge to/from their underlying SDK as needed.
public protocol InviteClientProvider {
    var inviteInboxId: String { get }

    func findConversation(conversationId: String) async throws -> MessagingConversation?
    func findOrCreateDm(with inboxId: String) async throws -> any MessagingDm

    // swiftlint:disable:next function_parameter_count
    func listDms(
        createdAfterNs: Int64?,
        createdBeforeNs: Int64?,
        lastActivityBeforeNs: Int64?,
        lastActivityAfterNs: Int64?,
        limit: Int?,
        consentStates: [MessagingConsentState]?,
        orderBy: MessagingOrderBy
    ) async throws -> [any MessagingDm]
}
