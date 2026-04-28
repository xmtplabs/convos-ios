import Combine
import Foundation
import GRDB

public protocol CloudConnectionRepositoryProtocol: Sendable {
    func connections() async throws -> [CloudConnection]
    func connectionsPublisher() -> AnyPublisher<[CloudConnection], Never>
    func grantsPublisher(for conversationId: String) -> AnyPublisher<[CloudConnectionGrant], Never>
    func grants(for conversationId: String) async throws -> [CloudConnectionGrant]
}

public final class CloudConnectionRepository: CloudConnectionRepositoryProtocol, Sendable {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func connections() async throws -> [CloudConnection] {
        try await databaseReader.read { db in
            try DBCloudConnection
                .filter(DBCloudConnection.Columns.status == CloudConnectionStatus.active.rawValue)
                .order(DBCloudConnection.Columns.connectedAt.desc)
                .fetchAll(db)
                .map { $0.toConnection() }
        }
    }

    public func connectionsPublisher() -> AnyPublisher<[CloudConnection], Never> {
        ValueObservation
            .tracking { db in
                try DBCloudConnection
                    .filter(DBCloudConnection.Columns.status == CloudConnectionStatus.active.rawValue)
                    .order(DBCloudConnection.Columns.connectedAt.desc)
                    .fetchAll(db)
                    .map { $0.toConnection() }
            }
            .publisher(in: databaseReader, scheduling: .immediate)
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    public func grants(for conversationId: String) async throws -> [CloudConnectionGrant] {
        try await databaseReader.read { db in
            try Self.fetchActiveGrants(conversationId: conversationId, db: db)
        }
    }

    public func grantsPublisher(for conversationId: String) -> AnyPublisher<[CloudConnectionGrant], Never> {
        ValueObservation
            .tracking { db in
                try Self.fetchActiveGrants(conversationId: conversationId, db: db)
            }
            .publisher(in: databaseReader, scheduling: .immediate)
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    /// Returns grants for a conversation, but only if the conversation has not
    /// expired. The FK `connectionGrant.conversationId → conversation(id) ON
    /// DELETE CASCADE` cleans up after the conversation row is deleted, but
    /// `ExpiredConversationsWorker` keeps the row around and only prunes
    /// messages — so without this filter, expired-but-undeleted conversations
    /// would surface stale grants.
    private static func fetchActiveGrants(
        conversationId: String,
        db: Database
    ) throws -> [CloudConnectionGrant] {
        let conversation = try DBConversation
            .filter(DBConversation.Columns.id == conversationId)
            .fetchOne(db)
        if let expiresAt = conversation?.expiresAt, expiresAt <= Date() {
            return []
        }
        return try DBCloudConnectionGrant
            .filter(DBCloudConnectionGrant.Columns.conversationId == conversationId)
            .fetchAll(db)
            .map { $0.toConnectionGrant() }
    }
}
