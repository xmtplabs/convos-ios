import ConvosInvites
import Foundation
@preconcurrency import XMTPiOS

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
    func deleteLocalDatabase() throws
    func reconnectLocalDatabase() async throws
    func dropLocalDatabaseConnection() throws
    /// Writes a single-inbox XMTP archive to `path`, sealed under `encryptionKey`.
    /// Used by the backup stack — see `ConvosBackupArchiveProvider`.
    func createArchive(atPath path: String, encryptionKey: Data) async throws
    /// Imports a previously-sealed XMTP archive into the client's local DB.
    /// Used by the restore stack's throwaway-client path — see
    /// `ConvosRestoreArchiveImporter`. Non-fatal at the call site; the bundle
    /// GRDB restore remains the primary contract.
    func importArchive(fromPath path: String, encryptionKey: Data) async throws
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

    public func createArchive(atPath path: String, encryptionKey: Data) async throws {
        // The archive element set is [.messages] by design. `.consent` is
        // excluded so restore doesn't pin a stale consent state — consent
        // is resolved by the GRDB restore + the XMTP consent stream after
        // the client comes back online.
        try await createArchive(
            path: path,
            encryptionKey: encryptionKey,
            opts: ArchiveOptions(archiveElements: [.messages])
        )
    }

    public func importArchive(fromPath path: String, encryptionKey: Data) async throws {
        try await importArchive(path: path, encryptionKey: encryptionKey)
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
