import Foundation
@preconcurrency import XMTPiOS

/// XMTPiOS-backed implementation of `MessagingGroup`.
///
/// Wraps `XMTPiOS.Group` and forwards every protocol method onto the
/// underlying SDK handle. Value types (identity/permission/member/etc.)
/// round-trip through the mappers in `XMTPiOSValueMappers.swift`.
///
/// `@unchecked Sendable`: the underlying `XMTPiOS.Group` is not marked
/// Sendable, but this wrapper is reference-stable and only reads from
/// the SDK via calls that are themselves thread-safe (ffiGroup state
/// is guarded by libxmtp). Matches the pattern already used by
/// `InboxReadyResult` in `InboxStateMachine.swift:38`.
public final class XMTPiOSMessagingGroup: MessagingGroup, @unchecked Sendable {
    // Stored handle is read-only after init; safe to expose to the
    // adapter-local code that needs to reach back into XMTPiOS.
    let xmtpGroup: XMTPiOS.Group

    public init(xmtpGroup: XMTPiOS.Group) {
        self.xmtpGroup = xmtpGroup
    }

    // MARK: - MessagingConversationCore

    public var id: String { xmtpGroup.id }
    public var topic: String { xmtpGroup.topic }
    public var createdAtNs: Int64 { xmtpGroup.createdAtNs }
    public var lastActivityAtNs: Int64 { xmtpGroup.lastActivityAtNs }

    public func consentState() async throws -> MessagingConsentState {
        MessagingConsentState(try xmtpGroup.consentState())
    }

    public func updateConsentState(_ state: MessagingConsentState) async throws {
        try await xmtpGroup.updateConsentState(state: state.xmtpConsentState)
    }

    public func debugInformation() async throws -> MessagingConversationDebugInfo {
        MessagingConversationDebugInfo(try await xmtpGroup.getDebugInformation())
    }

    public func sync() async throws {
        try await xmtpGroup.sync()
    }

    public func members() async throws -> [MessagingMember] {
        try await xmtpGroup.members.map(MessagingMember.init)
    }

    public func messages(query: MessagingMessageQuery) async throws -> [MessagingMessage] {
        let excludeStandard = query.excludeContentTypes?
            .compactMap(XMTPiOSContentTypeMapper.standardContentType(for:))
        let raw = try await xmtpGroup.messages(
            beforeNs: query.beforeNs,
            afterNs: query.afterNs,
            limit: query.limit,
            direction: XMTPiOS.SortDirection(query.direction),
            deliveryStatus: query.deliveryStatus.xmtpMessageDeliveryStatus,
            excludeContentTypes: excludeStandard,
            excludeSenderInboxIds: query.excludeSenderInboxIds
        )
        return raw.compactMap { try? MessagingMessage($0) }
    }

    public func lastMessage() async throws -> MessagingMessage? {
        guard let xmtpMessage = try await xmtpGroup.lastMessage() else { return nil }
        return try? MessagingMessage(xmtpMessage)
    }

    public func countMessages(query: MessagingMessageQuery) async throws -> Int64 {
        let excludeStandard = query.excludeContentTypes?
            .compactMap(XMTPiOSContentTypeMapper.standardContentType(for:))
        return try xmtpGroup.countMessages(
            beforeNs: query.beforeNs,
            afterNs: query.afterNs,
            deliveryStatus: query.deliveryStatus.xmtpMessageDeliveryStatus,
            excludeContentTypes: excludeStandard,
            excludeSenderInboxIds: query.excludeSenderInboxIds
        )
    }

    public func streamMessages(
        onClose: (@Sendable () -> Void)?
    ) -> MessagingStream<MessagingMessage> {
        XMTPiOSMessageStreamBridge.bridge(xmtpGroup.streamMessages(onClose: onClose))
    }

    public func getHmacKeys() async throws -> MessagingHmacKeys {
        MessagingHmacKeys(try xmtpGroup.getHmacKeys())
    }

    public func getPushTopics() async throws -> [String] {
        try xmtpGroup.getPushTopics()
    }

