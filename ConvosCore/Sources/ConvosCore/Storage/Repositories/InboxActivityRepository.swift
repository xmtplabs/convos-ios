import Combine
import Foundation
import GRDB

public struct InboxActivity: Codable, Hashable, Identifiable {
    public var id: String { clientId }
    public let clientId: String
    public let inboxId: String
    public let lastActivity: Date?
    public let conversationCount: Int

    public init(clientId: String, inboxId: String, lastActivity: Date?, conversationCount: Int) {
        self.clientId = clientId
        self.inboxId = inboxId
        self.lastActivity = lastActivity
        self.conversationCount = conversationCount
    }
}

public protocol InboxActivityRepositoryProtocol: Sendable {
    func allInboxActivities() throws -> [InboxActivity]
    func inboxActivity(for clientId: String) throws -> InboxActivity?
    func topActiveInboxes(limit: Int) throws -> [InboxActivity]
    func leastActiveInbox(excluding clientIds: Set<String>) throws -> InboxActivity?
    /// Returns a map of clientId -> [conversationId] for the specified client IDs
    func conversationIds(for clientIds: [String]) throws -> [String: [String]]
}

public struct InboxActivityRepository: InboxActivityRepositoryProtocol, @unchecked Sendable {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func allInboxActivities() throws -> [InboxActivity] {
        try databaseReader.read { db in
            try fetchInboxActivities(db: db)
        }
    }

    public func inboxActivity(for clientId: String) throws -> InboxActivity? {
        try databaseReader.read { db in
            try fetchInboxActivity(db: db, clientId: clientId)
        }
    }

    public func topActiveInboxes(limit: Int) throws -> [InboxActivity] {
        try databaseReader.read { db in
            let activities = try fetchInboxActivities(db: db)
            return Array(activities.prefix(limit))
        }
    }

    public func leastActiveInbox(excluding clientIds: Set<String>) throws -> InboxActivity? {
        try databaseReader.read { db in
            let activities = try fetchInboxActivities(db: db)
            return activities.last { !clientIds.contains($0.clientId) }
        }
    }

    public func conversationIds(for clientIds: [String]) throws -> [String: [String]] {
        guard !clientIds.isEmpty else { return [:] }

        return try databaseReader.read { db in
            let sql = """
                SELECT clientId, id as conversationId
                FROM conversation
                WHERE clientId IN (\(clientIds.map { _ in "?" }.joined(separator: ", ")))
                    AND id NOT LIKE 'draft-%'
                """

            var result: [String: [String]] = [:]
            for clientId in clientIds {
                result[clientId] = []
            }

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(clientIds))
            for row in rows {
                let clientId: String = row["clientId"]
                let conversationId: String = row["conversationId"]
                result[clientId, default: []].append(conversationId)
            }
            return result
        }
    }

    private func fetchInboxActivities(db: Database) throws -> [InboxActivity] {
        let sql = """
            SELECT
                i.clientId,
                i.inboxId,
                MAX(m.date) as lastActivity,
                COUNT(DISTINCT c.id) as conversationCount
            FROM inbox i
            LEFT JOIN conversation c ON c.clientId = i.clientId
                AND c.id NOT LIKE 'draft-%'
            LEFT JOIN message m ON m.conversationId = c.id
            GROUP BY i.clientId, i.inboxId
            ORDER BY lastActivity DESC NULLS LAST
            """

        return try Row.fetchAll(db, sql: sql).map { row in
            InboxActivity(
                clientId: row["clientId"],
                inboxId: row["inboxId"],
                lastActivity: row["lastActivity"],
                conversationCount: row["conversationCount"]
            )
        }
    }

    private func fetchInboxActivity(db: Database, clientId: String) throws -> InboxActivity? {
        let sql = """
            SELECT
                i.clientId,
                i.inboxId,
                MAX(m.date) as lastActivity,
                COUNT(DISTINCT c.id) as conversationCount
            FROM inbox i
            LEFT JOIN conversation c ON c.clientId = i.clientId
                AND c.id NOT LIKE 'draft-%'
            LEFT JOIN message m ON m.conversationId = c.id
            WHERE i.clientId = ?
            GROUP BY i.clientId, i.inboxId
            """

        return try Row.fetchOne(db, sql: sql, arguments: [clientId]).map { row in
            InboxActivity(
                clientId: row["clientId"],
                inboxId: row["inboxId"],
                lastActivity: row["lastActivity"],
                conversationCount: row["conversationCount"]
            )
        }
    }
}

public final class MockInboxActivityRepository: InboxActivityRepositoryProtocol, @unchecked Sendable {
    public var activities: [InboxActivity] = []
    public var mockConversationIds: [String: [String]] = [:]

    public init() {}

    public func allInboxActivities() throws -> [InboxActivity] {
        activities.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    }

    public func inboxActivity(for clientId: String) throws -> InboxActivity? {
        activities.first { $0.clientId == clientId }
    }

    public func topActiveInboxes(limit: Int) throws -> [InboxActivity] {
        Array(try allInboxActivities().prefix(limit))
    }

    public func leastActiveInbox(excluding clientIds: Set<String>) throws -> InboxActivity? {
        try allInboxActivities().last { !clientIds.contains($0.clientId) }
    }

    public func conversationIds(for clientIds: [String]) throws -> [String: [String]] {
        var result: [String: [String]] = [:]
        for clientId in clientIds {
            result[clientId] = mockConversationIds[clientId] ?? []
        }
        return result
    }
}
