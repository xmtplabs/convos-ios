import Combine
import Foundation
import GRDB

public struct PendingInviteInfo: Codable, Hashable, Identifiable {
    public var id: String { clientId }
    public let clientId: String
    public let inboxId: String
    public let pendingConversationIds: [String]
    public let hasPendingInvites: Bool

    public init(clientId: String, inboxId: String, pendingConversationIds: [String]) {
        self.clientId = clientId
        self.inboxId = inboxId
        self.pendingConversationIds = pendingConversationIds
        self.hasPendingInvites = !pendingConversationIds.isEmpty
    }
}

public struct OtherConversationInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String { conversationId }
    public let conversationId: String
    public let name: String?
    public let clientConversationId: String

    public init(conversationId: String, name: String?, clientConversationId: String) {
        self.conversationId = conversationId
        self.name = name
        self.clientConversationId = clientConversationId
    }
}

public struct PendingInviteDetail: Codable, Hashable, Identifiable, Sendable {
    public var id: String { conversationId }
    public let conversationId: String
    public let clientId: String
    public let inboxId: String
    public let inviteTag: String
    public let conversationName: String?
    public let createdAt: Date
    public let memberCount: Int
    public let otherConversations: [OtherConversationInfo]

    public var hasOtherConversations: Bool {
        !otherConversations.isEmpty
    }

    public init(
        conversationId: String,
        clientId: String,
        inboxId: String,
        inviteTag: String,
        conversationName: String?,
        createdAt: Date,
        memberCount: Int = 0,
        otherConversations: [OtherConversationInfo] = []
    ) {
        self.conversationId = conversationId
        self.clientId = clientId
        self.inboxId = inboxId
        self.inviteTag = inviteTag
        self.conversationName = conversationName
        self.createdAt = createdAt
        self.memberCount = memberCount
        self.otherConversations = otherConversations
    }
}

/// Read-only view over the local user's pending (draft + tagged) invites.
///
/// Single-inbox refactor (C10): `clientId`-scoped query methods
/// (`pendingInvites(for:)`, `hasPendingInvites(clientId:)`,
/// `clientIdsWithPendingInvites`, `stalePendingInviteClientIds`) were retired
/// because they only existed to feed the multi-inbox capacity tier in
/// `InboxLifecycleManager` (deleted in C4a). With one inbox per user the
/// answer to "which inboxes have pending invites" collapses to "the user has
/// some, or doesn't" — the no-arg `allPendingInvites()` covers that. The
/// `clientId` / `inboxId` properties on `PendingInviteInfo` and
/// `PendingInviteDetail` survive until C11 drops the columns from
/// `DBConversation`.
public protocol PendingInviteRepositoryProtocol {
    /// Returns one `PendingInviteInfo` per inbox row, with the inbox's pending
    /// draft conversation IDs. In single-inbox mode this is at most one entry.
    func allPendingInvites() throws -> [PendingInviteInfo]

    /// Returns one `PendingInviteDetail` per pending draft conversation, ordered
    /// by `createdAt` ascending. Used by the debug surface.
    func allPendingInviteDetails() throws -> [PendingInviteDetail]
}

public struct PendingInviteRepository: PendingInviteRepositoryProtocol {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func allPendingInvites() throws -> [PendingInviteInfo] {
        try databaseReader.read { db in
            try fetchAllPendingInvites(db: db)
        }
    }

    public func allPendingInviteDetails() throws -> [PendingInviteDetail] {
        try databaseReader.read { db in
            // C11c: `conversation.inboxId`/`.clientId` are gone. Read the
            // singleton `clientId`/`inboxId` from `DBInbox` once and attach
            // them to every detail row — the debug surface still surfaces
            // them (the `PendingInviteDetail.clientId`/`.inboxId` fields
            // survive), they just come from a different source.
            let singleton = try Row.fetchOne(
                db,
                sql: "SELECT clientId, inboxId FROM inbox LIMIT 1"
            )
            let singletonClientId: String = singleton?["clientId"] ?? ""
            let singletonInboxId: String = singleton?["inboxId"] ?? ""

            let sql = """
                SELECT
                    c.id as conversationId,
                    c.inviteTag,
                    c.name,
                    c.createdAt,
                    (SELECT COUNT(*) FROM conversation_members cm WHERE cm.conversationId = c.id) as memberCount
                FROM conversation c
                WHERE c.id LIKE 'draft-%'
                    AND c.inviteTag IS NOT NULL
                    AND c.inviteTag != ''
                ORDER BY c.createdAt ASC
                """

            let pendingInvites = try Row.fetchAll(db, sql: sql)

            return try pendingInvites.map { row in
                let conversationId: String = row["conversationId"]

                // "Other conversations" was a per-inbox grouping used by the
                // multi-inbox debug surface. In single-inbox mode it's just
                // "every other non-draft conversation this account knows
                // about" — the query simplifies to drop the clientId filter.
                let otherConvosSql = """
                    SELECT id, name, clientConversationId
                    FROM conversation
                    WHERE id != ?
                        AND id NOT LIKE 'draft-%'
                    """
                let otherConvos = try Row.fetchAll(db, sql: otherConvosSql, arguments: [conversationId])
                    .map { otherRow in
                        OtherConversationInfo(
                            conversationId: otherRow["id"],
                            name: otherRow["name"],
                            clientConversationId: otherRow["clientConversationId"]
                        )
                    }

                return PendingInviteDetail(
                    conversationId: conversationId,
                    clientId: singletonClientId,
                    inboxId: singletonInboxId,
                    inviteTag: row["inviteTag"],
                    conversationName: row["name"],
                    createdAt: row["createdAt"],
                    memberCount: row["memberCount"],
                    otherConversations: otherConvos
                )
            }
        }
    }

    private func fetchAllPendingInvites(db: Database) throws -> [PendingInviteInfo] {
        // C11c: conversation rows no longer carry `clientId`. Every draft
        // conversation belongs to the sole inbox, so the old JOIN just
        // concatenates all drafts onto the singleton inbox row.
        let sql = """
            SELECT
                i.clientId,
                i.inboxId,
                (
                    SELECT GROUP_CONCAT(c.id)
                    FROM conversation c
                    WHERE c.id LIKE 'draft-%'
                        AND c.inviteTag IS NOT NULL
                        AND c.inviteTag != ''
                ) as pendingConversationIds
            FROM inbox i
            """

        return try Row.fetchAll(db, sql: sql).map { row in
            let conversationIdsString: String? = row["pendingConversationIds"]
            let conversationIds = conversationIdsString?
                .split(separator: ",")
                .map { String($0) } ?? []
            return PendingInviteInfo(
                clientId: row["clientId"],
                inboxId: row["inboxId"],
                pendingConversationIds: conversationIds
            )
        }
    }
}

public final class MockPendingInviteRepository: PendingInviteRepositoryProtocol, @unchecked Sendable {
    public var pendingInvites: [PendingInviteInfo] = []
    public var pendingInviteDetails: [PendingInviteDetail] = []

    public init() {}

    public func allPendingInvites() throws -> [PendingInviteInfo] {
        pendingInvites
    }

    public func allPendingInviteDetails() throws -> [PendingInviteDetail] {
        pendingInviteDetails
    }
}
