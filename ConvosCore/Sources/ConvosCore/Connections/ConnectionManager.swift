import Foundation
import GRDB

public protocol ConnectionManagerProtocol: Sendable {
    func connect(serviceId: String) async throws -> Connection
    func disconnect(connectionId: String) async throws
    func refreshConnections() async throws -> [Connection]
}

public final class ConnectionManager: ConnectionManagerProtocol, @unchecked Sendable {
    private let apiClient: any ConvosAPIClientProtocol
    private let oauthProvider: any OAuthSessionProvider
    private let databaseWriter: any DatabaseWriter
    private let callbackURLScheme: String
    private let grantWriterProvider: @Sendable () -> (any ConnectionGrantWriterProtocol)?

    public init(
        apiClient: any ConvosAPIClientProtocol,
        oauthProvider: any OAuthSessionProvider,
        databaseWriter: any DatabaseWriter,
        callbackURLScheme: String,
        grantWriterProvider: @escaping @Sendable () -> (any ConnectionGrantWriterProtocol)? = { nil }
    ) {
        self.apiClient = apiClient
        self.oauthProvider = oauthProvider
        self.databaseWriter = databaseWriter
        self.callbackURLScheme = callbackURLScheme
        self.grantWriterProvider = grantWriterProvider
    }

    public func connect(serviceId canonicalServiceId: String) async throws -> Connection {
        let redirectUri = "\(callbackURLScheme)://connections/callback"
        let toolkitSlug = ConnectionServiceNaming.composioToolkitSlug(for: canonicalServiceId)

        let initiation = try await apiClient.initiateConnection(
            serviceId: toolkitSlug,
            redirectUri: redirectUri
        )

        guard let oauthURL = URL(string: initiation.redirectUrl) else {
            throw ConnectionManagerError.invalidOAuthURL
        }

        _ = try await oauthProvider.authenticate(url: oauthURL, callbackURLScheme: callbackURLScheme)

        let completion = try await apiClient.completeConnection(connectionRequestId: initiation.connectionRequestId)

        // Backend echoes whatever slug Composio returns; normalise back to canonical.
        let canonicalFromResponse = ConnectionServiceNaming.canonicalService(fromComposioSlug: completion.serviceId)
        let finalCanonical = canonicalFromResponse == completion.serviceId ? canonicalServiceId : canonicalFromResponse

        let connection = Connection(
            id: completion.connectionId,
            serviceId: finalCanonical,
            serviceName: displayName(for: completion.serviceName, fallbackFrom: finalCanonical),
            provider: .composio,
            composioEntityId: completion.composioEntityId,
            composioConnectionId: completion.composioConnectionId,
            status: ConnectionStatus.from(composioStatus: completion.status),
            connectedAt: Date()
        )

        let dbConnection = DBConnection(from: connection)
        try await databaseWriter.write { db in
            try dbConnection.save(db)
        }

        return connection
    }

    public func disconnect(connectionId: String) async throws {
        try await apiClient.revokeConnection(connectionId: connectionId)

        // Collect conversations that currently reference this connection so we
        // can republish per-conversation metadata after the local rows are gone.
        // Without this, the ProfileUpdate metadata previously published to XMTP
        // groups still carries the revoked grants and the agent would keep
        // using them.
        let affectedConversationIds = try await databaseWriter.read { db in
            try DBConnectionGrant
                .filter(DBConnectionGrant.Columns.connectionId == connectionId)
                .fetchAll(db)
                .map { $0.conversationId }
        }
        let uniqueConversationIds = Array(Set(affectedConversationIds))

        // revokeGrant deletes the row and republishes metadata for that
        // conversation. We go through the public writer interface so the two
        // paths stay in sync. A republish failure here is logged but doesn't
        // block the subsequent DBConnection delete — the ON DELETE CASCADE
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

        try await databaseWriter.write { db in
            _ = try DBConnection.deleteOne(db, key: connectionId)
        }
    }

    public func refreshConnections() async throws -> [Connection] {
        let responses = try await apiClient.listConnections()

        // Delta update rather than deleteAll-then-reinsert: DBConnectionGrant
        // rows have ON DELETE CASCADE on DBConnection.id, so deleting every
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
        let connections: [Connection] = try await databaseWriter.write { [self] db in
            let existingById = try Dictionary(
                uniqueKeysWithValues: DBConnection.fetchAll(db).map { ($0.id, $0) }
            )

            let refreshed: [Connection] = responses.map { response in
                let canonical = ConnectionServiceNaming.canonicalService(fromComposioSlug: response.serviceId)
                let existingConnectedAt = existingById[response.connectionId]?.connectedAt
                return Connection(
                    id: response.connectionId,
                    serviceId: canonical,
                    serviceName: self.displayName(for: response.serviceName, fallbackFrom: canonical),
                    provider: .composio,
                    composioEntityId: response.composioEntityId,
                    composioConnectionId: response.composioConnectionId,
                    status: ConnectionStatus.from(composioStatus: response.status),
                    connectedAt: existingConnectedAt ?? Date()
                )
            }

            for connection in refreshed {
                try DBConnection(from: connection).save(db)
            }

            let idsToDelete = Set(existingById.keys).subtracting(serverIds)
            if !idsToDelete.isEmpty {
                try DBConnection
                    .filter(idsToDelete.contains(DBConnection.Columns.id))
                    .deleteAll(db)
            }

            return refreshed
        }

        return connections
    }

    private func displayName(for serviceName: String, fallbackFrom serviceId: String) -> String {
        ConnectionServiceNaming.displayName(for: serviceName, fallbackFrom: serviceId)
    }
}

enum ConnectionManagerError: LocalizedError {
    case invalidOAuthURL

    var errorDescription: String? {
        switch self {
        case .invalidOAuthURL:
            "Invalid OAuth URL received from server"
        }
    }
}

extension ConnectionStatus {
    static func from(composioStatus raw: String) -> ConnectionStatus {
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
