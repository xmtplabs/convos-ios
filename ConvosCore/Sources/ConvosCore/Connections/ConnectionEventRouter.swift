import ConvosConnections
import Foundation
import GRDB

/// Routes connection grant/revoke events to the agent DM instead of the group
/// the grant was made from, so the transcript humans share isn't the agent's
/// audit log.
///
/// Callers keep addressing the origin conversation (the group the grant is
/// scoped to) through `ConnectionEventWriterProtocol`, exactly as before; the
/// router decides where the event actually lands:
/// - **Granted, agent DM known:** the full event goes to the DM, and a
///   grantee-less copy tagged `notice: true` goes to the origin group for
///   discoverability. The notice is render-only by contract — agent runtimes
///   drop it before it reaches the model.
/// - **Revoked, agent DM known:** the full event goes to the DM only.
/// - **No `grantedToInboxId`, no resolvable DM, or the DM send fails:** the
///   full event goes to the origin conversation — today's behavior, so events
///   never get lost while DM links are still propagating.
final class ConnectionEventRouter: ConnectionEventWriterProtocol, Sendable {
    private let sender: any ConnectionEventSending
    private let resolveAgentDm: @Sendable (_ agentInboxId: String, _ originConversationId: String) async -> String?

    init(
        sender: any ConnectionEventSending,
        resolveAgentDm: @escaping @Sendable (_ agentInboxId: String, _ originConversationId: String) async -> String?
    ) {
        self.sender = sender
        self.resolveAgentDm = resolveAgentDm
    }

    convenience init(sender: any ConnectionEventSending, databaseReader: any DatabaseReader) {
        self.init(sender: sender) { agentInboxId, originConversationId in
            let resolved: String?? = try? await databaseReader.read { db in
                try DBAgentDmOrigin.dmConversationId(
                    forOrigin: originConversationId,
                    agentInboxId: agentInboxId,
                    in: db
                )
            }
            return resolved.flatMap { $0 }
        }
    }

    func sendGranted(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws {
        try await route(
            ConnectionEvent(
                providerId: providerId,
                action: .granted,
                capability: capability,
                grantedToInboxId: grantedToInboxId
            ),
            from: conversationId
        )
    }

    func sendRevoked(
        providerId: String,
        capability: ConnectionCapability?,
        grantedToInboxId: String?,
        in conversationId: String
    ) async throws {
        try await route(
            ConnectionEvent(
                providerId: providerId,
                action: .revoked,
                capability: capability,
                grantedToInboxId: grantedToInboxId
            ),
            from: conversationId
        )
    }

    private func route(_ event: ConnectionEvent, from conversationId: String) async throws {
        guard let agentInboxId = event.grantedToInboxId, !agentInboxId.isEmpty,
              let dmConversationId = await resolveAgentDm(agentInboxId, conversationId),
              dmConversationId != conversationId else {
            try await sender.send(event, in: conversationId)
            return
        }

        do {
            try await sender.send(event, in: dmConversationId)
        } catch {
            Log.warning(
                "[connections] DM route failed for \(event.action.rawValue) \(event.providerId); " +
                "falling back to \(conversationId): \(error)"
            )
            try await sender.send(event, in: conversationId)
            return
        }

        guard event.action == .granted else { return }
        // Discoverability line in the group. Best-effort: the authoritative
        // event already landed in the DM, so a failed copy shouldn't fail the
        // grant flow.
        let notice = ConnectionEvent(
            providerId: event.providerId,
            action: .granted,
            capability: event.capability,
            grantedToInboxId: nil,
            notice: true
        )
        do {
            try await sender.send(notice, in: conversationId)
        } catch {
            Log.warning("[connections] notice copy failed for \(event.providerId) in \(conversationId): \(error)")
        }
    }
}