    public func processMessage(bytes: Data) async throws -> MessagingMessage? {
        guard let xmtpMessage = try await xmtpGroup.processMessage(messageBytes: bytes) else {
            return nil
        }
        return try MessagingMessage(xmtpMessage)
    }

    // MARK: - Send flows

    public func prepare(
        encodedContent: MessagingEncodedContent,
        options: MessagingSendOptions?
    ) async throws -> MessagingPreparedMessage {
        let messageId = try await xmtpGroup.prepareMessage(
            encodedContent: encodedContent.xmtpEncodedContent,
            visibilityOptions: XMTPiOSSendOptionsMapper.xmtpVisibilityOptions(options),
            noSend: true
        )
        return MessagingPreparedMessage(
            messageId: messageId,
            conversationId: id,
            deliveryStatus: .unpublished
        )
    }

    public func sendOptimistic(
        encodedContent: MessagingEncodedContent,
        options: MessagingSendOptions?
    ) async throws -> MessagingPreparedMessage {
        let messageId = try await xmtpGroup.prepareMessage(
            encodedContent: encodedContent.xmtpEncodedContent,
            visibilityOptions: XMTPiOSSendOptionsMapper.xmtpVisibilityOptions(options),
            noSend: false
        )
        return MessagingPreparedMessage(
            messageId: messageId,
            conversationId: id,
            deliveryStatus: .unpublished
        )
    }

    public func publish() async throws {
        try await xmtpGroup.publishMessages()
    }

    public func publish(messageId: String) async throws {
        try await xmtpGroup.publishMessage(messageId: messageId)
    }

    // MARK: - MessagingGroup specifics

    public func name() async throws -> String { try xmtpGroup.name() }
    public func imageUrl() async throws -> String { try xmtpGroup.imageUrl() }
    public func description() async throws -> String { try xmtpGroup.description() }
    public func appData() async throws -> String { try xmtpGroup.appData() }

    public func updateAppData(_ appData: String) async throws {
        try await xmtpGroup.updateAppData(appData: appData)
    }

    public func updateName(_ name: String) async throws {
        try await xmtpGroup.updateName(name: name)
    }

    public func updateImageUrl(_ url: String) async throws {
        try await xmtpGroup.updateImageUrl(imageUrl: url)
    }

    public func updateDescription(_ description: String) async throws {
        try await xmtpGroup.updateDescription(description: description)
    }

    public func addMembers(inboxIds: [MessagingInboxID]) async throws {
        _ = try await xmtpGroup.addMembers(inboxIds: inboxIds)
    }

    public func removeMembers(inboxIds: [MessagingInboxID]) async throws {
        try await xmtpGroup.removeMembers(inboxIds: inboxIds)
    }

    public func permissionPolicySet() async throws -> MessagingPermissionPolicySet {
        MessagingPermissionPolicySet(try xmtpGroup.permissionPolicySet())
    }

    public func updateAddMemberPermission(_ permission: MessagingPermission) async throws {
        try await xmtpGroup.updateAddMemberPermission(
            newPermissionOption: permission.xmtpPermissionOption
        )
    }

    public func creatorInboxId() async throws -> MessagingInboxID {
        try await xmtpGroup.creatorInboxId()
    }

    public func isCreator() async throws -> Bool {
        try await xmtpGroup.isCreator()
    }

    public func isAdmin(inboxId: MessagingInboxID) async throws -> Bool {
        try xmtpGroup.isAdmin(inboxId: inboxId)
    }

    public func isSuperAdmin(inboxId: MessagingInboxID) async throws -> Bool {
        try xmtpGroup.isSuperAdmin(inboxId: inboxId)
    }

    public func listAdmins() async throws -> [MessagingInboxID] {
        try xmtpGroup.listAdmins()
    }

    public func listSuperAdmins() async throws -> [MessagingInboxID] {
        try xmtpGroup.listSuperAdmins()
    }

    public func isActive() async throws -> Bool {
        try xmtpGroup.isActive()
    }
}
