import Foundation

// MARK: - Query / sort / filter

/// Query options for listing conversations.
///
/// Mirrors the parameter set currently passed through `ConversationsProvider`
/// in `XMTPClientProvider.swift:70-102`.
public struct MessagingConversationQuery: Hashable, Sendable {
    public var createdAfterNs: Int64?
    public var createdBeforeNs: Int64?
    public var lastActivityAfterNs: Int64?
    public var lastActivityBeforeNs: Int64?
    public var limit: Int?
    public var consentStates: [MessagingConsentState]?
    public var orderBy: MessagingOrderBy

    public init(
        createdAfterNs: Int64? = nil,
        createdBeforeNs: Int64? = nil,
        lastActivityAfterNs: Int64? = nil,
        lastActivityBeforeNs: Int64? = nil,
        limit: Int? = nil,
        consentStates: [MessagingConsentState]? = nil,
        orderBy: MessagingOrderBy = .lastActivity
    ) {
        self.createdAfterNs = createdAfterNs
        self.createdBeforeNs = createdBeforeNs
        self.lastActivityAfterNs = lastActivityAfterNs
        self.lastActivityBeforeNs = lastActivityBeforeNs
        self.limit = limit
        self.consentStates = consentStates
        self.orderBy = orderBy
    }
}

public enum MessagingOrderBy: String, Hashable, Sendable, Codable {
    case createdAt
    case lastActivity
}

public enum MessagingConversationFilter: String, Hashable, Sendable, Codable {
    case all
    case groups
    case dms
}

/// Replacement for `XMTPiOS.GroupSyncSummary` (returned from
/// `syncAllConversations`).
public struct MessagingSyncSummary: Hashable, Sendable, Codable {
    public let numEligible: UInt64
    public let numSynced: UInt64

    public init(numEligible: UInt64, numSynced: UInt64) {
        self.numEligible = numEligible
        self.numSynced = numSynced
    }
}

// MARK: - Conversations API

/// Convos-owned mirror of `XMTPiOS.Conversations`.
///
/// Replaces the existing `ConversationsProvider` protocol in
/// `XMTPClientProvider.swift:70-123`, which currently leaks raw
/// `XMTPiOS.Conversation` / `Dm` / `Group` types in its return shapes.
public protocol MessagingConversations: AnyObject, Sendable {
    func list(query: MessagingConversationQuery) async throws -> [MessagingConversation]
    func listGroups(query: MessagingConversationQuery) async throws -> [any MessagingGroup]
    func listDms(query: MessagingConversationQuery) async throws -> [any MessagingDm]

    func find(conversationId: String) async throws -> MessagingConversation?
    func findDmByInboxId(_ inboxId: MessagingInboxID) async throws -> (any MessagingDm)?
    func findMessage(messageId: String) async throws -> MessagingMessage?
    func findOrCreateDm(with inboxId: MessagingInboxID) async throws -> any MessagingDm

    /// Creates a purely local group handle before any members or
    /// network commit — the optimistic-create flow behind Convos'
    /// invite builder (`XMTPClientProvider.prepareConversation`).
    func newGroupOptimistic() async throws -> any MessagingGroup

    func newGroup(
        withInboxIds inboxIds: [MessagingInboxID],
        name: String,
        imageUrl: String,
        description: String
    ) async throws -> any MessagingGroup

    func sync() async throws
    func syncAll(consentStates: [MessagingConsentState]?) async throws -> MessagingSyncSummary

    func streamAll(
        filter: MessagingConversationFilter,
        onClose: (@Sendable () -> Void)?
    ) -> MessagingStream<MessagingConversation>

    func streamAllMessages(
        filter: MessagingConversationFilter,
        consentStates: [MessagingConsentState]?,
        onClose: (@Sendable () -> Void)?
    ) -> MessagingStream<MessagingMessage>
}
