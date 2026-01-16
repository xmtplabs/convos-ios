import Foundation
@preconcurrency import XMTPiOS

/// Protocol for static XMTP operations that don't require a client instance
public protocol XMTPStaticOperations {
    /// Fetches the newest message metadata for the given conversation IDs
    ///
    /// This is a static operation that can be performed without waking up the inbox's XMTP client.
    /// - Parameters:
    ///   - groupIds: Array of conversation/group IDs to fetch metadata for
    ///   - api: XMTP API options for the request
    /// - Returns: Dictionary mapping conversation ID to its newest message metadata
    static func getNewestMessageMetadata(
        groupIds: [String],
        api: ClientOptions.Api
    ) async throws -> [String: MessageMetadata]
}

extension Client: XMTPStaticOperations {}

public protocol MessageSender {
    func sendExplode(expiresAt: Date) async throws
    func prepare(text: String) async throws -> String
    func publish() async throws
    func consentState() throws -> ConsentState
}

public protocol ConversationSender {
    var id: String { get }
    func add(members inboxIds: [String]) async throws
    func remove(members inboxIds: [String]) async throws
    func prepare(text: String) async throws -> String
    func ensureInviteTag() async throws
    func publish() async throws
}

public protocol GroupConversationSender: ConversationSender {
    func permissionPolicySet() throws -> PermissionPolicySet
    func updateAddMemberPermission(newPermissionOption: PermissionOption) async throws
}

public protocol ConversationsProvider {
    // swiftlint:disable:next function_parameter_count
    func listGroups(
        createdAfterNs: Int64?,
        createdBeforeNs: Int64?,
        lastActivityAfterNs: Int64?,
        lastActivityBeforeNs: Int64?,
        limit: Int?,
        consentStates: [ConsentState]?,
        orderBy: ConversationsOrderBy
    ) throws -> [Group]

    // swiftlint:disable:next function_parameter_count
    func list(
        createdAfterNs: Int64?,
        createdBeforeNs: Int64?,
        lastActivityBeforeNs: Int64?,
        lastActivityAfterNs: Int64?,
        limit: Int?,
        consentStates: [ConsentState]?,
        orderBy: ConversationsOrderBy,
    ) async throws -> [XMTPiOS.Conversation]

    // swiftlint:disable:next function_parameter_count
    func listDms(
        createdAfterNs: Int64?,
        createdBeforeNs: Int64?,
        lastActivityBeforeNs: Int64?,
        lastActivityAfterNs: Int64?,
        limit: Int?,
        consentStates: [ConsentState]?,
        orderBy: ConversationsOrderBy
    ) throws -> [Dm]

    func stream(
        type: ConversationFilterType,
        onClose: (() -> Void)?
    ) -> AsyncThrowingStream<XMTPiOS.Conversation, Error>

    func findConversation(conversationId: String) async throws
    -> XMTPiOS.Conversation?

    func sync() async throws
    func syncAllConversations(consentStates: [ConsentState]?) async throws -> GroupSyncSummary
    func streamAllMessages(
        type: XMTPiOS.ConversationFilterType,
        consentStates: [XMTPiOS.ConsentState]?,
        onClose: (() -> Void)?
    ) -> AsyncThrowingStream<XMTPiOS.DecodedMessage, Error>
}

public protocol XMTPClientProvider: AnyObject {
    var installationId: String { get }
    var inboxId: String { get }
    var conversationsProvider: ConversationsProvider { get }
    func signWithInstallationKey(message: String) throws -> Data
    func verifySignature(message: String, signature: Data) throws -> Bool
    func messageSender(for conversationId: String) async throws -> (any MessageSender)?
    func canMessage(identity: String) async throws -> Bool
    func canMessage(identities: [String]) async throws -> [String: Bool]
    func prepareConversation() throws -> GroupConversationSender
    func newConversation(with memberInboxIds: [String],
                         name: String,
                         description: String,
                         imageUrl: String) async throws -> String
    func newConversation(with memberInboxId: String) async throws -> (any MessageSender)
    func conversation(with id: String) async throws -> XMTPiOS.Conversation?
    func inboxId(for ethereumAddress: String) async throws -> String?
    func update(consent: Consent, for conversationId: String) async throws
    func revokeInstallations(
        signingKey: SigningKey, installationIds: [String]
    ) async throws
    func deleteLocalDatabase() throws
    func reconnectLocalDatabase() async throws
    func dropLocalDatabaseConnection() throws
}

