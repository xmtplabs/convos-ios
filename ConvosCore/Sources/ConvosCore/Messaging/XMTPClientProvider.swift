import ConvosInvites
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

/// Sendable wrapper for XMTPStaticOperations metatypes.
///
/// Metatypes are inherently thread-safe since they only contain type metadata,
/// not mutable instance state. This wrapper allows passing metatypes across
/// actor boundaries without triggering false positive Sendable warnings.
public struct SendableXMTPOperations: Sendable {
    // Using @unchecked because metatypes are inherently thread-safe
    // (they're just references to type metadata, not mutable instances)
    private nonisolated(unsafe) let metatype: any XMTPStaticOperations.Type

    public init(_ metatype: any XMTPStaticOperations.Type) {
        self.metatype = metatype
    }

    public func getNewestMessageMetadata(
        groupIds: [String],
        api: ClientOptions.Api
    ) async throws -> [String: MessageMetadata] {
        try await metatype.getNewestMessageMetadata(groupIds: groupIds, api: api)
    }
}

public protocol MessageSender {
    func sendExplode(expiresAt: Date) async throws
    func sendTypingIndicator(isTyping: Bool) async throws
    func sendReadReceipt() async throws
    func prepare(text: String) async throws -> String
    func prepare(remoteAttachment: RemoteAttachment) async throws -> String
    func prepare(reply: Reply) async throws -> String
    func publish() async throws
    func publishMessage(messageId: String) async throws
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

    func findOrCreateDm(with peerInboxId: String) async throws -> Dm

    func findMessage(messageId: String) throws -> XMTPiOS.DecodedMessage?

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

    /// Fetch this inbox's current MLS state. Used by the revoker to
    /// enumerate live installations before deciding which to revoke.
    /// `refreshFromNetwork: true` forces a fresh read; with `false`
    /// the SDK returns its cached view which may be stale.
    func inboxState(refreshFromNetwork: Bool) async throws -> XMTPiOS.InboxState

    /// Write an encrypted XMTP archive of this client's conversations
    /// and messages to `path`. Key must be 32 bytes. The archive is
    /// AES-256-GCM-encrypted by the SDK; we carry the same key inside
    /// the backup bundle's full-form metadata so `importArchive` can
    /// read it back.
    func createArchive(path: String, encryptionKey: Data) async throws

    /// Read an encrypted XMTP archive at `path` and apply it to this
    /// client's local MLS state. Caller must have constructed the
    /// client against an empty XMTP DB file — importing onto a
    /// populated DB has undefined behavior per the SDK's archive
    /// contract.
    func importArchive(path: String, encryptionKey: Data) async throws

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
    public func findOrCreateDm(with peerInboxId: String) async throws -> Dm {
        try await findOrCreateDm(with: peerInboxId, disappearingMessageSettings: nil)
    }
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

    // Forwarding wrappers for the backup/restore archive APIs.
    // XMTPiOS.Client's `createArchive(path:encryptionKey:opts:)` takes
    // an `opts: ArchiveOptions = .init()` third arg; the protocol
    // requirement takes only path + encryptionKey, so an explicit
    // pass-through is needed for the witness to resolve.
    public func createArchive(path: String, encryptionKey: Data) async throws {
        try await self.createArchive(path: path, encryptionKey: encryptionKey, opts: ArchiveOptions())
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
    public func sendReadReceipt() async throws {
        try await send(
            content: ReadReceipt(),
            options: .init(contentType: ReadReceiptCodec().contentType)
        )
    }

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

    public func sendAssistantJoinRequest(_ request: AssistantJoinRequest) async throws {
        Log.info("Sending AssistantJoinRequest with status: \(request.status.rawValue), requestId: \(request.requestId)")
        let codec = AssistantJoinRequestCodec()
        try await send(
            content: request,
            options: .init(contentType: codec.contentType)
        )
        Log.info("AssistantJoinRequest message sent successfully")
    }

    public func sendTypingIndicator(isTyping: Bool) async throws {
        let codec = TypingIndicatorCodec()
        try await send(
            content: TypingIndicatorContent(isTyping: isTyping),
            options: .init(contentType: codec.contentType)
        )
    }

    public func prepare(text: String) async throws -> String {
        return try await prepareMessage(content: text)
    }

    public func prepare(remoteAttachment: RemoteAttachment) async throws -> String {
        return try await prepareMessage(
            content: remoteAttachment,
            options: .init(contentType: ContentTypeRemoteAttachment),
        )
    }

    public func prepare(reply: Reply) async throws -> String {
        return try await prepareMessage(
            content: reply,
            options: .init(contentType: ContentTypeReply)
        )
    }

    public func publish() async throws {
        try await publishMessages()
    }

    // publishMessage(messageId:) is already provided by XMTPiOS.Conversation
}
