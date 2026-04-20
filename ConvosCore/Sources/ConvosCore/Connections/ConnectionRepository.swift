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
            try DBConnectionGrant
                .filter(DBConnectionGrant.Columns.conversationId == conversationId)
                .fetchAll(db)
                .map { $0.toConnectionGrant() }
        }
    }

    public func grantsPublisher(for conversationId: String) -> AnyPublisher<[ConnectionGrant], Never> {
        ValueObservation
            .tracking { db in
                try DBConnectionGrant
                    .filter(DBConnectionGrant.Columns.conversationId == conversationId)
                    .fetchAll(db)
                    .map { $0.toConnectionGrant() }
            }
            .publisher(in: databaseReader, scheduling: .immediate)
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }
}
