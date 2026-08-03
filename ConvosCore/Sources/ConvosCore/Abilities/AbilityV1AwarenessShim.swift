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
/// V1 connections write can never interleave) and the payload shape the
/// agent runtime reads (see `CloudConnectionsMetadataPayload`).
///
/// The merge is surgical and lossless. Shim entries are identified
/// exclusively by their deterministic `grant_v2_...` id; upsert and
/// removal touch only the matching shim entry, never genuine V1 grants --
/// even same-toolkit, same-agent ones. The payload is edited as generic
/// JSON, so unknown fields on other entries (and unknown top-level keys)
/// survive verbatim. A payload that does not parse as the expected shape
/// is left untouched and the shim write is skipped (the serialized write
/// republishes the unchanged map once; harmless, logged).
///
/// Deliberate deltas from a real V1 entry:
/// - `composioEntityId`/`composioConnectionId` are empty: V2 never serves
///   credential identifiers to clients, and the runtime's awareness path
///   keys off `service` + `grantedToInboxId`, not the Composio ids.
/// - Bundle selection is not represented: the V1 payload has no bundle
///   field, so the shim conveys toolkit-level awareness only. Actual
///   permission scoping stays backend-side on the V2 entitlement.
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

    /// The ownership namespace for shim-written entries. Merge logic here
    /// may only touch entries carrying this prefix, and the V1 grant
    /// writer's wholesale payload rebuild preserves them by the same
    /// marker.
    static let entryIdNamespace: String = "grant_v2_"

    /// The deterministic shim-owned entry id. Components are
    /// length-prefixed because they may themselves contain the separator:
    /// a plain join would collide across distinct tuples (`("a_b", "c")`
    /// vs `("a", "b_c")`), letting one ability's extension replace or
    /// remove another's shim entry.
    static func shimEntryId(abilityId: String, conversationId: String, agentInboxId: String) -> String {
        let components = [abilityId, conversationId, agentInboxId]
        let encoded = components
            .map { (component: String) -> String in "\(component.utf8.count).\(component)" }
            .joined(separator: "_")
        return "\(entryIdNamespace)\(encoded)"
    }

    /// The shim-owned entries in an existing connections payload, as
    /// generic JSON objects. Used by `CloudConnectionGrantWriter` to carry
    /// them across its from-scratch payload rebuilds, which would otherwise
    /// silently drop V2 awareness whenever a V1 grant changes. An
    /// unparseable payload reads as no entries -- the V1 writer is about
    /// to replace it wholesale anyway.
    static func shimOwnedEntries(inPayload json: String?) -> [[String: Any]] {
        guard let json, let payload = parsePayload(json) else { return [] }
        let grants: [[String: Any]] = (payload["grants"] as? [[String: Any]]) ?? []
        return grants.filter { (($0["id"] as? String) ?? "").hasPrefix(entryIdNamespace) }
    }

    public func recordExtension(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String]) async {
        let entryId = Self.shimEntryId(abilityId: abilityId, conversationId: conversationId, agentInboxId: agentInboxId)
        let grantedAt = ISO8601DateFormatter().string(from: Date())
        let outcome = OutcomeBox()
        do {
            let senderId = try await myInboxIdProvider()
            try await profileMetadataWriter.updateMetadata(conversationId: conversationId, inboxId: senderId) { metadata in
                // Built inside the closure from Sendable captures.
                let entryJSON: [String: Any] = [
                    "id": entryId,
                    "senderId": senderId,
                    "grantedToInboxId": agentInboxId,
                    "service": abilityId,
                    "provider": "composio",
                    "scope": "conversation",
                    "composioEntityId": "",
                    "composioConnectionId": "",
                    "grantedAt": grantedAt,
                ]
                outcome.applied = Self.upsert(entryJSON: entryJSON, entryId: entryId, in: &metadata)
            }
            logOutcome(outcome, operation: "grant", abilityId: abilityId, agentInboxId: agentInboxId, bundleCount: bundleIds.count)
        } catch {
            Log.warning(
                "[Abilities] V1 awareness shim grant write failed (best-effort; V2 grant unaffected) " +
                "(abilityId=\(abilityId), conversationId=\(conversationId), agentInboxId=\(agentInboxId)): " +
                error.localizedDescription
            )
        }
    }

    public func recordWithdrawal(conversationId: String, abilityId: String, agentInboxId: String) async {
        let entryId = Self.shimEntryId(abilityId: abilityId, conversationId: conversationId, agentInboxId: agentInboxId)
        let outcome = OutcomeBox()
        do {
            let senderId = try await myInboxIdProvider()
            try await profileMetadataWriter.updateMetadata(conversationId: conversationId, inboxId: senderId) { metadata in
                outcome.applied = Self.remove(entryId: entryId, from: &metadata)
            }
            logOutcome(outcome, operation: "revoke", abilityId: abilityId, agentInboxId: agentInboxId, bundleCount: nil)
        } catch {
            Log.warning(
                "[Abilities] V1 awareness shim revoke write failed (best-effort; V2 withdrawal unaffected) " +
                "(abilityId=\(abilityId), conversationId=\(conversationId), agentInboxId=\(agentInboxId)): " +
                error.localizedDescription
            )
        }
    }

    private func logOutcome(_ outcome: OutcomeBox, operation: String, abilityId: String, agentInboxId: String, bundleCount: Int?) {
        if outcome.applied {
            let bundleSuffix = bundleCount.map { ", bundles=\($0)" } ?? ""
            Log.info("[Abilities] V1 awareness shim recorded \(operation) (service=\(abilityId), agent=\(agentInboxId)\(bundleSuffix))")
        } else {
            Log.warning(
                "[Abilities] V1 awareness shim skipped \(operation): existing connections payload " +
                "is not in the expected shape and was left untouched (service=\(abilityId), agent=\(agentInboxId))"
            )
        }
    }

    // MARK: - Payload merging (generic JSON, shim-owned entries only)

    /// Returns false when the existing payload cannot be edited safely
    /// (undecodable or unexpected shape); the metadata is left untouched.
    private static func upsert(entryJSON: [String: Any], entryId: String, in metadata: inout ProfileMetadata) -> Bool {
        var payloadObject: [String: Any]
        if let existingJson = metadata[ConversationScopedMetadataKey.connections]?.stringValue {
            guard let parsed = parsePayload(existingJson) else { return false }
            payloadObject = parsed
        } else {
            payloadObject = ["version": 1]
        }
        var grants: [[String: Any]] = (payloadObject["grants"] as? [[String: Any]]) ?? []
        grants.removeAll { ($0["id"] as? String) == entryId }
        grants.append(entryJSON)
        payloadObject["grants"] = grants
        guard let json = serialize(payloadObject) else { return false }
        metadata[ConversationScopedMetadataKey.connections] = .string(json)
        return true
    }

    /// Returns false only for an unsafely-editable payload. A payload with
    /// no matching shim entry is a successful no-op (left untouched).
    private static func remove(entryId: String, from metadata: inout ProfileMetadata) -> Bool {
        guard let existingJson = metadata[ConversationScopedMetadataKey.connections]?.stringValue else {
            return true
        }
        guard var payloadObject = parsePayload(existingJson) else { return false }
        var grants: [[String: Any]] = (payloadObject["grants"] as? [[String: Any]]) ?? []
        let countBefore = grants.count
        grants.removeAll { ($0["id"] as? String) == entryId }
        guard grants.count != countBefore else { return true }
        // Mirror the V1 writer's empty-payload behavior (clear the key)
        // only when nothing but the known envelope keys would be lost.
        if grants.isEmpty, Set(payloadObject.keys).isSubset(of: ["version", "grants"]) {
            metadata.removeValue(forKey: ConversationScopedMetadataKey.connections)
            return true
        }
        payloadObject["grants"] = grants
        guard let json = serialize(payloadObject) else { return false }
        metadata[ConversationScopedMetadataKey.connections] = .string(json)
        return true
    }

    /// Parses the payload as generic JSON, requiring only the envelope
    /// shape the merge relies on: a top-level object whose `grants` key,
    /// when present, is an array of objects. Anything else is unsafe to
    /// edit and reads as nil.
    private static func parsePayload(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let grants = object["grants"], !(grants is [[String: Any]]) {
            return nil
        }
        return object
    }

    private static func serialize(_ payloadObject: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(payloadObject),
              let data = try? JSONSerialization.data(withJSONObject: payloadObject, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Carries the merge outcome out of the non-throwing update closure so
    /// the skip case can be logged. Written and read sequentially around
    /// the awaited update; never shared concurrently.
    private final class OutcomeBox: @unchecked Sendable {
        var applied: Bool = true
    }
}
