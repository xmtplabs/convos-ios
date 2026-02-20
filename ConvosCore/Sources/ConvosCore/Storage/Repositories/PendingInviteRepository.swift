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

public struct PendingInviteDetail: Codable, Hashable, Identifiable, Sendable {
    public var id: String { conversationId }
    public let conversationId: String
    public let clientId: String
    public let inboxId: String
    public let inviteTag: String
    public let conversationName: String?
    public let createdAt: Date
    public let memberCount: Int

    public init(
        conversationId: String,
        clientId: String,
        inboxId: String,
        inviteTag: String,
        conversationName: String?,
        createdAt: Date,
        memberCount: Int = 0
    ) {
        self.conversationId = conversationId
        self.clientId = clientId
        self.inboxId = inboxId
        self.inviteTag = inviteTag
        self.conversationName = conversationName
        self.createdAt = createdAt
        self.memberCount = memberCount
    }
}

public protocol PendingInviteRepositoryProtocol {
    func allPendingInvites() throws -> [PendingInviteInfo]
    func pendingInvites(for clientId: String) throws -> PendingInviteInfo?
    func clientIdsWithPendingInvites() throws -> Set<String>
    func hasPendingInvites(clientId: String) throws -> Bool
    func allPendingInviteDetails() throws -> [PendingInviteDetail]
    func stalePendingInviteClientIds(olderThan cutoff: Date) throws -> Set<String>
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

    public func pendingInvites(for clientId: String) throws -> PendingInviteInfo? {
        try databaseReader.read { db in
            try fetchPendingInvites(db: db, clientId: clientId)
        }
    }

    public func clientIdsWithPendingInvites() throws -> Set<String> {
        try databaseReader.read { db in
            let sql = """
                SELECT DISTINCT c.clientId
                FROM conversation c
                WHERE c.id LIKE 'draft-%'
                AND c.inviteTag IS NOT NULL
                AND c.inviteTag != ''
                """
            let clientIds = try String.fetchAll(db, sql: sql)
            return Set(clientIds)
        }
    }

    public func hasPendingInvites(clientId: String) throws -> Bool {
        try databaseReader.read { db in
            let count = try DBConversation
                .filter(DBConversation.Columns.clientId == clientId)
                .filter(DBConversation.Columns.id.like("draft-%"))
                .filter(DBConversation.Columns.inviteTag != nil)
                .filter(length(DBConversation.Columns.inviteTag) > 0)
                .fetchCount(db)
            return count > 0
        }
    }

    public func allPendingInviteDetails() throws -> [PendingInviteDetail] {
        try databaseReader.read { db in
            let sql = """
                SELECT
                    c.id as conversationId,
                    c.clientId,
                    c.inboxId,
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
            return try Row.fetchAll(db, sql: sql).map { row in
                PendingInviteDetail(
                    conversationId: row["conversationId"],
                    clientId: row["clientId"],
                    inboxId: row["inboxId"],
                    inviteTag: row["inviteTag"],
                    conversationName: row["name"],
                    createdAt: row["createdAt"],
                    memberCount: row["memberCount"]
                )
            }
        }
    }

    public func stalePendingInviteClientIds(olderThan cutoff: Date) throws -> Set<String> {
        try databaseReader.read { db in
            let sql = """
                SELECT DISTINCT c.clientId
                FROM conversation c
                WHERE c.id LIKE 'draft-%'
                    AND c.inviteTag IS NOT NULL
                    AND c.inviteTag != ''
                    AND c.createdAt < ?
                    AND (SELECT COUNT(*) FROM conversation_members cm WHERE cm.conversationId = c.id) <= 1
                """
            let clientIds = try String.fetchAll(db, sql: sql, arguments: [cutoff])
            return Set(clientIds)
        }
    }

    private func fetchAllPendingInvites(db: Database) throws -> [PendingInviteInfo] {
        let sql = """
            SELECT
                i.clientId,
                i.inboxId,
                GROUP_CONCAT(c.id) as pendingConversationIds
            FROM inbox i
            LEFT JOIN conversation c ON c.clientId = i.clientId
                AND c.id LIKE 'draft-%'
                AND c.inviteTag IS NOT NULL
                AND c.inviteTag != ''
            GROUP BY i.clientId, i.inboxId
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

    private func fetchPendingInvites(db: Database, clientId: String) throws -> PendingInviteInfo? {
        let sql = """
            SELECT
                i.clientId,
                i.inboxId,
                GROUP_CONCAT(c.id) as pendingConversationIds
            FROM inbox i
            LEFT JOIN conversation c ON c.clientId = i.clientId
                AND c.id LIKE 'draft-%'
                AND c.inviteTag IS NOT NULL
                AND c.inviteTag != ''
            WHERE i.clientId = ?
            GROUP BY i.clientId, i.inboxId
            """

        return try Row.fetchOne(db, sql: sql, arguments: [clientId]).map { row in
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
    public var staleCutoffResult: Set<String> = []

    public init() {}

    public func allPendingInvites() throws -> [PendingInviteInfo] {
        pendingInvites
    }

    public func pendingInvites(for clientId: String) throws -> PendingInviteInfo? {
        pendingInvites.first { $0.clientId == clientId }
    }

    public func clientIdsWithPendingInvites() throws -> Set<String> {
        Set(pendingInvites.filter { $0.hasPendingInvites }.map { $0.clientId })
    }

    public func hasPendingInvites(clientId: String) throws -> Bool {
        pendingInvites.first { $0.clientId == clientId }?.hasPendingInvites ?? false
    }

    public func allPendingInviteDetails() throws -> [PendingInviteDetail] {
        pendingInviteDetails
    }

    public func stalePendingInviteClientIds(olderThan cutoff: Date) throws -> Set<String> {
        staleCutoffResult
    }
}
