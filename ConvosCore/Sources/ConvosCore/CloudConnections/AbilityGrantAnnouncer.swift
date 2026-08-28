import Foundation

/// Announces a per-conversation ability opt-in to the agent runtime.
///
/// The abilities surfaces (the Connections browser's per-chat toggles and
/// the conversation-info section) write the backend entitlement tables, but
/// the agent runtime's connections skill resolves grants from the sender's
/// profile metadata (`metadata["connections"]`) - the ledger only the
/// capability-card approval path wrote. Without this announcement a
/// toggled-on ability is authorized backend-side yet invisible to the
/// agent, which then cards the member for consent they already gave.
///
/// Successor to the deleted `AbilityV1AwarenessShimWriter` (removed in
/// #1442 as dead debug code), with different semantics: production-on by
/// design, and full card-path equivalence - real grant rows via
/// `CloudConnectionGrantWriter` (metadata payload + backend consent
/// record) plus the in-chat granted/revoked `ConnectionEvent` - rather
/// than the shim's flag-gated raw-JSON side-write.
///
/// Best-effort by contract: the backend opt-in the caller just wrote is
/// the authoritative record, so a failed announcement is logged and
/// swallowed - the member's toggle must never revert because a profile
/// publish failed. The worst case is the pre-announcement behavior: the
/// agent asks once.
public protocol AbilityGrantAnnouncing: Sendable {
    /// The member enabled `abilityId` for `agentInboxId` in `conversationId`.
    func announceEnabled(
        conversationId: String,
        agentInboxId: String,
        abilityId: String,
        bundleIds: [String]
    ) async

    /// The member disabled `abilityId` for `agentInboxId` in `conversationId`.
    func announceDisabled(
        conversationId: String,
        agentInboxId: String,
        abilityId: String
    ) async
}

/// `AbilityGrantAnnouncing` backed by the same `CloudConnectionGrantWriter`
/// the capability-card approval path uses, so a toggle-on becomes
/// equivalent to approving a card.
///
/// Ability ids are Composio toolkit slugs, the same namespace as
/// `CloudConnection.serviceId` (an assumption the deleted shim relied on
/// undocumented; documented here), so resolution is a direct
/// most-recent-active match over the repository's connections - with one
/// `refreshConnections` retry, because an ability connected moments ago
/// through the V2 abilities OAuth exists in the backend's list but not
/// yet in the local store. The refresh is safe to call here: it is a
/// delta update by design (see `CloudConnectionManager.refreshConnections`),
/// never a delete-and-reinsert that would cascade grants away.
///
/// Idempotent by repository check, mirroring
/// `AgentBuilderConnectionGrantReplayer` - but scope-aware: an
/// already-recorded grant for (service, agent, conversation) whose bundle
/// set matches the request announces nothing (no duplicate backend push,
/// no duplicate transcript line), while a recorded grant with a
/// *different* bundle set is re-granted so the corrected scope reaches
/// the metadata payload and the backend consent record - the legacy
/// entitlement fallback authorizes from that record, so a stale wider
/// scope there would outlive the member's narrower re-selection. A scope
/// correction is not a new connection, so it broadcasts no transcript
/// event (matching the card path's diff-based
/// `newlyApprovedProviderIds` broadcasting). A recorded nil bundle set
/// (legacy full-service) compared against an explicit selection is
/// treated as different - the conservative direction is to re-push the
/// explicit scope.
public final class CloudAbilityGrantAnnouncer: AbilityGrantAnnouncing {
    private let repository: any CloudConnectionRepositoryProtocol
    private let grantWriter: @Sendable () -> any CloudConnectionGrantWriterProtocol
    private let eventWriter: @Sendable () -> any ConnectionEventWriterProtocol
    private let refreshConnections: @Sendable () async throws -> Void

    public init(
        repository: any CloudConnectionRepositoryProtocol,
        grantWriter: @escaping @Sendable () -> any CloudConnectionGrantWriterProtocol,
        eventWriter: @escaping @Sendable () -> any ConnectionEventWriterProtocol,
        refreshConnections: @escaping @Sendable () async throws -> Void
    ) {
        self.repository = repository
        self.grantWriter = grantWriter
        self.eventWriter = eventWriter
        self.refreshConnections = refreshConnections
    }

