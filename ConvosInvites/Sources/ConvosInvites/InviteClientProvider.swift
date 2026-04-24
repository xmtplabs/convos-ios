// FIXME(stage4): `@preconcurrency import XMTPiOS` remains because
// ConvosInvites is a sibling SwiftPM package (ConvosCore depends on
// it). See `InviteCoordinator.swift` for the circular-import blocker.
@preconcurrency import XMTPiOS

/// Minimal client interface needed by InviteCoordinator.
///
/// Both `XMTPiOS.Client` and app-level client wrappers can conform to this
/// protocol, allowing a single InviteCoordinator implementation to serve
/// direct SDK users and apps with their own abstraction layers.
public protocol InviteClientProvider {
    var inviteInboxId: String { get }
    func findConversation(conversationId: String) async throws -> XMTPiOS.Conversation?
    func findOrCreateDm(with inboxId: String) async throws -> XMTPiOS.Dm
    // swiftlint:disable:next function_parameter_count
    func listDms(
        createdAfterNs: Int64?,
        createdBeforeNs: Int64?,
        lastActivityBeforeNs: Int64?,
        lastActivityAfterNs: Int64?,
        limit: Int?,
        consentStates: [XMTPiOS.ConsentState]?,
        orderBy: XMTPiOS.ConversationsOrderBy
    ) throws -> [XMTPiOS.Dm]
}

extension XMTPiOS.Client: InviteClientProvider {
    public var inviteInboxId: String { inboxID }

    public func findConversation(conversationId: String) async throws -> XMTPiOS.Conversation? {
        try await conversations.findConversation(conversationId: conversationId)
    }

    public func findOrCreateDm(with inboxId: String) async throws -> XMTPiOS.Dm {
        try await conversations.findOrCreateDm(with: inboxId)
    }

    // swiftlint:disable:next function_parameter_count
    public func listDms(
        createdAfterNs: Int64?,
        createdBeforeNs: Int64?,
        lastActivityBeforeNs: Int64?,
        lastActivityAfterNs: Int64?,
        limit: Int?,
        consentStates: [XMTPiOS.ConsentState]?,
        orderBy: XMTPiOS.ConversationsOrderBy
    ) throws -> [XMTPiOS.Dm] {
        try conversations.listDms(
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
