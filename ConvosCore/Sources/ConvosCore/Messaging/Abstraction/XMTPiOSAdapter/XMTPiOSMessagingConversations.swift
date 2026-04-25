import ConvosMessagingProtocols
import Foundation
@preconcurrency import XMTPiOS

/// XMTPiOS-backed implementation of `MessagingConversations`.
///
/// Wraps `XMTPiOS.Conversations` and maps its return types through the
/// adapter classes / value mappers. Mirrors the current
/// `ConversationsProvider` seam in `XMTPClientProvider.swift:70-123`
/// without leaking `XMTPiOS.Conversation` / `Group` / `Dm` into the
/// protocol surface.
public final class XMTPiOSMessagingConversations: MessagingConversations, @unchecked Sendable {
    let xmtpConversations: XMTPiOS.Conversations

    public init(xmtpConversations: XMTPiOS.Conversations) {
        self.xmtpConversations = xmtpConversations
    }

    // MARK: - Listing

    public func list(query: MessagingConversationQuery) async throws -> [MessagingConversation] {
        let xmtpStates = query.consentStates?.map(\.xmtpConsentState)
        let xmtpList = try await xmtpConversations.list(
            createdAfterNs: query.createdAfterNs,
            createdBeforeNs: query.createdBeforeNs,
            lastActivityBeforeNs: query.lastActivityBeforeNs,
            lastActivityAfterNs: query.lastActivityAfterNs,
            limit: query.limit,
            consentStates: xmtpStates,
            orderBy: XMTPiOS.ConversationsOrderBy(query.orderBy)
        )
        return xmtpList.map(XMTPiOSConversationAdapter.messagingConversation)
    }

    public func listGroups(query: MessagingConversationQuery) async throws -> [any MessagingGroup] {
        let xmtpStates = query.consentStates?.map(\.xmtpConsentState)
        let xmtpGroups = try xmtpConversations.listGroups(
            createdAfterNs: query.createdAfterNs,
            createdBeforeNs: query.createdBeforeNs,
            lastActivityAfterNs: query.lastActivityAfterNs,
            lastActivityBeforeNs: query.lastActivityBeforeNs,
            limit: query.limit,
            consentStates: xmtpStates,
            orderBy: XMTPiOS.ConversationsOrderBy(query.orderBy)
        )
        return xmtpGroups.map { XMTPiOSMessagingGroup(xmtpGroup: $0) }
    }

    public func listDms(query: MessagingConversationQuery) async throws -> [any MessagingDm] {
        let xmtpStates = query.consentStates?.map(\.xmtpConsentState)
        let xmtpDms = try xmtpConversations.listDms(
            createdAfterNs: query.createdAfterNs,
            createdBeforeNs: query.createdBeforeNs,
            lastActivityBeforeNs: query.lastActivityBeforeNs,
            lastActivityAfterNs: query.lastActivityAfterNs,
            limit: query.limit,
            consentStates: xmtpStates,
            orderBy: XMTPiOS.ConversationsOrderBy(query.orderBy)
        )
        return xmtpDms.map { XMTPiOSMessagingDm(xmtpDm: $0) }
    }

    // MARK: - Find

    public func find(conversationId: String) async throws -> MessagingConversation? {
        guard let xmtpConversation = try await xmtpConversations.findConversation(
            conversationId: conversationId
        ) else {
            return nil
        }
        return XMTPiOSConversationAdapter.messagingConversation(xmtpConversation)
    }

    public func findDmByInboxId(_ inboxId: MessagingInboxID) async throws -> (any MessagingDm)? {
        guard let xmtpDm = try xmtpConversations.findDmByInboxId(inboxId: inboxId) else {
            return nil
        }
        return XMTPiOSMessagingDm(xmtpDm: xmtpDm)
    }

    public func findMessage(messageId: String) async throws -> MessagingMessage? {
        guard let xmtpMessage = try xmtpConversations.findMessage(messageId: messageId) else {
            return nil
        }
        return try MessagingMessage(xmtpMessage)
    }

    public func findOrCreateDm(with inboxId: MessagingInboxID) async throws -> any MessagingDm {
        let xmtpDm = try await xmtpConversations.findOrCreateDm(
            with: inboxId,
            disappearingMessageSettings: nil
        )
        return XMTPiOSMessagingDm(xmtpDm: xmtpDm)
    }

    // MARK: - Create

    public func newGroupOptimistic() async throws -> any MessagingGroup {
        let xmtpGroup = try xmtpConversations.newGroupOptimistic()
        return XMTPiOSMessagingGroup(xmtpGroup: xmtpGroup)
    }

    public func newGroup(
        withInboxIds inboxIds: [MessagingInboxID],
        name: String,
        imageUrl: String,
        description: String
    ) async throws -> any MessagingGroup {
        let xmtpGroup = try await xmtpConversations.newGroup(
            with: inboxIds,
            name: name,
            imageUrl: imageUrl,
            description: description
        )
        return XMTPiOSMessagingGroup(xmtpGroup: xmtpGroup)
    }

    // MARK: - Sync

    public func sync() async throws {
        try await xmtpConversations.sync()
    }

    public func syncAll(consentStates: [MessagingConsentState]?) async throws -> MessagingSyncSummary {
        let xmtpStates = consentStates?.map(\.xmtpConsentState)
        let summary = try await xmtpConversations.syncAllConversations(consentStates: xmtpStates)
        return MessagingSyncSummary(summary)
    }

    // MARK: - Streams

    public func streamAll(
        filter: MessagingConversationFilter,
        onClose: (@Sendable () -> Void)?
    ) -> MessagingStream<MessagingConversation> {
        let xmtpStream = xmtpConversations.stream(
            type: XMTPiOS.ConversationFilterType(filter),
            onClose: onClose
        )
        return XMTPiOSConversationStreamBridge.bridge(xmtpStream)
    }

    public func streamAllMessages(
        filter: MessagingConversationFilter,
        consentStates: [MessagingConsentState]?,
        onClose: (@Sendable () -> Void)?
    ) -> MessagingStream<MessagingMessage> {
        let xmtpStates = consentStates?.map(\.xmtpConsentState)
        let xmtpStream = xmtpConversations.streamAllMessages(
            type: XMTPiOS.ConversationFilterType(filter),
            consentStates: xmtpStates,
            onClose: onClose
        )
        return XMTPiOSMessageStreamBridge.bridge(xmtpStream)
    }
}
