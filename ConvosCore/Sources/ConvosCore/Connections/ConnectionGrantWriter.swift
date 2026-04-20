import Foundation
import GRDB
@preconcurrency import XMTPiOS

public protocol ConnectionGrantWriterProtocol: Sendable {
    func grantConnection(_ connectionId: String, to conversationId: String) async throws
    func revokeGrant(connectionId: String, from conversationId: String) async throws
}

final class ConnectionGrantWriter: ConnectionGrantWriterProtocol, @unchecked Sendable {
    private let inboxStateManager: any InboxStateManagerProtocol
    private let databaseWriter: any DatabaseWriter
    private let databaseReader: any DatabaseReader

    init(
        inboxStateManager: any InboxStateManagerProtocol,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader
    ) {
        self.inboxStateManager = inboxStateManager
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
    }

    func grantConnection(_ connectionId: String, to conversationId: String) async throws {
        let connection = try await databaseReader.read { db in
            try DBConnection.fetchOne(db, key: connectionId)
        }
        guard let connection else {
            throw ConnectionGrantError.connectionNotFound(connectionId)
        }

        let grant = DBConnectionGrant(
            connectionId: connectionId,
            conversationId: conversationId,
            serviceId: connection.serviceId,
            grantedAt: Date()
        )

        try await databaseWriter.write { db in
            try grant.save(db)
        }

        try await syncGrantsToMetadata(for: conversationId)
    }

    func revokeGrant(connectionId: String, from conversationId: String) async throws {
        try await databaseWriter.write { db in
            try DBConnectionGrant
                .filter(
                    DBConnectionGrant.Columns.connectionId == connectionId
                        && DBConnectionGrant.Columns.conversationId == conversationId
                )
                .deleteAll(db)
        }

        try await syncGrantsToMetadata(for: conversationId)
    }

    private func syncGrantsToMetadata(for conversationId: String) async throws {
        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
        let senderId = inboxReady.client.inboxId

        guard let conversation = try await inboxReady.client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConnectionGrantError.conversationNotFound(conversationId)
        }

        let grants = try await databaseReader.read { db in
            try DBConnectionGrant
                .filter(DBConnectionGrant.Columns.conversationId == conversationId)
                .fetchAll(db)
        }

        let connections = try await databaseReader.read { db in
            try DBConnection
                .filter(DBConnection.Columns.status == ConnectionStatus.active.rawValue)
                .fetchAll(db)
        }
        let connectionsById = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })

        let iso8601 = ISO8601DateFormatter()
        let entries: [ConnectionGrantEntry] = grants.compactMap { grant in
            guard let conn = connectionsById[grant.connectionId] else { return nil }
            return ConnectionGrantEntry(
                id: "grant_\(grant.connectionId)_\(conversationId)",
                senderId: senderId,
                service: conn.serviceId,
                provider: conn.provider,
                scope: "conversation",
                composioEntityId: conn.composioEntityId,
                composioConnectionId: conn.composioConnectionId,
                grantedAt: iso8601.string(from: grant.grantedAt)
            )
        }

        var payload: ConnectionsMetadataPayload
        if let existingJson = try? group.connectionsJson {
            payload = (try? ConnectionsMetadataPayload.fromJsonString(existingJson)) ?? ConnectionsMetadataPayload()
        } else {
            payload = ConnectionsMetadataPayload()
        }

        payload.setEntries(entries, forSenderId: senderId)

        if payload.isEmpty {
            try await group.clearConnectionsJson()
        } else {
            let json = try payload.toJsonString()
            try await group.updateConnectionsJson(json)
        }
    }
}

enum ConnectionGrantError: LocalizedError {
    case connectionNotFound(String)
    case conversationNotFound(String)

    var errorDescription: String? {
        switch self {
        case .connectionNotFound(let id):
            "Connection not found: \(id)"
        case .conversationNotFound(let id):
            "Conversation not found: \(id)"
        }
    }
}
