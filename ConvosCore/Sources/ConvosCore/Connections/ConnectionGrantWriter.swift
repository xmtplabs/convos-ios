import ConvosProfiles
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
    private let myProfileWriter: any MyProfileWriterProtocol

    init(
        inboxStateManager: any InboxStateManagerProtocol,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        myProfileWriter: any MyProfileWriterProtocol
    ) {
        self.inboxStateManager = inboxStateManager
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
        self.myProfileWriter = myProfileWriter
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

        do {
            try await syncGrantsToMetadata(for: conversationId)
        } catch {
            Log.warning("[Connections] metadata write failed, rolling back DB grant (connectionId=\(connectionId), conversationId=\(conversationId)): \(error.localizedDescription)")
            try? await databaseWriter.write { db in
                try DBConnectionGrant
                    .filter(
                        DBConnectionGrant.Columns.connectionId == connectionId
                            && DBConnectionGrant.Columns.conversationId == conversationId
                    )
                    .deleteAll(db)
            }
            throw error
        }
    }

    func revokeGrant(connectionId: String, from conversationId: String) async throws {
        let removedGrant = try await databaseReader.read { db in
            try DBConnectionGrant
                .filter(
                    DBConnectionGrant.Columns.connectionId == connectionId
                        && DBConnectionGrant.Columns.conversationId == conversationId
                )
                .fetchOne(db)
        }

        try await databaseWriter.write { db in
            try DBConnectionGrant
                .filter(
                    DBConnectionGrant.Columns.connectionId == connectionId
                        && DBConnectionGrant.Columns.conversationId == conversationId
                )
                .deleteAll(db)
        }

        do {
            try await syncGrantsToMetadata(for: conversationId)
        } catch {
            Log.warning("[Connections] metadata write failed, restoring DB grant (connectionId=\(connectionId), conversationId=\(conversationId)): \(error.localizedDescription)")
            if let removedGrant {
                try? await databaseWriter.write { db in
                    try removedGrant.save(db)
                }
            }
            throw error
        }
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
            // Guard against DB rows written before canonical-naming landed: if the
            // stored serviceId is a Composio toolkit slug, translate back to canonical.
            let canonicalService = ConnectionServiceNaming.canonicalService(fromComposioSlug: conn.serviceId)
            return ConnectionGrantEntry(
                id: "grant_\(grant.connectionId)_\(conversationId)",
                senderId: senderId,
                service: canonicalService,
                provider: conn.provider,
                scope: "conversation",
                composioEntityId: conn.composioEntityId,
                composioConnectionId: conn.composioConnectionId,
                grantedAt: iso8601.string(from: grant.grantedAt)
            )
        }

        let payload = ConnectionsMetadataPayload(grants: entries)
        let grantsJson = payload.isEmpty ? nil : try payload.toJsonString()

        if let grantsJson {
            Log.info("[Connections] writing grants for groupId=\(conversationId) senderId=\(senderId) entryCount=\(entries.count) bytes=\(grantsJson.utf8.count)\n\(prettyPrint(grantsJson))")
        } else {
            Log.info("[Connections] clearing grants for groupId=\(conversationId) senderId=\(senderId)")
        }

        // Best-effort: stash on the sender's ConversationProfile in appData (field 5).
        // Forward-compat hedge for any CLI reader that looks at appData — failures are logged only.
        do {
            if let grantsJson {
                try await group.updateSenderConnections(grantsJson, senderInboxId: senderId)
            } else {
                try await group.clearSenderConnections(senderInboxId: senderId)
            }
        } catch {
            Log.warning("[Connections] appData write failed (best-effort), continuing: \(error.localizedDescription)")
        }

        // Primary: send a ProfileUpdate message with metadata["connections"]. This is
        // the CLI's (and therefore the agent's) current read path — throws on failure
        // so the caller rolls the DB grant back.
        try await sendProfileUpdateWithConnections(
            conversationId: conversationId,
            senderId: senderId,
            grantsJson: grantsJson
        )
    }

    private func sendProfileUpdateWithConnections(
        conversationId: String,
        senderId: String,
        grantsJson: String?
    ) async throws {
        let existingMetadata = try await databaseReader.read { db in
            try DBMemberProfile.fetchOne(
                db,
                conversationId: conversationId,
                inboxId: senderId
            )?.metadata
        }
        var merged: ProfileMetadata = existingMetadata ?? [:]
        if let grantsJson {
            merged[Constant.connectionsKey] = .string(grantsJson)
        } else {
            merged.removeValue(forKey: Constant.connectionsKey)
        }

        try await myProfileWriter.update(
            metadata: merged.isEmpty ? nil : merged,
            conversationId: conversationId
        )
    }

    private func prettyPrint(_ json: String) -> String {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: pretty, encoding: .utf8) else {
            return json
        }
        return string
    }

    private enum Constant {
        static let connectionsKey: String = "connections"
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
