@testable import ConvosCore
import Foundation
import Testing

/// Stateful metadata writer: keeps a persistent per-(conversation, inbox)
/// map across updates so merge behavior (upsert over existing entries,
/// key removal on empty payload) is observable, unlike the empty-map
/// `MockProfileMetadataWriter`.
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
    private func makeShim(writer: StatefulMetadataWriter, inboxId: String = "my-inbox") -> AbilityV1AwarenessShimWriter {
        AbilityV1AwarenessShimWriter(
            profileMetadataWriter: writer,
            myInboxIdProvider: { inboxId }
        )
    }

    private func payload(from writer: StatefulMetadataWriter, conversationId: String, inboxId: String = "my-inbox") throws -> CloudConnectionsMetadataPayload? {
        let metadata = writer.metadata(conversationId: conversationId, inboxId: inboxId)
        guard let json = metadata[ConversationScopedMetadataKey.connections]?.stringValue else { return nil }
        return try CloudConnectionsMetadataPayload.fromJsonString(json)
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

        let payload = try #require(try payload(from: writer, conversationId: "conv-1"))
        #expect(payload.grants.count == 1)
        let entry = try #require(payload.grants.first)
        #expect(entry.service == "googlecalendar")
        #expect(entry.grantedToInboxId == "agent-1")
        #expect(entry.senderId == "my-inbox")
        #expect(entry.provider == "composio")
        #expect(entry.scope == "conversation")
        #expect(entry.composioEntityId.isEmpty)
        #expect(entry.composioConnectionId.isEmpty)
    }

    @Test("Re-extending the same (service, agent) upserts instead of duplicating")
    func extensionUpserts() async throws {
        let writer = StatefulMetadataWriter()
        let shim = makeShim(writer: writer)

        await shim.recordExtension(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1", bundleIds: ["calendar.events"])
        await shim.recordExtension(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1", bundleIds: ["calendar.events", "calendar.availability"])

        let payload = try #require(try payload(from: writer, conversationId: "conv-1"))
        #expect(payload.grants.count == 1)
    }

    @Test("Distinct agents and services keep separate entries")
    func distinctEntriesCoexist() async throws {
        let writer = StatefulMetadataWriter()
        let shim = makeShim(writer: writer)

        await shim.recordExtension(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1", bundleIds: [])
        await shim.recordExtension(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-2", bundleIds: [])
        await shim.recordExtension(conversationId: "conv-1", abilityId: "spotify", agentInboxId: "agent-1", bundleIds: [])

        let payload = try #require(try payload(from: writer, conversationId: "conv-1"))
        #expect(payload.grants.count == 3)
    }

    @Test("Withdrawal removes only the matching entry; the last removal clears the key")
    func withdrawalRemoves() async throws {
        let writer = StatefulMetadataWriter()
        let shim = makeShim(writer: writer)

        await shim.recordExtension(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1", bundleIds: [])
        await shim.recordExtension(conversationId: "conv-1", abilityId: "spotify", agentInboxId: "agent-1", bundleIds: [])

        await shim.recordWithdrawal(conversationId: "conv-1", abilityId: "spotify", agentInboxId: "agent-1")
        let remaining = try #require(try payload(from: writer, conversationId: "conv-1"))
        #expect(remaining.grants.map(\.service) == ["googlecalendar"])

        await shim.recordWithdrawal(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1")
        let metadata = writer.metadata(conversationId: "conv-1", inboxId: "my-inbox")
        #expect(metadata[ConversationScopedMetadataKey.connections] == nil)
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
            try await service.extendAbility(conversationId: "conv-1", abilityId: "googlecalendar", agentInboxId: "agent-1", bundleIds: [])
        }
        #expect(shim.extensions.isEmpty)
    }
}

/// Tiny lock-guarded flag so the `@Sendable` gate closure can observe
/// test-driven flips without data races.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
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
