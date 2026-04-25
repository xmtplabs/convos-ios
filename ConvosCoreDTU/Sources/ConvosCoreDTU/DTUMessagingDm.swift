import ConvosCore
import ConvosMessagingProtocols
import Foundation
import XMTPDTU

/// DTU-backed implementation of `MessagingDm`.
///
/// DTU's engine does not today distinguish groups from DMs at the action
/// level — both flow through `create_group` / `send` / `list_messages`.
/// The adapter maps the abstraction's DM surface onto the same universe
/// actions, with a cached `peerInboxId` supplied at construction time
/// (the single counterparty alias).
///
/// The shared conversation-core surface — consent, members, messages,
/// send flows — is delegated to an internal `DTUMessagingGroup` wrapper
/// so the DM class stays small and both types share one implementation
/// of the DTU-specific quirks (synthesized timestamps, client-side query
/// filtering, etc.).
public final class DTUMessagingDm: MessagingDm, @unchecked Sendable {
    private let core: DTUMessagingGroup
    private let cachedPeerInboxId: MessagingInboxID

    public init(
        context: DTUMessagingClientContext,
        conversationAlias: String,
        peerInboxId: MessagingInboxID,
        creatorInboxId: MessagingInboxID? = nil,
        createdAtNs: Int64 = 0,
        lastActivityAtNs: Int64 = 0
    ) {
        self.core = DTUMessagingGroup(
            context: context,
            conversationAlias: conversationAlias,
            creatorInboxId: creatorInboxId,
            createdAtNs: createdAtNs,
            lastActivityAtNs: lastActivityAtNs
        )
        self.cachedPeerInboxId = peerInboxId
    }

    // MARK: - MessagingConversationCore (forwarded to core)

    public var id: String { core.id }
    public var topic: String { core.topic }
    public var createdAtNs: Int64 { core.createdAtNs }
    public var lastActivityAtNs: Int64 { core.lastActivityAtNs }

    public func consentState() async throws -> MessagingConsentState {
        try await core.consentState()
    }

    public func updateConsentState(_ state: MessagingConsentState) async throws {
        try await core.updateConsentState(state)
    }

    public func debugInformation() async throws -> MessagingConversationDebugInfo {
        try await core.debugInformation()
    }

    public func sync() async throws {
        try await core.sync()
    }

    public func members() async throws -> [MessagingMember] {
        try await core.members()
    }

    public func messages(query: MessagingMessageQuery) async throws -> [MessagingMessage] {
        try await core.messages(query: query)
    }

    public func lastMessage() async throws -> MessagingMessage? {
        try await core.lastMessage()
    }

    public func countMessages(query: MessagingMessageQuery) async throws -> Int64 {
        try await core.countMessages(query: query)
    }

    public func streamMessages(
        onClose: (@Sendable () -> Void)?
    ) -> MessagingStream<MessagingMessage> {
        core.streamMessages(onClose: onClose)
    }

    public func getHmacKeys() async throws -> MessagingHmacKeys {
        try await core.getHmacKeys()
    }

    public func getPushTopics() async throws -> [String] {
        try await core.getPushTopics()
    }

    public func processMessage(bytes: Data) async throws -> MessagingMessage? {
        try await core.processMessage(bytes: bytes)
    }

    // MARK: - Send flows (forwarded)

    public func prepare(
        encodedContent: MessagingEncodedContent,
        options: MessagingSendOptions?
    ) async throws -> MessagingPreparedMessage {
        try await core.prepare(encodedContent: encodedContent, options: options)
    }

    public func sendOptimistic(
        encodedContent: MessagingEncodedContent,
        options: MessagingSendOptions?
    ) async throws -> MessagingPreparedMessage {
        try await core.sendOptimistic(encodedContent: encodedContent, options: options)
    }

    public func publish() async throws { try await core.publish() }

    public func publish(messageId: String) async throws {
        try await core.publish(messageId: messageId)
    }

    // MARK: - MessagingDm specifics

    public func peerInboxId() async throws -> MessagingInboxID {
        cachedPeerInboxId
    }
}
