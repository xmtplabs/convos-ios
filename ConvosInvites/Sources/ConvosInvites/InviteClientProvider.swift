import ConvosMessagingProtocols

/// Minimal client interface needed by `InviteCoordinator`.
///
/// Typed against the backend-agnostic `Messaging*` types. Conformers
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
