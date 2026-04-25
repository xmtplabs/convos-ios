import Combine
import Foundation
import GRDB

public protocol ConnectionRepositoryProtocol: Sendable {
    func connections() async throws -> [Connection]
    func connectionsPublisher() -> AnyPublisher<[Connection], Never>
    func grantsPublisher(for conversationId: String) -> AnyPublisher<[ConnectionGrant], Never>
    func grants(for conversationId: String) async throws -> [ConnectionGrant]
}

public final class ConnectionRepository: ConnectionRepositoryProtocol, Sendable {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func connections() async throws -> [Connection] {
        try await databaseReader.read { db in
            try DBConnection
                .filter(DBConnection.Columns.status == ConnectionStatus.active.rawValue)
                .order(DBConnection.Columns.connectedAt.desc)
                .fetchAll(db)
                .map { $0.toConnection() }
        }
    }

    public func connectionsPublisher() -> AnyPublisher<[Connection], Never> {
        ValueObservation
            .tracking { db in
                try DBConnection
                    .filter(DBConnection.Columns.status == ConnectionStatus.active.rawValue)
                    .order(DBConnection.Columns.connectedAt.desc)
                    .fetchAll(db)
                    .map { $0.toConnection() }
            }
            .publisher(in: databaseReader, scheduling: .immediate)
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }

    public func grants(for conversationId: String) async throws -> [ConnectionGrant] {
        try await databaseReader.read { db in
            try Self.fetchActiveGrants(conversationId: conversationId, db: db)
        }
    }

    public func grantsPublisher(for conversationId: String) -> AnyPublisher<[ConnectionGrant], Never> {
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
    ) throws -> [ConnectionGrant] {
        let conversation = try DBConversation
            .filter(DBConversation.Columns.id == conversationId)
            .fetchOne(db)
        if let expiresAt = conversation?.expiresAt, expiresAt <= Date() {
            return []
        }
        return try DBConnectionGrant
            .filter(DBConnectionGrant.Columns.conversationId == conversationId)
            .fetchAll(db)
            .map { $0.toConnectionGrant() }
    }
}
