@testable import ConvosCore
import Foundation
import Testing

/// Stateful metadata writer: keeps a persistent per-(conversation, inbox)
/// map across updates so merge behavior (surgical upsert next to V1
/// entries, key removal on empty payload) is observable, unlike the
/// empty-map `MockProfileMetadataWriter`.
private final class StatefulMetadataWriter: ProfileMetadataWriterProtocol, @unchecked Sendable {
    private(set) var store: [String: ProfileMetadata] = [:]
    var updateError: (any Error)?

    func updateMetadata(
        conversationId: String,
        inboxId: String,
        update: @escaping @Sendable (inout ProfileMetadata) -> Void
    ) async throws {
        if let updateError {
            throw updateError
        }
        let key = "\(conversationId)|\(inboxId)"
        var metadata = store[key] ?? [:]
        update(&metadata)
        store[key] = metadata
    }

    func seed(conversationId: String, inboxId: String, connectionsJson: String) {
        store["\(conversationId)|\(inboxId)"] = [ConversationScopedMetadataKey.connections: .string(connectionsJson)]
    }

    func metadata(conversationId: String, inboxId: String) -> ProfileMetadata {
        store["\(conversationId)|\(inboxId)"] ?? [:]
    }
}

private final class RecordingShimWriter: AbilityV1AwarenessShimWriting, @unchecked Sendable {
    private(set) var extensions: [(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String])] = []
    private(set) var withdrawals: [(conversationId: String, abilityId: String, agentInboxId: String)] = []

    func recordExtension(conversationId: String, abilityId: String, agentInboxId: String, bundleIds: [String]) async {
        extensions.append((conversationId, abilityId, agentInboxId, bundleIds))
    }

    func recordWithdrawal(conversationId: String, abilityId: String, agentInboxId: String) async {
        withdrawals.append((conversationId, abilityId, agentInboxId))
    }
}

@Suite("AbilityV1AwarenessShimWriter")
struct AbilityV1AwarenessShimTests {
    /// A realistic V1 writer entry for the same toolkit and agent the shim
    /// targets, carrying real Composio ids plus fields a newer writer might
    /// add -- everything the shim must preserve verbatim.
    private let v1EntryJson = """
    {"composioConnectionId":"comp-conn-1","composioEntityId":"comp-entity-1","futureField":{"nested":true},\
    "grantedAt":"2026-07-01T00:00:00Z","grantedToInboxId":"agent-1","id":"grant_conn1_conv-1_agent-1",\
    "provider":"composio","scope":"conversation","senderId":"my-inbox","service":"googlecalendar"}
    """

    private var v1PayloadJson: String {
        #"{"customTopLevel":"keep","grants":[\#(v1EntryJson)],"version":1}"#
    }

    private func makeShim(writer: StatefulMetadataWriter, inboxId: String = "my-inbox") -> AbilityV1AwarenessShimWriter {
        AbilityV1AwarenessShimWriter(
            profileMetadataWriter: writer,
            myInboxIdProvider: { inboxId }
        )
    }

    private func payloadObject(from writer: StatefulMetadataWriter, conversationId: String, inboxId: String = "my-inbox") throws -> [String: Any]? {
        let metadata = writer.metadata(conversationId: conversationId, inboxId: inboxId)
        guard let json = metadata[ConversationScopedMetadataKey.connections]?.stringValue else { return nil }
        let data = try #require(json.data(using: .utf8))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func grants(in payload: [String: Any]?) -> [[String: Any]] {
        (payload?["grants"] as? [[String: Any]]) ?? []
    }

    @Test("Extension writes a V1-shaped grant entry under the connections key")
    func extensionWritesEntry() async throws {
        let writer = StatefulMetadataWriter()
        let shim = makeShim(writer: writer)

        await shim.recordExtension(
            conversationId: "conv-1",
            abilityId: "googlecalendar",
            agentInboxId: "agent-1",
            bundleIds: ["calendar.events"]
        )

        let payload = try payloadObject(from: writer, conversationId: "conv-1")
        let written = grants(in: payload)
        #expect(written.count == 1)
        let entry = try #require(written.first)
        #expect(entry["id"] as? String == "grant_v2_14.googlecalendar_6.conv-1_7.agent-1")
        #expect(entry["service"] as? String == "googlecalendar")
        #expect(entry["grantedToInboxId"] as? String == "agent-1")
        #expect(entry["senderId"] as? String == "my-inbox")
        #expect(entry["provider"] as? String == "composio")
        #expect(entry["scope"] as? String == "conversation")
        #expect(entry["composioEntityId"] as? String == "")
        #expect(entry["composioConnectionId"] as? String == "")
    }

