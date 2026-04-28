import Foundation
import GRDB

public protocol CloudConnectionManagerProtocol: Sendable {
    func connect(serviceId: String) async throws -> CloudConnection
    func disconnect(connectionId: String) async throws
    func refreshConnections() async throws -> [CloudConnection]
}

public final class CloudConnectionManager: CloudConnectionManagerProtocol, @unchecked Sendable {
    private let apiClient: any ConvosAPIClientProtocol
    private let oauthProvider: any OAuthSessionProvider
    private let databaseWriter: any DatabaseWriter
    private let callbackURLScheme: String
    private let grantWriterProvider: @Sendable () -> (any CloudConnectionGrantWriterProtocol)?

    public init(
        apiClient: any ConvosAPIClientProtocol,
        oauthProvider: any OAuthSessionProvider,
        databaseWriter: any DatabaseWriter,
        callbackURLScheme: String,
        grantWriterProvider: @escaping @Sendable () -> (any CloudConnectionGrantWriterProtocol)? = { nil }
    ) {
        self.apiClient = apiClient
        self.oauthProvider = oauthProvider
        self.databaseWriter = databaseWriter
        self.callbackURLScheme = callbackURLScheme
        self.grantWriterProvider = grantWriterProvider
    }

    public func connect(serviceId canonicalServiceId: String) async throws -> CloudConnection {
        let redirectUri = "\(callbackURLScheme)://connections/callback"
        let toolkitSlug = CloudConnectionServiceNaming.composioToolkitSlug(for: canonicalServiceId)

        let initiation = try await apiClient.initiateCloudConnection(
            serviceId: toolkitSlug,
            redirectUri: redirectUri
        )

        guard let oauthURL = URL(string: initiation.redirectUrl) else {
            throw CloudConnectionManagerError.invalidOAuthURL
        }

        _ = try await oauthProvider.authenticate(url: oauthURL, callbackURLScheme: callbackURLScheme)

        let completion = try await apiClient.completeCloudConnection(connectionRequestId: initiation.connectionRequestId)

        // Backend echoes whatever slug Composio returns; normalise back to canonical.
        let canonicalFromResponse = CloudConnectionServiceNaming.canonicalService(fromComposioSlug: completion.serviceId)
        let finalCanonical = canonicalFromResponse == completion.serviceId ? canonicalServiceId : canonicalFromResponse

        let connection = CloudConnection(
            id: completion.connectionId,
            serviceId: finalCanonical,
            serviceName: displayName(for: completion.serviceName, fallbackFrom: finalCanonical),
            provider: .composio,
            composioEntityId: completion.composioEntityId,
            composioConnectionId: completion.composioConnectionId,
            status: CloudConnectionStatus.from(composioStatus: completion.status),
            connectedAt: Date()
        )

        let dbConnection = DBCloudConnection(from: connection)
        try await databaseWriter.write { db in
            try dbConnection.save(db)
        }

        return connection
    }

    public func disconnect(connectionId: String) async throws {
        try await apiClient.revokeCloudConnection(connectionId: connectionId)

        // Collect conversations that currently reference this connection so we
        // can republish per-conversation metadata after the local rows are gone.
        // Without this, the ProfileUpdate metadata previously published to XMTP
        // groups still carries the revoked grants and the agent would keep
        // using them.
        let affectedConversationIds = try await databaseWriter.read { db in
            try DBCloudConnectionGrant
                .filter(DBCloudConnectionGrant.Columns.connectionId == connectionId)
                .fetchAll(db)
                .map { $0.conversationId }
        }
        let uniqueConversationIds = Array(Set(affectedConversationIds))

        // revokeGrant deletes the row and republishes metadata for that
        // conversation. We go through the public writer interface so the two
        // paths stay in sync. A republish failure here is logged but doesn't
        // block the subsequent DBCloudConnection delete — the ON DELETE CASCADE
        // guarantees any grant revokeGrant restored on failure still gets
        // removed locally. The stale metadata on XMTP is the best we can do
        // if the sync is down at wipe time.
        if let grantWriter = grantWriterProvider() {
            for conversationId in uniqueConversationIds {
                do {
                    try await grantWriter.revokeGrant(
                        connectionId: connectionId,
                        from: conversationId
                    )
                } catch {
                    Log.warning("[CloudConnections] failed to republish grants after disconnect (connectionId=\(connectionId), conversationId=\(conversationId)): \(error.localizedDescription)")
                }
            }
        } else if !uniqueConversationIds.isEmpty {
            let conversationCount = uniqueConversationIds.count
            Log.warning(
                "[CloudConnections] disconnect had no grant writer injected; metadata for " +
                "\(conversationCount) conversation(s) will remain stale until the next grant/revoke " +
                "on the affected conversations"
            )
        }

        // Idempotent: GRDB's deleteOne returns false when the row is already
        // gone (it doesn't throw). Two concurrent disconnects of the same
        // connectionId are therefore safe — both end with the same DB state.
        // Log the second one so concurrent disconnects are observable.
        try await databaseWriter.write { db in
            let deleted = try DBCloudConnection.deleteOne(db, key: connectionId)
            if !deleted {
                Log.warning(
                    "[CloudConnections] disconnect found connection \(connectionId) already deleted; another disconnect path likely raced with this one"
                )
            }
        }
    }

