import ConvosInvites
import ConvosMessagingProtocols
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