enum XMTPClientProviderError: Error {
    case conversationNotFound(id: String)
}

extension XMTPiOS.Group: GroupConversationSender {
    public func add(members inboxIds: [String]) async throws {
        _ = try await addMembers(inboxIds: inboxIds)
    }

    public func remove(members inboxIds: [String]) async throws {
        _ = try await removeMembers(inboxIds: inboxIds)
    }

    public func prepare(text: String) async throws -> String {
        return try await prepareMessage(content: text)
    }

    public func publish() async throws {
        try await publishMessages()
    }
}

extension XMTPiOS.Conversations: ConversationsProvider {
}

extension XMTPiOS.Client: XMTPClientProvider {
    public var conversationsProvider: any ConversationsProvider {
        conversations
    }

    public var installationId: String {
        installationID
    }

    public var inboxId: String {
        inboxID
    }

    public func canMessage(identity: String) async throws -> Bool {
        return try await canMessage(
            identity: PublicIdentity(kind: .ethereum, identifier: identity)
        )
    }

    public func prepareConversation() throws -> GroupConversationSender {
        return try conversations.newGroupOptimistic()
    }

    public func newConversation(with memberInboxIds: [String],
                                name: String,
                                description: String,
                                imageUrl: String) async throws -> String {
        let group = try await conversations.newGroup(
            with: memberInboxIds,
            name: name,
            imageUrl: imageUrl,
            description: description
        )
        return group.id
    }

    public func newConversation(with memberInboxId: String) async throws -> (any MessageSender) {
        let group = try await conversations.newConversation(
            with: memberInboxId,
            disappearingMessageSettings: nil
        )
        return group
    }

    public func conversation(with id: String) async throws -> XMTPiOS.Conversation? {
        return try await conversations.findConversation(conversationId: id)
    }

    public func canMessage(identities: [String]) async throws -> [String: Bool] {
        return try await canMessage(
            identities: identities.map {
                PublicIdentity(kind: .ethereum, identifier: $0)
            }
        )
    }

    public func messageSender(for conversationId: String) async throws -> (any MessageSender)? {
        return try await conversations.findConversation(conversationId: conversationId)
    }

    public func inboxId(for ethereumAddress: String) async throws -> String? {
        return try await inboxIdFromIdentity(identity: .init(kind: .ethereum, identifier: ethereumAddress))
    }

    public func update(consent: Consent, for conversationId: String) async throws {
        guard let foundConversation = try await self.conversation(with: conversationId) else {
            throw XMTPClientProviderError.conversationNotFound(id: conversationId)
        }
        try await foundConversation.updateConsentState(state: consent.consentState)
    }
}

extension XMTPiOS.Conversation: MessageSender {
    public func sendExplode(expiresAt: Date) async throws {
        Log.info("Sending ExplodeSettings message with expiresAt: \(expiresAt) (\(expiresAt.timeIntervalSince1970))")
        let codec = ExplodeSettingsCodec()
        Log.info("ExplodeSettings shouldPush: \(try codec.shouldPush(content: ExplodeSettings(expiresAt: expiresAt)))")
        try await send(
            content: ExplodeSettings(expiresAt: expiresAt),
            options: .init(contentType: codec.contentType)
        )
        Log.info("ExplodeSettings message sent successfully")
    }

    public func sendInviteJoinError(_ error: InviteJoinError) async throws {
        Log.info("Sending InviteJoinError message with errorType: \(error.errorType.rawValue), inviteTag: \(error.inviteTag)")
        let codec = InviteJoinErrorCodec()
        try await send(
            content: error,
            options: .init(contentType: codec.contentType)
        )
        Log.info("InviteJoinError message sent successfully")
    }

    public func prepare(text: String) async throws -> String {
        return try await prepareMessage(content: text)
    }

    public func publish() async throws {
        try await publishMessages()
    }
}
