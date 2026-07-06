import Foundation
import GRDB
@preconcurrency import XMTPiOS

public protocol CloudConnectionGrantWriterProtocol: Sendable {
    /// `bundleIds` is the picker's bundle selection for the connection's
    /// service (catalog ids like "calendar.events"). Pass nil when no picker
    /// was involved (full-service consent paths); the writer then grants
    /// every bundle the catalog lists for the service.
    func grantConnection(
        _ connectionId: String,
        to conversationId: String,
        grantedToInboxId: String,
        bundleIds: [String]?
    ) async throws
    func revokeGrant(
        connectionId: String,
        from conversationId: String,
        grantedToInboxId: String
    ) async throws
}

public extension CloudConnectionGrantWriterProtocol {
    /// Full-service consent convenience: no explicit bundle selection.
    func grantConnection(
        _ connectionId: String,
        to conversationId: String,
        grantedToInboxId: String
    ) async throws {
        try await grantConnection(
            connectionId,
            to: conversationId,
            grantedToInboxId: grantedToInboxId,
            bundleIds: nil
        )
    }
}

final class CloudConnectionGrantWriter: CloudConnectionGrantWriterProtocol, @unchecked Sendable {
    private let sessionStateManager: any SessionStateManagerProtocol
    private let databaseWriter: any DatabaseWriter
    private let databaseReader: any DatabaseReader
    private let profileMetadataWriter: any ProfileMetadataWriterProtocol
    private let servicesStore: any ConnectionServicesStoreProtocol

    init(
        sessionStateManager: any SessionStateManagerProtocol,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        profileMetadataWriter: any ProfileMetadataWriterProtocol,
        servicesStore: any ConnectionServicesStoreProtocol
    ) {
        self.sessionStateManager = sessionStateManager
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
        self.profileMetadataWriter = profileMetadataWriter
        self.servicesStore = servicesStore
    }