    @Test("Re-extending the same (service, agent) upserts the shim entry instead of duplicating")
    func extensionUpserts() async throws {
        let writer = StatefulMetadataWriter()
        let shim = makeShim(writer: writer)

        await shim.recordExtension(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1", bundleIds: ["calendar.events"])
        await shim.recordExtension(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1", bundleIds: ["calendar.events", "calendar.availability"])

        let payload = try payloadObject(from: writer, conversationId: "conv-1")
        #expect(grants(in: payload).count == 1)
    }

    @Test("Components containing the separator cannot collide or cross-delete")
    func separatorComponentsDoNotCollide() async throws {
        let writer = StatefulMetadataWriter()
        let shim = makeShim(writer: writer)

        // Under a plain underscore join both tuples would share one id,
        // so the second upsert would replace the first and the withdrawal
        // below would delete the survivor.
        await shim.recordExtension(conversationId: "c", abilityId: "a", agentInboxId: "c_d", bundleIds: [])
        await shim.recordExtension(conversationId: "c", abilityId: "a_c", agentInboxId: "d", bundleIds: [])

        let payload = try payloadObject(from: writer, conversationId: "c")
        #expect(grants(in: payload).count == 2)

        await shim.recordWithdrawal(conversationId: "c", abilityId: "a", agentInboxId: "c_d")
        let afterWithdrawal = try payloadObject(from: writer, conversationId: "c")
        let remaining = grants(in: afterWithdrawal)
        #expect(remaining.count == 1)
        #expect(remaining.first?["service"] as? String == "a_c")
    }

    @Test("Distinct agents and services keep separate entries")
    func distinctEntriesCoexist() async throws {
        let writer = StatefulMetadataWriter()
        let shim = makeShim(writer: writer)

        await shim.recordExtension(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1", bundleIds: [])
        await shim.recordExtension(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-2", bundleIds: [])
        await shim.recordExtension(conversationId: "conv-1", abilityId: "spotify", agentInboxId: "agent-1", bundleIds: [])

        let payload = try payloadObject(from: writer, conversationId: "conv-1")
        #expect(grants(in: payload).count == 3)
    }

    @Test("A same-toolkit V1 grant survives shim upsert and withdrawal, unknown fields verbatim")
    func v1GrantCoexistsUntouched() async throws {
        let writer = StatefulMetadataWriter()
        writer.seed(conversationId: "conv-1", inboxId: "my-inbox", connectionsJson: v1PayloadJson)
        let shim = makeShim(writer: writer)

        // Upsert next to the V1 entry for the same (service, agent).
        await shim.recordExtension(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1", bundleIds: [])
        var payload = try payloadObject(from: writer, conversationId: "conv-1")
        #expect(grants(in: payload).count == 2)
        #expect(payload?["customTopLevel"] as? String == "keep")

        // Withdrawal removes only the shim-owned entry.
        await shim.recordWithdrawal(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1")
        payload = try payloadObject(from: writer, conversationId: "conv-1")
        let remaining = grants(in: payload)
        #expect(remaining.count == 1)
        let v1Entry = try #require(remaining.first)
        #expect(v1Entry["id"] as? String == "grant_conn1_conv-1_agent-1")
        #expect(v1Entry["composioEntityId"] as? String == "comp-entity-1")
        #expect((v1Entry["futureField"] as? [String: Any])?["nested"] as? Bool == true)
        #expect(payload?["customTopLevel"] as? String == "keep")
    }

    @Test("Withdrawal removes only the matching entry; the last shim removal clears the key")
    func withdrawalRemoves() async throws {
        let writer = StatefulMetadataWriter()
        let shim = makeShim(writer: writer)

        await shim.recordExtension(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1", bundleIds: [])
        await shim.recordExtension(conversationId: "conv-1", abilityId: "spotify", agentInboxId: "agent-1", bundleIds: [])

        await shim.recordWithdrawal(conversationId: "conv-1", abilityId: "spotify", agentInboxId: "agent-1")
        let remaining = grants(in: try payloadObject(from: writer, conversationId: "conv-1"))
        #expect(remaining.map { $0["service"] as? String } == ["googlecalendar"])

        await shim.recordWithdrawal(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1")
        let metadata = writer.metadata(conversationId: "conv-1", inboxId: "my-inbox")
        #expect(metadata[ConversationScopedMetadataKey.connections] == nil)
    }

    @Test("Withdrawing an ability with no shim entry leaves a V1 payload byte-identical")
    func withdrawalWithoutShimEntryIsNoOp() async throws {
        let writer = StatefulMetadataWriter()
        writer.seed(conversationId: "conv-1", inboxId: "my-inbox", connectionsJson: v1PayloadJson)
        let shim = makeShim(writer: writer)

        await shim.recordWithdrawal(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1")
        let metadata = writer.metadata(conversationId: "conv-1", inboxId: "my-inbox")
        #expect(metadata[ConversationScopedMetadataKey.connections]?.stringValue == v1PayloadJson)
    }

    @Test("An undecodable existing payload is left untouched and the shim write is skipped")
    func malformedPayloadSkipped() async throws {
        let writer = StatefulMetadataWriter()
        writer.seed(conversationId: "conv-1", inboxId: "my-inbox", connectionsJson: "not json at all")
        let shim = makeShim(writer: writer)

        await shim.recordExtension(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1", bundleIds: [])
        var metadata = writer.metadata(conversationId: "conv-1", inboxId: "my-inbox")
        #expect(metadata[ConversationScopedMetadataKey.connections]?.stringValue == "not json at all")

        await shim.recordWithdrawal(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1")
        metadata = writer.metadata(conversationId: "conv-1", inboxId: "my-inbox")
        #expect(metadata[ConversationScopedMetadataKey.connections]?.stringValue == "not json at all")
    }

    @Test("A grants key of an unexpected shape is also left untouched")
    func unexpectedGrantsShapeSkipped() async throws {
        let writer = StatefulMetadataWriter()
        let oddPayload = #"{"grants":"not-an-array","version":1}"#
        writer.seed(conversationId: "conv-1", inboxId: "my-inbox", connectionsJson: oddPayload)
        let shim = makeShim(writer: writer)

        await shim.recordExtension(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1", bundleIds: [])
        let metadata = writer.metadata(conversationId: "conv-1", inboxId: "my-inbox")
        #expect(metadata[ConversationScopedMetadataKey.connections]?.stringValue == oddPayload)
    }

    @Test("A publish failure is swallowed (best-effort)")
    func publishFailureSwallowed() async throws {
        let writer = StatefulMetadataWriter()
        writer.updateError = CancellationError()
        let shim = makeShim(writer: writer)
        await shim.recordExtension(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1", bundleIds: [])
        #expect(writer.store.isEmpty)
    }
}

@Suite("LiveAbilitiesService V1 awareness shim gating")
struct LiveAbilitiesServiceShimGatingTests {
    private final class ExtendStubAPIClient: TestStubAPIClient, @unchecked Sendable {
        override func putConversationAbility(
            conversationId: String,
            abilityId: String,
            agentInboxId: String,
            bundleIds: [String],
            extendedByInboxId: String?
        ) async throws -> AbilitiesAPI.ConversationAbilityEntry {
            AbilitiesAPI.ConversationAbilityEntry(
                abilityId: abilityId,
                conversationId: conversationId,
                agentInboxId: agentInboxId,
                bundleIds: bundleIds,
                extendedByInboxId: extendedByInboxId,
                extendedByMe: true,
                status: .active,
                createdAt: Date(),
                updatedAt: Date()
            )
        }

        override func deleteConversationAbility(conversationId: String, abilityId: String, agentInboxId: String) async throws {}
    }

    private final class FailingExtendAPIClient: TestStubAPIClient, @unchecked Sendable {
        override func putConversationAbility(
            conversationId: String,
            abilityId: String,
            agentInboxId: String,
            bundleIds: [String],
            extendedByInboxId: String?
        ) async throws -> AbilitiesAPI.ConversationAbilityEntry {
            throw AbilitiesAPI.EndpointError.needsEntitlement
        }
    }

    @Test("Extend and withdraw invoke the shim only while the toggle reads on")
    func shimGating() async throws {
        let shim = RecordingShimWriter()
        let toggle = LockedFlag(initial: false)
        let service = LiveAbilitiesService(
            apiClient: ExtendStubAPIClient(),
            callbackURLScheme: "convos-testing",
            cache: nil,
            shimWriter: shim,
            isShimEnabled: { toggle.read() }
        )

        try await service.extendAbility(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1", bundleIds: ["calendar.events"])
        #expect(shim.extensions.isEmpty)

        toggle.set(true)
        try await service.extendAbility(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1", bundleIds: ["calendar.events"])
        #expect(shim.extensions.count == 1)
        #expect(shim.extensions.first?.bundleIds == ["calendar.events"])

        try await service.withdrawAbility(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1")
        #expect(shim.withdrawals.count == 1)
    }

    @Test("A failed extend never reaches the shim")
    func failedExtendSkipsShim() async throws {
        let shim = RecordingShimWriter()
        let service = LiveAbilitiesService(
            apiClient: FailingExtendAPIClient(),
            callbackURLScheme: "convos-testing",
            cache: nil,
            shimWriter: shim,
            isShimEnabled: { true }
        )
        await #expect(throws: AbilitiesServiceError.needsEntitlement(abilityId: "googlecalendar")) {
            try await service.extendAbility(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1", bundleIds: ["calendar.events"])
        }
        #expect(shim.extensions.isEmpty)
    }
}

/// Tiny lock-guarded flag so the `@Sendable` gate closure can observe
/// test-driven flips without data races.
private final class LockedFlag: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var value: Bool

    init(initial: Bool) {
        self.value = initial
    }

    func read() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}
