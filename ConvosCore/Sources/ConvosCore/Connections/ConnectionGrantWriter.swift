import Foundation
import GRDB
@preconcurrency import XMTPiOS

public protocol ConnectionGrantWriterProtocol: Sendable {
    func grantConnection(_ connectionId: String, to conversationId: String) async throws
    func revokeGrant(connectionId: String, from conversationId: String) async throws
}

final class ConnectionGrantWriter: ConnectionGrantWriterProtocol, @unchecked Sendable {
    private let sessionStateManager: any SessionStateManagerProtocol
    private let databaseWriter: any DatabaseWriter
    private let databaseReader: any DatabaseReader
    private let myProfileWriter: any MyProfileWriterProtocol

    init(
        sessionStateManager: any SessionStateManagerProtocol,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        myProfileWriter: any MyProfileWriterProtocol
    ) {
        self.sessionStateManager = sessionStateManager
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
        guard connection.status == ConnectionStatus.active.rawValue else {
            throw ConnectionGrantError.connectionNotActive(connectionId, status: connection.status)
        }

        let grant = DBConnectionGrant(
            connectionId: connectionId,
            conversationId: conversationId,
            serviceId: connection.serviceId,
            grantedAt: Date()
        )

        // Publish before persisting. If the publish fails we never commit the grant
        // locally, so there is no way for a partially-completed operation to leave a
        // local grant that was never announced to the group.
        let targetGrants = try await projectedGrants(
            for: conversationId,
            addingOrReplacing: grant,
            removing: nil
        )
        try await syncGrantsToMetadata(for: conversationId, desiredGrants: targetGrants)

        try await databaseWriter.write { db in
            try grant.save(db)
        }
    }

    func revokeGrant(connectionId: String, from conversationId: String) async throws {
        let existing = try await databaseReader.read { db in
            try DBConnectionGrant
                .filter(
                    DBConnectionGrant.Columns.connectionId == connectionId
                        && DBConnectionGrant.Columns.conversationId == conversationId
                )
                .fetchOne(db)
        }
        guard existing != nil else {
            // Nothing to revoke, no-op.
            return
        }

        // Publish the reduced grant set first; only delete locally after the agent sees
        // the removal. If publish fails we leave the row intact so the UI/agent stay
        // consistent.
        let targetGrants = try await projectedGrants(
            for: conversationId,
            addingOrReplacing: nil,
            removing: (connectionId: connectionId, conversationId: conversationId)
        )
        try await syncGrantsToMetadata(for: conversationId, desiredGrants: targetGrants)

        try await databaseWriter.write { db in
            try DBConnectionGrant
                .filter(
                    DBConnectionGrant.Columns.connectionId == connectionId
                        && DBConnectionGrant.Columns.conversationId == conversationId
                )
                .deleteAll(db)
        }
    }

    private func projectedGrants(
        for conversationId: String,
        addingOrReplacing addition: DBConnectionGrant?,
        removing removal: (connectionId: String, conversationId: String)?
    ) async throws -> [DBConnectionGrant] {
        let existing = try await databaseReader.read { db in
            try DBConnectionGrant
                .filter(DBConnectionGrant.Columns.conversationId == conversationId)
                .fetchAll(db)
        }

        var projected = existing
        if let removal {
            projected.removeAll {
                $0.connectionId == removal.connectionId
                    && $0.conversationId == removal.conversationId
            }
        }
        if let addition {
            projected.removeAll {
                $0.connectionId == addition.connectionId
                    && $0.conversationId == addition.conversationId
            }
            projected.append(addition)
        }
        return projected
    }

    private func syncGrantsToMetadata(
        for conversationId: String,
        desiredGrants: [DBConnectionGrant]
    ) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        let senderId = inboxReady.client.inboxId

        let connections = try await databaseReader.read { db in
            try DBConnection
                .filter(DBConnection.Columns.status == ConnectionStatus.active.rawValue)
                .fetchAll(db)
        }
        let connectionsById = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })

        let iso8601 = ISO8601DateFormatter()
        let entries: [ConnectionGrantEntry] = desiredGrants.compactMap { grant in
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
            Log.info("[CloudConnections] writing grants for groupId=\(conversationId) senderId=\(senderId) entryCount=\(entries.count) bytes=\(grantsJson.utf8.count)\n\(prettyPrint(grantsJson))")
        } else {
            Log.info("[CloudConnections] clearing grants for groupId=\(conversationId) senderId=\(senderId)")
        }

        // Primary: send a ProfileUpdate message with metadata["connections"]. This is
        // the CLI's (and therefore the agent's) current read path. We use the throwing
        // variant so a send failure propagates to the caller, which then declines to
        // persist the local grant change. We run this before the best-effort appData
        // write so a ProfileUpdate failure can't leave a stale grant in appData.
        try await sendProfileUpdateWithConnections(
            conversationId: conversationId,
            senderId: senderId,
            grantsJson: grantsJson
        )

        // Best-effort: stash on the sender's ConversationProfile in appData (field 5).
        // Forward-compat hedge for any CLI reader that looks at appData — failures are logged only,
        // including failure to locate the group (appData isn't on the critical path).
        do {
            guard let group = try await inboxReady.client.messagingGroup(with: conversationId) else {
                Log.warning("[CloudConnections] appData write skipped (best-effort), conversation not found: \(conversationId)")
                return
            }
            if let grantsJson {
                try await group.updateSenderConnections(grantsJson, senderInboxId: senderId)
            } else {
                try await group.clearSenderConnections(senderInboxId: senderId)
            }
        } catch {
            Log.warning("[CloudConnections] appData write failed (best-effort), continuing: \(error.localizedDescription)")
        }
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

        try await myProfileWriter.updateAndPublish(
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
    case connectionNotActive(String, status: String)
    case conversationNotFound(String)

    var errorDescription: String? {
        switch self {
        case .connectionNotFound(let id):
            "Connection not found: \(id)"
        case let .connectionNotActive(id, status):
            "Connection not active (\(status)): \(id)"
        case .conversationNotFound(let id):
            "Conversation not found: \(id)"
        }
    }
}
