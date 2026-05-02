import ConvosConnections
import Foundation
import GRDB

public actor GRDBHealthBackgroundSubscriptionStore: HealthBackgroundSubscriptionStore {
    private let dbWriter: any DatabaseWriter
    private let dbReader: any DatabaseReader

    public init(dbWriter: any DatabaseWriter, dbReader: any DatabaseReader) {
        self.dbWriter = dbWriter
        self.dbReader = dbReader
    }

    public func upsert(_ subscription: HealthBackgroundSubscription) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: """
                    INSERT INTO healthBackgroundSubscription
                        (conversationId, agentInboxId, typeIdentifier, frequency, historyDays, anchor, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(conversationId, agentInboxId, typeIdentifier) DO UPDATE SET
                        frequency = excluded.frequency,
                        historyDays = excluded.historyDays,
                        anchor = excluded.anchor,
                        updatedAt = excluded.updatedAt
                    """,
                arguments: [
                    subscription.conversationId,
                    subscription.agentInboxId,
                    subscription.typeIdentifier.rawValue,
                    subscription.frequency.rawValue,
                    subscription.historyDays,
                    subscription.anchor,
                    subscription.createdAt,
                    subscription.updatedAt,
                ]
            )
        }
    }

    public func delete(
        conversationId: String,
        agentInboxId: String,
        typeIdentifier: HealthSampleType
    ) async throws {
        try await dbWriter.write { db in
            _ = try DBHealthBackgroundSubscription
                .filter(DBHealthBackgroundSubscription.Columns.conversationId == conversationId)
                .filter(DBHealthBackgroundSubscription.Columns.agentInboxId == agentInboxId)
                .filter(DBHealthBackgroundSubscription.Columns.typeIdentifier == typeIdentifier.rawValue)
                .deleteAll(db)
        }
    }

    public func updateAnchor(
        conversationId: String,
        agentInboxId: String,
        typeIdentifier: HealthSampleType,
        anchor: Data
    ) async throws {
        try await dbWriter.write { db in
            try db.execute(
                sql: """
                    UPDATE healthBackgroundSubscription
                       SET anchor = ?, updatedAt = ?
                     WHERE conversationId = ? AND agentInboxId = ? AND typeIdentifier = ?
                    """,
                arguments: [anchor, Date(), conversationId, agentInboxId, typeIdentifier.rawValue]
            )
        }
    }

    public func allSubscriptions() async throws -> [HealthBackgroundSubscription] {
        try await dbReader.read { db in
            try DBHealthBackgroundSubscription.fetchAll(db).compactMap(Self.toDomain)
        }
    }

    public func subscriptions(forType typeIdentifier: HealthSampleType) async throws -> [HealthBackgroundSubscription] {
        try await dbReader.read { db in
            try DBHealthBackgroundSubscription
                .filter(DBHealthBackgroundSubscription.Columns.typeIdentifier == typeIdentifier.rawValue)
                .fetchAll(db)
                .compactMap(Self.toDomain)
        }
    }

    public func subscriptions(forConversation conversationId: String) async throws -> [HealthBackgroundSubscription] {
        try await dbReader.read { db in
            try DBHealthBackgroundSubscription
                .filter(DBHealthBackgroundSubscription.Columns.conversationId == conversationId)
                .fetchAll(db)
                .compactMap(Self.toDomain)
        }
    }

    private static func toDomain(_ row: DBHealthBackgroundSubscription) -> HealthBackgroundSubscription? {
        guard let type = HealthSampleType(rawValue: row.typeIdentifier),
              let frequency = HealthBackgroundFrequency(rawValue: row.frequency) else {
            return nil
        }
        return HealthBackgroundSubscription(
            conversationId: row.conversationId,
            agentInboxId: row.agentInboxId,
            typeIdentifier: type,
            frequency: frequency,
            historyDays: row.historyDays,
            anchor: row.anchor,
            createdAt: row.createdAt,
            updatedAt: row.updatedAt
        )
    }
}

struct DBHealthBackgroundSubscription: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "healthBackgroundSubscription"

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let agentInboxId: Column = Column(CodingKeys.agentInboxId)
        static let typeIdentifier: Column = Column(CodingKeys.typeIdentifier)
    }

    let conversationId: String
    let agentInboxId: String
    let typeIdentifier: String
    let frequency: String
    let historyDays: Int
    let anchor: Data?
    let createdAt: Date
    let updatedAt: Date
}
