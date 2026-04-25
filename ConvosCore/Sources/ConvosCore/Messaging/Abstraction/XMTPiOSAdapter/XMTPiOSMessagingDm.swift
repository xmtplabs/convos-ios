import ConvosMessagingProtocols
import Foundation
@preconcurrency import XMTPiOS

/// XMTPiOS-backed implementation of `MessagingDm`.
///
/// Wraps `XMTPiOS.Dm`. Apart from the missing group-specific methods
/// (name / image / member management / permissions), the surface is
/// exactly the same as `XMTPiOSMessagingGroup`, forwarded onto the Dm
/// handle.
public final class XMTPiOSMessagingDm: MessagingDm, @unchecked Sendable {
    let xmtpDm: XMTPiOS.Dm

    public init(xmtpDm: XMTPiOS.Dm) {
        self.xmtpDm = xmtpDm
    }

    // Stage 4 bridge — remove when Stage 3 writers migrate.
    // Stage 4 callers hold `any MessagingDm` but the Storage/Writers
    // layer still takes raw `XMTPiOS.Dm`. Callers downcast to
    // `XMTPiOSMessagingDm` and reach through this accessor until the
    // writers are migrated. No new consumers should take this path.
    public var underlyingXMTPiOSDm: XMTPiOS.Dm { xmtpDm }

    // MARK: - MessagingConversationCore

    public var id: String { xmtpDm.id }
    public var topic: String { xmtpDm.topic }
    public var createdAtNs: Int64 { xmtpDm.createdAtNs }
    public var lastActivityAtNs: Int64 { xmtpDm.lastActivityAtNs }

    public func consentState() async throws -> MessagingConsentState {
        MessagingConsentState(try xmtpDm.consentState())
    }

    public func updateConsentState(_ state: MessagingConsentState) async throws {
        try await xmtpDm.updateConsentState(state: state.xmtpConsentState)
    }

    public func debugInformation() async throws -> MessagingConversationDebugInfo {
        MessagingConversationDebugInfo(try await xmtpDm.getDebugInformation())
    }

    public func sync() async throws {
        try await xmtpDm.sync()
    }

    public func members() async throws -> [MessagingMember] {
        try await xmtpDm.members.map(MessagingMember.init)
    }

    public func messages(query: MessagingMessageQuery) async throws -> [MessagingMessage] {
        let excludeStandard = query.excludeContentTypes?
            .compactMap(XMTPiOSContentTypeMapper.standardContentType(for:))
        let raw = try await xmtpDm.messages(
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
        guard let xmtpMessage = try await xmtpDm.lastMessage() else { return nil }
        return try? MessagingMessage(xmtpMessage)
    }

    public func countMessages(query: MessagingMessageQuery) async throws -> Int64 {
        let excludeStandard = query.excludeContentTypes?
            .compactMap(XMTPiOSContentTypeMapper.standardContentType(for:))
        return try xmtpDm.countMessages(
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
        XMTPiOSMessageStreamBridge.bridge(xmtpDm.streamMessages(onClose: onClose))
    }

    public func getHmacKeys() async throws -> MessagingHmacKeys {
        MessagingHmacKeys(try xmtpDm.getHmacKeys())
    }

    public func getPushTopics() async throws -> [String] {
        try await xmtpDm.getPushTopics()
    }

    public func processMessage(bytes: Data) async throws -> MessagingMessage? {
        guard let xmtpMessage = try await xmtpDm.processMessage(messageBytes: bytes) else {
            return nil
        }
        return try MessagingMessage(xmtpMessage)
    }

    // MARK: - Send flows

    public func prepare(
        encodedContent: MessagingEncodedContent,
        options: MessagingSendOptions?
    ) async throws -> MessagingPreparedMessage {
        let messageId = try await xmtpDm.prepareMessage(
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
        let messageId = try await xmtpDm.prepareMessage(
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
        try await xmtpDm.publishMessages()
    }

    public func publish(messageId: String) async throws {
        try await xmtpDm.publishMessage(messageId: messageId)
    }

    // MARK: - MessagingDm specifics

    public func peerInboxId() async throws -> MessagingInboxID {
        try xmtpDm.peerInboxId
    }
}