    func grantConnection(
        _ connectionId: String,
        to conversationId: String,
        grantedToInboxId: String,
        bundleIds: [String]?
    ) async throws {
        guard !grantedToInboxId.isEmpty else {
            throw CloudConnectionGrantError.missingGrantedToInboxId
        }
        let connection = try await databaseReader.read { db in
            try DBCloudConnection.fetchOne(db, key: connectionId)
        }
        guard let connection else {
            throw CloudConnectionGrantError.connectionNotFound(connectionId)
        }
        guard connection.status == CloudConnectionStatus.active.rawValue else {
            throw CloudConnectionGrantError.connectionNotActive(connectionId, status: connection.status)
        }

        let grant = DBCloudConnectionGrant(
            connectionId: connectionId,
            conversationId: conversationId,
            serviceId: connection.serviceId,
            grantedToInboxId: grantedToInboxId,
            grantedAt: Date(),
            bundleIds: bundleIds
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

        await pushGrantToBackend(grant, connection: connection)
    }

    func revokeGrant(
        connectionId: String,
        from conversationId: String,
        grantedToInboxId: String
    ) async throws {
        guard !grantedToInboxId.isEmpty else {
            throw CloudConnectionGrantError.missingGrantedToInboxId
        }
        let existing = try await databaseReader.read { db in
            try DBCloudConnectionGrant
                .filter(
                    DBCloudConnectionGrant.Columns.connectionId == connectionId
                        && DBCloudConnectionGrant.Columns.conversationId == conversationId
                        && DBCloudConnectionGrant.Columns.grantedToInboxId == grantedToInboxId
                )
                .fetchOne(db)
        }
        guard let existing else {
            // Nothing to revoke, no-op.
            return
        }

        // Publish the reduced grant set first; only delete locally after the agent sees
        // the removal. If publish fails we leave the row intact so the UI/agent stay
        // consistent.
        let targetGrants = try await projectedGrants(
            for: conversationId,
            addingOrReplacing: nil,
            removing: GrantKey(connectionId: connectionId, conversationId: conversationId, grantedToInboxId: grantedToInboxId)
        )
        try await syncGrantsToMetadata(for: conversationId, desiredGrants: targetGrants)

        try await databaseWriter.write { db in
            try DBCloudConnectionGrant
                .filter(
                    DBCloudConnectionGrant.Columns.connectionId == connectionId
                        && DBCloudConnectionGrant.Columns.conversationId == conversationId
                        && DBCloudConnectionGrant.Columns.grantedToInboxId == grantedToInboxId
                )
                .deleteAll(db)
        }

        await revokeBackendGrant(for: existing)
    }

    /// Pushes one per-agent consent record to the backend grant store and
    /// remembers the returned id on the local row so revocation can target it.
    /// Grants are bundle-scoped against the services catalog (see
    /// `resolveBundleScope`); a 400 `unknown_bundle` rejection means our
    /// catalog cache is stale, so the push refetches it, drops ids the fresh
    /// catalog no longer knows, and retries exactly once. Otherwise
    /// best-effort with no retry: on failure the local grant stands, but the
    /// backend will deny the agent's tool execution (403) until the user
    /// re-grants, so the failure is logged at error level.
    private func pushGrantToBackend(_ grant: DBCloudConnectionGrant, connection: DBCloudConnection) async {
        do {
            let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
            guard let scope = await resolveBundleScope(
                toolkit: connection.serviceId,
                explicitSelection: grant.bundleIds
            ) else { return }
            let response: CloudConnectionsAPI.CreateGrantResponse
            let pushedScope: BundleScope
            do {
                response = try await inboxReady.apiClient.createConnectionGrant(
                    ownerInboxId: inboxReady.client.inboxId,
                    granteeInboxId: grant.grantedToInboxId,
                    conversationId: grant.conversationId,
                    toolkit: connection.serviceId,
                    bundleIds: scope.bundleIds,
                    serviceVersion: scope.serviceVersion
                )
                pushedScope = scope
            } catch CloudConnectionsAPI.GrantError.unknownBundle(let bundleId) {
                Log.warning(
                    "[CloudConnections] grant rejected for stale bundle id " +
                    "(toolkit=\(connection.serviceId), bundleId=\(bundleId ?? "?")); " +
                    "refetching services catalog and retrying once"
                )
                guard let retryScope = try await retryScope(
                    afterUnknownBundleFor: connection.serviceId,
                    firstAttempt: scope
                ) else { return }
                response = try await inboxReady.apiClient.createConnectionGrant(
                    ownerInboxId: inboxReady.client.inboxId,
                    granteeInboxId: grant.grantedToInboxId,
                    conversationId: grant.conversationId,
                    toolkit: connection.serviceId,
                    bundleIds: retryScope.bundleIds,
                    serviceVersion: retryScope.serviceVersion
                )
                pushedScope = retryScope
            }
            let updated = DBCloudConnectionGrant(
                connectionId: grant.connectionId,
                conversationId: grant.conversationId,
                serviceId: grant.serviceId,
                grantedToInboxId: grant.grantedToInboxId,
                grantedAt: grant.grantedAt,
                backendGrantId: response.id,
                bundleIds: pushedScope.bundleIds,
                serviceVersion: pushedScope.serviceVersion
            )
            try await databaseWriter.write { db in
                try updated.save(db)
            }
        } catch {
            Log.error(
                "[CloudConnections] backend grant push failed; agent will get 403 from backend-mediated " +
                "execution until the user re-grants (connectionId=\(grant.connectionId), " +
                "conversationId=\(grant.conversationId), grantedToInboxId=\(grant.grantedToInboxId)): " +
                error.localizedDescription
            )
        }
    }

    private struct BundleScope {
        /// Nil omits `bundleIds` from the request body — the backend's legacy
        /// whole-toolkit path, used for services outside the catalog.
        let bundleIds: [String]?
        let serviceVersion: Int?
    }

    /// Maps the user's bundle selection (nil = full-service consent with no
    /// picker involved) onto the cached services catalog:
    /// - service in catalog + explicit selection → ids kept as picked,
    ///   filtered to the catalog
    /// - service in catalog + nil selection → every catalog bundle id,
    ///   materialized here once so a later retry can only ever narrow it
    /// - service proven absent from a successfully fetched catalog →
    ///   explicit selection as-is, or the legacy whole-toolkit grant when
    ///   there is none
    /// - catalog UNREACHABLE → explicit selection as-is (the backend
    ///   validates it), but a nil selection fails closed: without a
    ///   successful fetch proving the service is uncataloged, omitting
    ///   `bundleIds` could silently escalate a cataloged service to
    ///   whole-toolkit access
    ///
    /// Returns nil to fail closed: a scope that would carry an empty
    /// `bundleIds` array must never be pushed, because the backend treats an
    /// empty array as whole-toolkit access — strictly more than the user
    /// approved. That covers an explicit selection that is empty or no longer
    /// maps to any known bundle, and a cataloged service that lists no
    /// bundles at all.
    private func resolveBundleScope(toolkit: String, explicitSelection: [String]?) async -> BundleScope? {
        if let explicitSelection, explicitSelection.isEmpty {
            Log.error(
                "[CloudConnections] explicit bundle selection for \(toolkit) is empty; " +
                "skipping backend push to avoid escalating an empty selection to " +
                "whole-toolkit access"
            )
            return nil
        }
        let service: CloudConnectionsAPI.ServiceConfig?
        do {
            service = try await servicesStore.service(id: toolkit)
        } catch {
            guard let explicitSelection, !explicitSelection.isEmpty else {
                Log.error(
                    "[CloudConnections] services catalog unavailable for \(toolkit) and no explicit " +
                    "bundle selection to fall back on; skipping backend push rather than risk " +
                    "escalating to whole-toolkit access: \(error.localizedDescription)"
                )
                return nil
            }
            Log.warning(
                "[CloudConnections] services catalog unavailable for \(toolkit); " +
                "pushing the explicit bundle selection unfiltered: \(error.localizedDescription)"
            )
            return BundleScope(bundleIds: explicitSelection, serviceVersion: nil)
        }
        guard let service else {
            return BundleScope(bundleIds: explicitSelection, serviceVersion: nil)
        }
        let known = service.bundles.map(\.id)
        guard let explicitSelection else {
            guard !known.isEmpty else {
                Log.error(
                    "[CloudConnections] catalog lists no bundles for \(toolkit); skipping " +
                    "backend push rather than escalating an empty bundle list to " +
                    "whole-toolkit access"
                )
                return nil
            }
            return BundleScope(bundleIds: known, serviceVersion: service.version)
        }
        let kept = explicitSelection.filter(Set(known).contains)
        guard !kept.isEmpty else {
            Log.error(
                "[CloudConnections] none of the selected bundle ids exist in the catalog for " +
                "\(toolkit) (selected=\(explicitSelection)); skipping backend push to avoid " +
                "escalating an empty selection to whole-toolkit access"
            )
            return nil
        }
        return BundleScope(bundleIds: kept, serviceVersion: service.version)
    }

    /// Recovery scope after a 400 `unknown_bundle`: invalidate + refetch the
    /// catalog, then intersect the ids of the FIRST attempt with the refreshed
    /// catalog. The retry can only ever narrow the originally pushed scope —
    /// recomputing from a nil selection against a refreshed catalog could
    /// widen it past what was first materialized. Returns nil to give up
    /// (fail closed): no bundles survived, the service vanished from the
    /// catalog, or the rejected attempt didn't carry bundle ids at all
    /// (the server only validates non-empty `bundleIds`, so that rejection
    /// is unexpected and not retryable).
    private func retryScope(
        afterUnknownBundleFor toolkit: String,
        firstAttempt: BundleScope
    ) async throws -> BundleScope? {
        guard let firstIds = firstAttempt.bundleIds, !firstIds.isEmpty else {
            Log.error(
                "[CloudConnections] unknown_bundle rejection for a grant that sent no bundle ids " +
                "(toolkit=\(toolkit)); not retrying"
            )
            return nil
        }
        await servicesStore.invalidate()
        guard let refreshed = try await servicesStore.service(id: toolkit) else {
            Log.error(
                "[CloudConnections] \(toolkit) is gone from the refreshed services catalog; " +
                "failing closed instead of retrying the grant push"
            )
            return nil
        }
        let known = Set(refreshed.bundles.map(\.id))
        let kept = firstIds.filter(known.contains)
        guard !kept.isEmpty else {
            Log.error(
                "[CloudConnections] none of the pushed bundle ids survive the refreshed catalog for " +
                "\(toolkit) (pushed=\(firstIds)); failing closed instead of retrying the grant push"
            )
            return nil
        }
        return BundleScope(bundleIds: kept, serviceVersion: refreshed.version)
    }

    /// Revokes the backend consent record for a grant that was just removed
    /// locally. Uses the natural-key revoke (toolkit, conversation, grantee) so
    /// it succeeds even when no backendGrantId was stored (the by-id path can't
    /// run for those rows). Best-effort: a failure is logged and not retried;
    /// the backend connection-level revoke (disconnect) independently cuts off
    /// execution.
    private func revokeBackendGrant(for grant: DBCloudConnectionGrant) async {
        do {
            let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
            try await inboxReady.apiClient.revokeConnectionGrantByNaturalKey(
                toolkit: grant.serviceId,
                conversationId: grant.conversationId,
                granteeInboxId: grant.grantedToInboxId
            )
        } catch {
            Log.warning(
                "[CloudConnections] backend grant revoke failed " +
                "(toolkit=\(grant.serviceId), connectionId=\(grant.connectionId), " +
                "conversationId=\(grant.conversationId), grantedToInboxId=\(grant.grantedToInboxId)): " +
                error.localizedDescription
            )
        }
    }

    private struct GrantKey {
        let connectionId: String
        let conversationId: String
        let grantedToInboxId: String
    }

    private func projectedGrants(
        for conversationId: String,
        addingOrReplacing addition: DBCloudConnectionGrant?,
        removing removal: GrantKey?
    ) async throws -> [DBCloudConnectionGrant] {
        let existing = try await databaseReader.read { db in
            try DBCloudConnectionGrant
                .filter(DBCloudConnectionGrant.Columns.conversationId == conversationId)
                .fetchAll(db)
        }

        var projected = existing
        if let removal {
            projected.removeAll {
                $0.connectionId == removal.connectionId
                    && $0.conversationId == removal.conversationId
                    && $0.grantedToInboxId == removal.grantedToInboxId
            }
        }
        if let addition {
            projected.removeAll {
                $0.connectionId == addition.connectionId
                    && $0.conversationId == addition.conversationId
                    && $0.grantedToInboxId == addition.grantedToInboxId
            }
            projected.append(addition)
        }
        return projected
    }

    private func syncGrantsToMetadata(
        for conversationId: String,
        desiredGrants: [DBCloudConnectionGrant]
    ) async throws {
        let inboxReady = try await sessionStateManager.waitForInboxReadyResult()
        let senderId = inboxReady.client.inboxId

        let connections = try await databaseReader.read { db in
            try DBCloudConnection
                .filter(DBCloudConnection.Columns.status == CloudConnectionStatus.active.rawValue)
                .fetchAll(db)
        }
        let connectionsById = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0) })

        let iso8601 = ISO8601DateFormatter()
        let entries: [CloudConnectionGrantEntry] = desiredGrants.compactMap { grant in
            guard let conn = connectionsById[grant.connectionId] else { return nil }
            return CloudConnectionGrantEntry(
                id: "grant_\(grant.connectionId)_\(conversationId)_\(grant.grantedToInboxId)",
                senderId: senderId,
                grantedToInboxId: grant.grantedToInboxId,
                service: conn.serviceId,
                provider: conn.provider,
                scope: "conversation",
                composioEntityId: conn.composioEntityId,
                composioConnectionId: conn.composioConnectionId,
                grantedAt: iso8601.string(from: grant.grantedAt)
            )
        }

        let payload = CloudConnectionsMetadataPayload(grants: entries)
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
            guard let conversation = try await inboxReady.client.conversation(with: conversationId),
                  case .group(let group) = conversation else {
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
        // Route through the shared ProfileMetadataWriter so a connections write
        // and a timezone write can never interleave on the per-sender metadata
        // map's non-atomic read-merge-write.
        let connectionsKey = Constant.connectionsKey
        try await profileMetadataWriter.updateMetadata(
            conversationId: conversationId,
            inboxId: senderId
        ) { metadata in
            if let grantsJson {
                metadata[connectionsKey] = .string(grantsJson)
            } else {
                metadata.removeValue(forKey: connectionsKey)
            }
        }
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

enum CloudConnectionGrantError: LocalizedError {
    case connectionNotFound(String)
    case connectionNotActive(String, status: String)
    case conversationNotFound(String)
    case missingGrantedToInboxId

    var errorDescription: String? {
        switch self {
        case .connectionNotFound(let id):
            "CloudConnection not found: \(id)"
        case let .connectionNotActive(id, status):
            "CloudConnection not active (\(status)): \(id)"
        case .conversationNotFound(let id):
            "Conversation not found: \(id)"
        case .missingGrantedToInboxId:
            "grantedToInboxId is required and cannot be empty"
        }
    }
}
