import Foundation

/// Best-effort side-writes keeping V1-reader agents aware of V2 ability
/// extensions during the MCP transition. Failures never propagate: the
/// backend's V2 grant is the enforcement path, the shim only affects what
/// a V1 runtime can see.
public protocol AbilityV1AwarenessShimWriting: Sendable {
    func recordExtension(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String]) async
    func recordWithdrawal(conversationId: String, abilityId: String, agentInboxId: String) async
}

/// Publishes V1-shaped `connections` grant entries to the conversation's
/// per-sender `ProfileUpdate` metadata when a V2 ability is extended or
/// withdrawn, reusing the V1 writer machinery: the shared
/// `ProfileMetadataWriter` choke point (so a shim write and a timezone or
/// V1 connections write can never interleave) and the
/// `CloudConnectionsMetadataPayload` wire shape the agent runtime reads.
///
/// Deliberate deltas from a real V1 entry:
/// - `composioEntityId`/`composioConnectionId` are empty: V2 never serves
///   credential identifiers to clients, and the runtime's awareness path
///   keys off `service` + `grantedToInboxId`, not the Composio ids.
/// - Bundle selection is not represented: the V1 payload has no bundle
///   field, so the shim conveys toolkit-level awareness only. Actual
///   permission scoping stays backend-side on the V2 entitlement.
///
/// Entries are keyed by (service, grantedToInboxId) within the
/// conversation payload, so a shim write upserts over a same-keyed V1
/// entry rather than duplicating it.
public final class AbilityV1AwarenessShimWriter: AbilityV1AwarenessShimWriting, Sendable {
    private let profileMetadataWriter: any ProfileMetadataWriterProtocol
    /// The caller's inbox id; also the metadata sender. Throws when the
    /// inbox never becomes ready, which the shim swallows as best-effort.
    private let myInboxIdProvider: @Sendable () async throws -> String

    public init(
        profileMetadataWriter: any ProfileMetadataWriterProtocol,
        myInboxIdProvider: @escaping @Sendable () async throws -> String
    ) {
        self.profileMetadataWriter = profileMetadataWriter
        self.myInboxIdProvider = myInboxIdProvider
    }

    public func recordExtension(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String]) async {
        do {
            let senderId = try await myInboxIdProvider()
            let entry = CloudConnectionGrantEntry(
                id: "grant_v2_\(abilityId)_\(conversationId)_\(agentInboxId)",
                senderId: senderId,
                grantedToInboxId: agentInboxId,
                service: abilityId,
                provider: "composio",
                scope: "conversation",
                composioEntityId: "",
                composioConnectionId: "",
                grantedAt: ISO8601DateFormatter().string(from: Date())
            )
            try await profileMetadataWriter.updateMetadata(conversationId: conversationId, inboxId: senderId) { metadata in
                Self.upsert(entry: entry, in: &metadata)
            }
            Log.info("[Abilities] V1 awareness shim recorded extension (service=\(abilityId), agent=\(agentInboxId), bundles=\(bundleIds.count))")
        } catch {
            Log.warning(
                "[Abilities] V1 awareness shim grant write failed (best-effort; V2 grant unaffected) " +
                "(abilityId=\(abilityId), conversationId=\(conversationId), agentInboxId=\(agentInboxId)): " +
                error.localizedDescription
            )
        }
    }

    public func recordWithdrawal(conversationId: String, abilityId: String, agentInboxId: String) async {
        do {
            let senderId = try await myInboxIdProvider()
            try await profileMetadataWriter.updateMetadata(conversationId: conversationId, inboxId: senderId) { metadata in
                Self.remove(service: abilityId, grantedToInboxId: agentInboxId, from: &metadata)
            }
            Log.info("[Abilities] V1 awareness shim recorded withdrawal (service=\(abilityId), agent=\(agentInboxId))")
        } catch {
            Log.warning(
                "[Abilities] V1 awareness shim revoke write failed (best-effort; V2 withdrawal unaffected) " +
                "(abilityId=\(abilityId), conversationId=\(conversationId), agentInboxId=\(agentInboxId)): " +
                error.localizedDescription
            )
        }
    }

    // MARK: - Payload merging

    private static func upsert(entry: CloudConnectionGrantEntry, in metadata: inout ProfileMetadata) {
        var payload = decodePayload(metadata) ?? CloudConnectionsMetadataPayload()
        payload.grants.removeAll { $0.service == entry.service && $0.grantedToInboxId == entry.grantedToInboxId }
        payload.grants.append(entry)
        write(payload, to: &metadata)
    }

    private static func remove(service: String, grantedToInboxId: String, from metadata: inout ProfileMetadata) {
        guard var payload = decodePayload(metadata) else { return }
        payload.grants.removeAll { $0.service == service && $0.grantedToInboxId == grantedToInboxId }
        write(payload, to: &metadata)
    }

    private static func decodePayload(_ metadata: ProfileMetadata) -> CloudConnectionsMetadataPayload? {
        guard let json = metadata[ConversationScopedMetadataKey.connections]?.stringValue else { return nil }
        return try? CloudConnectionsMetadataPayload.fromJsonString(json)
    }

    private static func write(_ payload: CloudConnectionsMetadataPayload, to metadata: inout ProfileMetadata) {
        if payload.isEmpty {
            metadata.removeValue(forKey: ConversationScopedMetadataKey.connections)
        } else if let json = try? payload.toJsonString() {
            metadata[ConversationScopedMetadataKey.connections] = .string(json)
        }
    }
}