    public func announceEnabled(
        conversationId: String,
        agentInboxId: String,
        abilityId: String,
        bundleIds: [String]
    ) async {
        do {
            // An empty explicit selection is never pushed (the writer fails
            // closed on it); nil means full-service consent materialized
            // from the catalog, which matches a toggle with no picker.
            let requestedBundles: [String]? = bundleIds.isEmpty ? nil : bundleIds
            let recorded = try await repository.grants(for: conversationId).first {
                $0.serviceId == abilityId && $0.grantedToInboxId == agentInboxId
            }
            if let recorded, Self.scopeMatches(recorded: recorded.bundleIds, requested: requestedBundles) {
                return
            }

            guard let connection = try await resolveActiveConnection(serviceId: abilityId) else {
                Log.warning(
                    "[abilities] no active cloud connection for \(abilityId) even after refresh; " +
                        "grant not announced - the agent will card on first use"
                )
                return
            }
            try await grantWriter().grantConnection(
                connection.id,
                to: conversationId,
                grantedToInboxId: agentInboxId,
                bundleIds: requestedBundles
            )
            // Only a NEW grant puts a "connected" line in the transcript; a
            // scope correction over an existing grant is not a new
            // connection (see the class doc).
            if recorded == nil {
                await broadcast(.granted, abilityId: abilityId, agentInboxId: agentInboxId, in: conversationId)
            }
        } catch is CancellationError {
            return
        } catch {
            Log.warning(
                "[abilities] announcing \(abilityId) enable failed " +
                    "(conversationId=\(conversationId), agent=\(agentInboxId)): \(error); " +
                    "the agent will card on first use"
            )
        }
    }

    public func announceDisabled(
        conversationId: String,
        agentInboxId: String,
        abilityId: String
    ) async {
        do {
            // Revoke by the recorded grant rows rather than the currently
            // active connection: the connection that was granted may since
            // have been replaced, and an un-announced grant (toggled on
            // before announcements existed) simply has no rows to revoke.
            let recorded = try await repository.grants(for: conversationId).filter {
                $0.serviceId == abilityId && $0.grantedToInboxId == agentInboxId
            }
            for grant in recorded {
                try await grantWriter().revokeGrant(
                    connectionId: grant.connectionId,
                    from: conversationId,
                    grantedToInboxId: agentInboxId
                )
            }
            // Only when something actually changed: a revoked-nothing
            // broadcast would put a "removed" line in the transcript over
            // a no-op.
            if !recorded.isEmpty {
                await broadcast(.revoked, abilityId: abilityId, agentInboxId: agentInboxId, in: conversationId)
            }
        } catch is CancellationError {
            return
        } catch {
            Log.warning(
                "[abilities] announcing \(abilityId) disable failed " +
                    "(conversationId=\(conversationId), agent=\(agentInboxId)): \(error); " +
                    "the metadata grant may outlive the withdrawn opt-in"
            )
        }
    }

    private enum BroadcastAction {
        case granted
        case revoked
    }

    /// The in-chat "connected their <service>" transcript line, exactly as
    /// the capability-card path broadcasts it. Best-effort on its own: the
    /// grant already landed, and a dropped transcript line is cosmetic
    /// (same posture as `AgentBuilderConnectionGrantReplayer`).
    private func broadcast(
        _ action: BroadcastAction,
        abilityId: String,
        agentInboxId: String,
        in conversationId: String
    ) async {
        let providerId = "composio.\(abilityId)"
        do {
            switch action {
            case .granted:
                try await eventWriter().sendGranted(
                    providerId: providerId,
                    capability: nil,
                    grantedToInboxId: agentInboxId,
                    in: conversationId
                )
            case .revoked:
                try await eventWriter().sendRevoked(
                    providerId: providerId,
                    capability: nil,
                    grantedToInboxId: agentInboxId,
                    in: conversationId
                )
            }
        } catch is CancellationError {
            return
        } catch {
            Log.warning("[abilities] \(action) broadcast failed for \(abilityId) in \(conversationId): \(error)")
        }
    }

    /// Whether the recorded grant's bundle scope already covers exactly
    /// what the caller is announcing. Nil on both sides is full-service
    /// consent twice - a match. Nil on one side only cannot be compared
    /// locally (the writer materializes nil from the live catalog), so it
    /// reads as different and the explicit scope is re-pushed.
    private static func scopeMatches(recorded: [String]?, requested: [String]?) -> Bool {
        switch (recorded, requested) {
        case (nil, nil):
            return true
        case let (recorded?, requested?):
            return Set(recorded) == Set(requested)
        default:
            return false
        }
    }

    private func resolveActiveConnection(serviceId: String) async throws -> CloudConnection? {
        if let connection = try await activeConnection(serviceId: serviceId) {
            return connection
        }
        do {
            try await refreshConnections()
        } catch {
            Log.warning("[abilities] connection refresh failed while resolving \(serviceId): \(error)")
        }
        return try await activeConnection(serviceId: serviceId)
    }

    /// Most-recent active connection for the service, matching
    /// `CloudConnectionManager.existingActiveConnection`.
    private func activeConnection(serviceId: String) async throws -> CloudConnection? {
        try await repository.connections()
            .filter { $0.serviceId == serviceId && $0.status == .active }
            .max { $0.connectedAt < $1.connectedAt }
    }
}
