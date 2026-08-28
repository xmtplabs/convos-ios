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
    private let eventWriterProvider: @Sendable () -> (any ConnectionEventWriterProtocol)?
    private let resolverProvider: @Sendable () -> (any CapabilityResolver)?

    public init(
        apiClient: any ConvosAPIClientProtocol,
        oauthProvider: any OAuthSessionProvider,
        databaseWriter: any DatabaseWriter,
        callbackURLScheme: String,
        grantWriterProvider: @escaping @Sendable () -> (any CloudConnectionGrantWriterProtocol)? = { nil },
        eventWriterProvider: @escaping @Sendable () -> (any ConnectionEventWriterProtocol)? = { nil },
        resolverProvider: @escaping @Sendable () -> (any CapabilityResolver)? = { nil }
    ) {
        self.apiClient = apiClient
        self.oauthProvider = oauthProvider
        self.databaseWriter = databaseWriter
        self.callbackURLScheme = callbackURLScheme
        self.grantWriterProvider = grantWriterProvider
        self.eventWriterProvider = eventWriterProvider
        self.resolverProvider = resolverProvider
    }

    public func connect(serviceId: String) async throws -> CloudConnection {
        let redirectUri = "\(callbackURLScheme)://connections/callback"

        let initiation = try await apiClient.initiateCloudConnection(
            serviceId: serviceId,
            redirectUri: redirectUri
        )

        guard let redirectUrlString = initiation.redirectUrl else {
            return try await resolveConnectionWithoutOAuth(serviceId: serviceId, initiation: initiation)
        }

        guard let oauthURL = URL(string: redirectUrlString) else {
            throw CloudConnectionManagerError.invalidOAuthURL
        }

        _ = try await oauthProvider.authenticate(url: oauthURL, callbackURLScheme: callbackURLScheme)

        let completion = try await apiClient.completeCloudConnection(connectionRequestId: initiation.connectionRequestId)
        return try await persistCompletedConnection(completion, fallbackServiceId: serviceId)
    }

    /// Resolves a connect whose `/initiate` came back with a null redirectUrl,
    /// meaning no OAuth step. The backend's authoritative signal is
    /// `alreadyConnected`: when true, the account already authorized this
    /// service, so the connection is finalized without a browser -- returning a
    /// cached live local connection when present, otherwise completing the
    /// request to materialize it. When the field is false or absent (backends
    /// predating it), a cached live local connection is still accepted as a
    /// transitional fallback; with neither signal the service is not connected
    /// here, so a typed error surfaces instead of the sheet hanging.
    private func resolveConnectionWithoutOAuth(
        serviceId: String,
        initiation: CloudConnectionsAPI.InitiateResponse
    ) async throws -> CloudConnection {
        if initiation.alreadyConnected {
            if let existing = try await existingActiveConnection(serviceId: serviceId) {
                return existing
            }
            let completion = try await apiClient.completeCloudConnection(connectionRequestId: initiation.connectionRequestId)
            return try await persistCompletedConnection(completion, fallbackServiceId: serviceId)
        }
        if let existing = try await existingActiveConnection(serviceId: serviceId) {
            return existing
        }
        throw CloudConnectionManagerError.oauthUrlUnavailable
    }

    /// Builds and persists a `CloudConnection` from a completion response.
    /// `fallbackServiceId` is used only when the backend echoes an empty
    /// service id.
    private func persistCompletedConnection(
        _ completion: CloudConnectionsAPI.CompleteResponse,
        fallbackServiceId: String
    ) async throws -> CloudConnection {
        // Backend echoes Composio's slug. Fall back to the original arg only if
        // the response somehow comes back with no service id at all.
        let finalServiceId = completion.serviceId.isEmpty ? fallbackServiceId : completion.serviceId

        // Only an active completion is a usable connection. A non-active status
        // (INITIALIZING/EXPIRED/FAILED/unknown maps to .expired/.revoked) means
        // there is no live credential behind it; persisting and returning it
        // would read as connected while the repository still treats the service
        // as disconnected -- a phantom-linked false success. Fail closed so the
        // connect surfaces an actionable error instead.
        let status = CloudConnectionStatus.from(composioStatus: completion.status)
        guard status == .active else {
            throw CloudConnectionManagerError.connectionNotActive
        }

        let connection = CloudConnection(
            id: completion.connectionId,
            serviceId: finalServiceId,
            serviceName: displayName(for: completion.serviceName, fallbackFrom: finalServiceId),
            provider: .composio,
            composioEntityId: completion.composioEntityId,
            composioConnectionId: completion.composioConnectionId,
            status: status,
            connectedAt: Date()
        )

        let dbConnection = DBCloudConnection(from: connection)
        try await databaseWriter.write { db in
            try dbConnection.save(db)
        }

        return connection
    }

    /// The most recently connected active local connection for `serviceId`, or
    /// nil when none exists. Reads the same store that feeds a provider's
    /// `linked` state and grant confirmation, so a null-redirect initiate can
    /// resolve to success without a further backend round-trip.
    private func existingActiveConnection(serviceId: String) async throws -> CloudConnection? {
        try await databaseWriter.read { db in
            try DBCloudConnection
                .filter(DBCloudConnection.Columns.serviceId == serviceId)
                .filter(DBCloudConnection.Columns.status == CloudConnectionStatus.active.rawValue)
                .order(DBCloudConnection.Columns.connectedAt.desc)
                .fetchOne(db)?
                .toConnection()
        }
    }

    public func disconnect(connectionId: String) async throws {
        try await apiClient.revokeCloudConnection(connectionId: connectionId)

        // Read the connection's serviceId before any local mutation so we can
        // derive the providerId for ConnectionEvent.revoked and the resolver
        // cleanup even if the row is gone by the time we need it.
        let serviceId = try await databaseWriter.read { db in
            try DBCloudConnection.fetchOne(db, key: connectionId)?.serviceId
        }

        // Collect every (conversation, agent) grant row that currently references
        // this connection so we can republish per-conversation metadata after the
        // local rows are gone. Without this, the ProfileUpdate metadata previously
        // published to XMTP groups still carries the revoked grants and the agent
        // would keep using them. With per-agent grants, the same conversation can
        // have several rows (one per agent), and each must be revoked individually
        // so the metadata payload's per-agent entries all go away.
        let affectedGrants: [DBCloudConnectionGrant] = try await databaseWriter.read { db in
            try DBCloudConnectionGrant
                .filter(DBCloudConnectionGrant.Columns.connectionId == connectionId)
                .fetchAll(db)
        }

        await republishRevokedGrants(affectedGrants, context: "after disconnect")

        await postRevocationSideEffects(
            connectionId: connectionId,
            serviceId: serviceId,
            grants: affectedGrants
        )

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

        // Before deleting orphaned connections, capture the (id, serviceId)
        // pairs and the grants that referenced them. We need both to (a)
        // republish ProfileUpdate metadata so XMTP group state matches the
        // server-side revoke, and (b) post connection_event.revoked +
        // clear capability resolutions for the same provider — symmetric
        // with disconnect(). serviceId must be read before the FK cascade
        // wipes the row.
        let orphanedConnections: [(id: String, serviceId: String)] = try await databaseWriter.read { db in
            try DBCloudConnection
                .fetchAll(db)
                .filter { !serverIds.contains($0.id) }
                .map { ($0.id, $0.serviceId) }
        }
        let orphanedConnectionIds = Set(orphanedConnections.map(\.id))
        let orphanedGrants: [DBCloudConnectionGrant] = orphanedConnectionIds.isEmpty
            ? []
            : try await databaseWriter.read { db in
                try DBCloudConnectionGrant
                    .filter(orphanedConnectionIds.contains(DBCloudConnectionGrant.Columns.connectionId))
                    .fetchAll(db)
            }

        await republishRevokedGrants(orphanedGrants, context: "during refresh")

        for orphan in orphanedConnections {
            await postRevocationSideEffects(
                connectionId: orphan.id,
                serviceId: orphan.serviceId,
                grants: orphanedGrants.filter { $0.connectionId == orphan.id }
            )
        }

        let connections: [CloudConnection] = try await databaseWriter.write { [self] db in
            let existingById = try Dictionary(
                uniqueKeysWithValues: DBCloudConnection.fetchAll(db).map { ($0.id, $0) }
            )

            let refreshed: [CloudConnection] = responses.map { response in
                let existingConnectedAt = existingById[response.connectionId]?.connectedAt
                return CloudConnection(
                    id: response.connectionId,
                    serviceId: response.serviceId,
                    serviceName: self.displayName(for: response.serviceName, fallbackFrom: response.serviceId),
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

    /// Posts `connection_event.revoked` to every affected conversation and
    /// Walks `grants`, calling `revokeGrant` on the injected writer for each so the
    /// per-conversation ProfileUpdate metadata reflects the deletion. Best-effort:
    /// per-grant failures are logged and don't propagate. `context` is a short noun
    /// phrase ("after disconnect", "during refresh") used for log-message disambiguation
    /// when both call sites land in the same log file.
    private func republishRevokedGrants(_ grants: [DBCloudConnectionGrant], context: String) async {
        guard !grants.isEmpty else { return }
        guard let grantWriter = grantWriterProvider() else {
            let conversationCount = Set(grants.map(\.conversationId)).count
            Log.warning(
                "[CloudConnections] \(context) had no grant writer injected; metadata for " +
                "\(conversationCount) conversation(s) will remain stale until the next grant/revoke"
            )
            // The writer normally revokes the backend consent records as part of
            // revokeGrant; with no writer injected that path can't run, so revoke
            // them directly to keep the backend grant store in sync.
            await revokeBackendGrants(grants, context: context)
            return
        }
        for grant in grants {
            do {
                try await grantWriter.revokeGrant(
                    connectionId: grant.connectionId,
                    from: grant.conversationId,
                    grantedToInboxId: grant.grantedToInboxId
                )
            } catch {
                Log.warning(
                    "[CloudConnections] failed to republish grants \(context) " +
                    "(connectionId=\(grant.connectionId), conversationId=\(grant.conversationId), " +
                    "grantedToInboxId=\(grant.grantedToInboxId)): \(error.localizedDescription)"
                )
                // The writer only revokes the backend record after a successful
                // metadata publish, so a throw here means the backend grant
                // survived. Revoke it directly; the row is about to be cascade-
                // deleted with the connection, taking the stored id with it.
                await revokeBackendGrants([grant], context: context)
            }
        }
    }

    /// Directly revokes the backend consent records for grants whose normal
    /// writer-mediated revocation didn't run. Uses the natural-key revoke so it
    /// works even for rows that never stored a backendGrantId (push failed or
    /// hadn't happened). Best-effort: failures are logged and never propagate;
    /// the connection-level backend revoke independently cuts off agent
    /// execution.
    private func revokeBackendGrants(_ grants: [DBCloudConnectionGrant], context: String) async {
        for grant in grants {
            do {
                try await apiClient.revokeConnectionGrantByNaturalKey(
                    toolkit: grant.serviceId,
                    conversationId: grant.conversationId,
                    granteeInboxId: grant.grantedToInboxId
                )
            } catch {
                Log.warning(
                    "[CloudConnections] failed to revoke backend grant \(context) " +
                    "(toolkit=\(grant.serviceId), connectionId=\(grant.connectionId), " +
                    "conversationId=\(grant.conversationId), grantedToInboxId=\(grant.grantedToInboxId)): " +
                    error.localizedDescription
                )
            }
        }
    }

    /// clears the provider from every CapabilityResolution. Best-effort —
    /// failures are logged but never propagate, matching the existing grant-
    /// republish behavior. `serviceId == nil` is the "row already deleted"
    /// race; we skip cleanup because there's no providerId to derive.
    private func postRevocationSideEffects(
        connectionId: String,
        serviceId: String?,
        grants: [DBCloudConnectionGrant]
    ) async {
        guard let serviceId else { return }
        let providerId = ProviderID(rawValue: "composio.\(serviceId)")
        if let eventWriter = eventWriterProvider() {
            // One revoked event per (conversation, agent) grant rather than one
            // per conversation: the agent inbox id is what lets the event route
            // to that agent's DM instead of the shared group transcript.
            var seenTargets: Set<String> = []
            for grant in grants {
                let target = "\(grant.conversationId)|\(grant.grantedToInboxId)"
                guard seenTargets.insert(target).inserted else { continue }
                do {
                    try await eventWriter.sendRevoked(
                        providerId: providerId.rawValue,
                        capability: nil,
                        grantedToInboxId: grant.grantedToInboxId,
                        in: grant.conversationId
                    )
                } catch {
                    Log.warning("Failed to send connection_event revoked (connectionId=\(connectionId), conversationId=\(grant.conversationId)): \(error.localizedDescription)")
                }
            }
        } else if !grants.isEmpty {
            Log.warning(
                "Revocation had no event writer injected; connection_event.revoked " +
                "will not be posted for \(grants.count) grant(s) (connectionId=\(connectionId))"
            )
        }
        if let resolver = resolverProvider() {
            do {
                try await resolver.removeProviderFromAllResolutions(providerId)
            } catch {
                Log.warning("Failed to clear capability resolutions for \(providerId.rawValue): \(error.localizedDescription)")
            }
        } else {
            Log.warning(
                "Revocation had no capability resolver injected; resolutions for " +
                "\(providerId.rawValue) will remain stale (connectionId=\(connectionId))"
            )
        }
    }
}

enum CloudConnectionManagerError: LocalizedError {
    case invalidOAuthURL
    case oauthUrlUnavailable
    case connectionNotActive

    var errorDescription: String? {
        switch self {
        case .invalidOAuthURL:
            "Invalid OAuth URL received from server"
        case .oauthUrlUnavailable:
            "Couldn't start sign-in for this service. Please try again."
        case .connectionNotActive:
            "This service isn't finished connecting yet. Please try again."
        }
    }
}

extension CloudConnectionStatus {
    static func from(composioStatus raw: String) -> CloudConnectionStatus {
        switch raw.uppercased() {
        case "ACTIVE":
            return .active
        case "INITIATED", "INITIALIZING":
            // OAuth was started but never finished. Treating these as active
            // minted phantom-linked providers: the approval sheet trusted the
            // local snapshot and skipped its OAuth leg, then the grant sat on
            // a connection with no credential behind it. Not usable until the
            // flow completes, so surface the (re)connect prompt.
            return .expired
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