    public func refreshConnections() async throws -> [CloudConnection] {
        let responses = try await apiClient.listCloudConnections()

        // Delta update rather than deleteAll-then-reinsert: DBCloudConnectionGrant
        // rows have ON DELETE CASCADE on DBCloudConnection.id, so deleting every
        // connection (even momentarily within the same transaction) wipes
        // every grant on the device. Since refresh() fires every time the
        // Connections settings screen appears, that path would destroy every
        // grant on settings entry.
        //
        // The server response doesn't include the original connection
        // timestamp, so we must preserve the existing `connectedAt` for rows
        // that already exist locally; otherwise every refresh resets the
        // historical "connected on" date to now. Only brand-new rows get
        // `Date()` as their creation timestamp.
        let serverIds = Set(responses.map { $0.connectionId })

        // Before deleting orphaned connections, republish ProfileUpdate
        // metadata for every conversation that referenced them — same
        // rationale as disconnect(). Without this, the FK cascade deletes
        // local DBCloudConnectionGrant rows but the XMTP group metadata still
        // carries the revoked grants and the assistant keeps using them.
        let orphanedGrants = try await databaseWriter.read { db in
            let existingIds = Set(try DBCloudConnection.fetchAll(db).map { $0.id })
            let toDelete = existingIds.subtracting(serverIds)
            guard !toDelete.isEmpty else { return [DBCloudConnectionGrant]() }
            return try DBCloudConnectionGrant
                .filter(toDelete.contains(DBCloudConnectionGrant.Columns.connectionId))
                .fetchAll(db)
        }

        if !orphanedGrants.isEmpty {
            if let grantWriter = grantWriterProvider() {
                for grant in orphanedGrants {
                    do {
                        try await grantWriter.revokeGrant(
                            connectionId: grant.connectionId,
                            from: grant.conversationId
                        )
                    } catch {
                        Log.warning(
                            "[CloudConnections] failed to republish grants during refresh (connectionId=\(grant.connectionId), conversationId=\(grant.conversationId)): \(error.localizedDescription)"
                        )
                    }
                }
            } else {
                Log.warning(
                    "[CloudConnections] refresh had \(orphanedGrants.count) orphaned grant(s) but no grant writer was " +
                    "injected; metadata for the affected conversation(s) will remain stale until the next grant/revoke"
                )
            }
        }

        let connections: [CloudConnection] = try await databaseWriter.write { [self] db in
            let existingById = try Dictionary(
                uniqueKeysWithValues: DBCloudConnection.fetchAll(db).map { ($0.id, $0) }
            )

            let refreshed: [CloudConnection] = responses.map { response in
                let canonical = CloudConnectionServiceNaming.canonicalService(fromComposioSlug: response.serviceId)
                let existingConnectedAt = existingById[response.connectionId]?.connectedAt
                return CloudConnection(
                    id: response.connectionId,
                    serviceId: canonical,
                    serviceName: self.displayName(for: response.serviceName, fallbackFrom: canonical),
                    provider: .composio,
                    composioEntityId: response.composioEntityId,
                    composioConnectionId: response.composioConnectionId,
                    status: CloudConnectionStatus.from(composioStatus: response.status),
                    connectedAt: existingConnectedAt ?? Date()
                )
            }

            for connection in refreshed {
                try DBCloudConnection(from: connection).save(db)
            }

            let idsToDelete = Set(existingById.keys).subtracting(serverIds)
            if !idsToDelete.isEmpty {
                try DBCloudConnection
                    .filter(idsToDelete.contains(DBCloudConnection.Columns.id))
                    .deleteAll(db)
            }

            return refreshed
        }

        return connections
    }

    private func displayName(for serviceName: String, fallbackFrom serviceId: String) -> String {
        CloudConnectionServiceNaming.displayName(for: serviceName, fallbackFrom: serviceId)
    }
}

enum CloudConnectionManagerError: LocalizedError {
    case invalidOAuthURL

    var errorDescription: String? {
        switch self {
        case .invalidOAuthURL:
            "Invalid OAuth URL received from server"
        }
    }
}

extension CloudConnectionStatus {
    static func from(composioStatus raw: String) -> CloudConnectionStatus {
        switch raw.uppercased() {
        case "ACTIVE", "INITIATED", "INITIALIZING":
            return .active
        case "EXPIRED":
            return .expired
        case "FAILED", "INACTIVE":
            return .revoked
        default:
            // Unknown Composio states (e.g. a future "BLOCKED") shouldn't be treated
            // as usable. Mark as expired so the UI surfaces a reconnect prompt.
            return .expired
        }
    }
}
