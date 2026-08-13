import Foundation

/// Grants the acting user's own live cloud connections to an agent they just
/// added to a conversation, so a fresh agent conversation starts with the
/// user's already-connected abilities enabled instead of requiring a trip to
/// the conversation-info toggles. Runs the same per-agent grant fan-out the
/// manual toggle runs (the confirming grant writer plus one granted
/// transcript line per service), so the resulting rows are indistinguishable
/// from a manual toggle-on and the toggle UI stays truthful through its
/// normal data flow.
///
/// Everything here is best-effort: the entry point never throws and callers
/// run it detached from the join path, so a failure can never block or fail
/// adding the agent. Grant state is device-local until normal sync paths
/// run; another device on the same account sees the enablement only through
/// those paths.
public final class AutoEnableAbilitiesService: Sendable {
    private let cloudConnectionRepository: any CloudConnectionRepositoryProtocol
    private let grantWriter: any CloudConnectionGrantWriterProtocol
    private let connectionEventWriter: any ConnectionEventWriterProtocol
    /// Gate evaluated on every invocation. The abilities v2 surfaces replace
    /// the v1 connections toggle this service mirrors, so the host wires this
    /// to the same flag check that decides which surface renders; while v2 is
    /// active the service stands down entirely.
    private let isEnabled: @Sendable () async -> Bool

    public init(
        cloudConnectionRepository: any CloudConnectionRepositoryProtocol,
        grantWriter: any CloudConnectionGrantWriterProtocol,
        connectionEventWriter: any ConnectionEventWriterProtocol,
        isEnabled: @escaping @Sendable () async -> Bool
    ) {
        self.cloudConnectionRepository = cloudConnectionRepository
        self.grantWriter = grantWriter
        self.connectionEventWriter = connectionEventWriter
        self.isEnabled = isEnabled
    }

    /// Auto-enables every qualifying connection for `agentInboxId` in
    /// `conversationId`. Qualifying means an active composio-backed
    /// account-level connection for a supported service with no existing
    /// grant row for this (connection, conversation, agent) tuple.
    ///
    /// Each connection goes through the confirming grant path so a row only
    /// counts as enabled with a live backend grant behind it:
    /// - Confirmed: the row stands and one granted transcript line posts.
    /// - Refused with the typed connection-not-found (no live credential
    ///   server-side): the just-published metadata and local row are rolled
    ///   back through the revoke path and the service is left to the manual
    ///   toggle, which can route the user through OAuth. No error surfaces;
    ///   there is no user mid-flow here.
    /// - Any other failure: the unconfirmed row stands (its nil
    ///   backendGrantId marks the push as still owed, same as a manual
    ///   toggle whose push failed) and no transcript line posts.
    public func autoEnable(conversationId: String, agentInboxId: String) async {
        guard await isEnabled() else {
            Log.info("[AutoEnableAbilities] disabled; skipping for conversation \(conversationId)")
            return
        }
        guard !agentInboxId.isEmpty else {
            Log.warning("[AutoEnableAbilities] empty agent inbox id for conversation \(conversationId); skipping")
            return
        }
        let connections: [CloudConnection]
        let existingGrants: [CloudConnectionGrant]
        do {
            connections = try await cloudConnectionRepository.connections()
            existingGrants = try await cloudConnectionRepository.grants(for: conversationId)
        } catch {
            Log.error("[AutoEnableAbilities] reading connection state failed for \(conversationId): \(error.localizedDescription)")
            return
        }
        let candidates = Self.qualifyingConnections(
            connections: connections,
            existingGrants: existingGrants,
            conversationId: conversationId,
            agentInboxId: agentInboxId
        )
        // Sequential on purpose: each confirming grant reads the
        // conversation's current grant rows and republishes the projected
        // set, so concurrent grants for one conversation would race that
        // read-project-publish sequence.
        for connection in candidates {
            await grantAndAnnounce(
                connection: connection,
                conversationId: conversationId,
                agentInboxId: agentInboxId
            )
        }
    }

    /// The connections worth granting: active composio-backed rows for
    /// supported services, minus any the agent already holds a grant row for
    /// in this conversation. Grants held by other agents don't count; grant
    /// rows are per (connection, conversation, agent).
    static func qualifyingConnections(
        connections: [CloudConnection],
        existingGrants: [CloudConnectionGrant],
        conversationId: String,
        agentInboxId: String
    ) -> [CloudConnection] {
        let alreadyGrantedConnectionIds = Set(
            existingGrants
                .filter { $0.conversationId == conversationId && $0.grantedToInboxId == agentInboxId }
                .map(\.connectionId)
        )
        return connections.filter { connection in
            connection.provider == .composio
                && connection.status == .active
                && SupportedConnections.isSupported(cloudServiceId: connection.serviceId)
                && !alreadyGrantedConnectionIds.contains(connection.id)
        }
    }

    private func grantAndAnnounce(
        connection: CloudConnection,
        conversationId: String,
        agentInboxId: String
    ) async {
        let providerId = "composio.\(connection.serviceId)"
        do {
            // Nil bundle selection is the no-picker consent shape: the writer
            // materializes the full catalog bundle scope for the service.
            try await grantWriter.grantConnectionConfirmingBackend(
                connection.id,
                to: conversationId,
                grantedToInboxId: agentInboxId,
                bundleIds: nil
            )
        } catch CloudConnectionsAPI.GrantError.connectionNotFound {
            // The backend holds no live credential behind this connection, so
            // it refused the grant after the local row and profile metadata
            // were already published. Roll both back through the revoke path
            // so nothing reads the refused grant as live.
            Log.warning("[AutoEnableAbilities] backend holds no live connection for \(providerId); rolling back the local grant")
            do {
                try await grantWriter.revokeGrant(
                    connectionId: connection.id,
                    from: conversationId,
                    grantedToInboxId: agentInboxId
                )
            } catch {
                Log.error("[AutoEnableAbilities] rollback failed for \(providerId) in \(conversationId): \(error.localizedDescription)")
            }
            return
        } catch {
            Log.error("[AutoEnableAbilities] grant failed for \(providerId) -> \(agentInboxId) in \(conversationId): \(error.localizedDescription)")
            return
        }
        // One conversation-level transcript line per service crediting the
        // agent, the same shape the manual toggle posts. Best-effort: the
        // grant is already confirmed, so a failed line is only cosmetic.
        try? await connectionEventWriter.sendGranted(
            providerId: providerId,
            capability: nil,
            grantedToInboxId: agentInboxId,
            in: conversationId
        )
    }
}
