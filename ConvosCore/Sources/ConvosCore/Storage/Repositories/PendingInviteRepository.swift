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

public protocol PendingInviteRepositoryProtocol {
    func allPendingInvites() throws -> [PendingInviteInfo]
    func pendingInvites(for clientId: String) throws -> PendingInviteInfo?
    func clientIdsWithPendingInvites() throws -> Set<String>
    func hasPendingInvites(clientId: String) throws -> Bool
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
}
