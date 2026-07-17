@testable import ConvosConnections
import Foundation
import Testing

@Suite("InMemoryEnablementStore")
struct InMemoryEnablementStoreTests {
    private static let agent: String = "agent-1"

    @Test("toggling enablement persists across reads")
    func togglePersists() async {
        let store = InMemoryEnablementStore()
        let isEnabledBefore = await store.isEnabled(
            kind: .health,
            capability: .read,
            conversationId: "conv-1",
            grantedToInboxId: Self.agent
        )
        #expect(isEnabledBefore == false)

        await store.setEnabled(
            true,
            kind: .health,
            capability: .read,
            conversationId: "conv-1",
            grantedToInboxId: Self.agent
        )
        let isEnabledAfter = await store.isEnabled(
            kind: .health,
            capability: .read,
            conversationId: "conv-1",
            grantedToInboxId: Self.agent
        )
        #expect(isEnabledAfter == true)

        await store.setEnabled(
            false,
            kind: .health,
            capability: .read,
            conversationId: "conv-1",
            grantedToInboxId: Self.agent
        )
        let isEnabledFinal = await store.isEnabled(
            kind: .health,
            capability: .read,
            conversationId: "conv-1",
            grantedToInboxId: Self.agent
        )
        #expect(isEnabledFinal == false)
    }

    @Test("conversationIds(enabledFor:capability:) returns only matching kind")
    func filterByKind() async {
        let store = InMemoryEnablementStore()
        await store.setEnabled(
            true,
            kind: .health,
            capability: .read,
            conversationId: "conv-a",
            grantedToInboxId: Self.agent
        )
        await store.setEnabled(
            true,
            kind: .health,
            capability: .read,
            conversationId: "conv-b",
            grantedToInboxId: Self.agent
        )
        await store.setEnabled(
            true,
            kind: .calendar,
            capability: .read,
            conversationId: "conv-c",
            grantedToInboxId: Self.agent
        )

        let healthConversations = await store.conversationIds(
            enabledFor: .health,
            capability: .read
        )
        #expect(healthConversations == ["conv-a", "conv-b"])

        let calendarConversations = await store.conversationIds(
            enabledFor: .calendar,
            capability: .read
        )
        #expect(calendarConversations == ["conv-c"])

        let photosConversations = await store.conversationIds(
            enabledFor: .photos,
            capability: .read
        )
        #expect(photosConversations.isEmpty)
    }

    @Test("allEnablements returns a stable sort order")
    func allEnablementsIsSorted() async {
        let store = InMemoryEnablementStore()
        await store.setEnabled(
            true,
            kind: .photos,
            capability: .read,
            conversationId: "z",
            grantedToInboxId: Self.agent
        )
        await store.setEnabled(
            true,
            kind: .health,
            capability: .read,
            conversationId: "b",
            grantedToInboxId: Self.agent
        )
        await store.setEnabled(
            true,
            kind: .health,
            capability: .read,
            conversationId: "a",
            grantedToInboxId: Self.agent
        )

        let all = await store.allEnablements()
        #expect(all.map(\.conversationId) == ["a", "b", "z"])
    }

    @Test("per-capability enablement is independent")
    func perCapabilityIndependence() async {
        let store = InMemoryEnablementStore()
        await store.setEnabled(
            true,
            kind: .calendar,
            capability: .writeCreate,
            conversationId: "c",
            grantedToInboxId: Self.agent
        )
        let readEnabled = await store.isEnabled(
            kind: .calendar,
            capability: .read,
            conversationId: "c",
            grantedToInboxId: Self.agent
        )
        let createEnabled = await store.isEnabled(
            kind: .calendar,
            capability: .writeCreate,
            conversationId: "c",
            grantedToInboxId: Self.agent
        )
        let deleteEnabled = await store.isEnabled(
            kind: .calendar,
            capability: .writeDelete,
            conversationId: "c",
            grantedToInboxId: Self.agent
        )
        #expect(readEnabled == false)
        #expect(createEnabled == true)
        #expect(deleteEnabled == false)
    }

    @Test("per-agent enablement is independent across agents")
    func perAgentIndependence() async {
        let store = InMemoryEnablementStore()
        await store.setEnabled(
            true,
            kind: .calendar,
            capability: .read,
            conversationId: "c",
            grantedToInboxId: "agent-1"
        )
        let agent1 = await store.isEnabled(
            kind: .calendar,
            capability: .read,
            conversationId: "c",
            grantedToInboxId: "agent-1"
        )
        let agent2 = await store.isEnabled(
            kind: .calendar,
            capability: .read,
            conversationId: "c",
            grantedToInboxId: "agent-2"
        )
        #expect(agent1 == true)
        #expect(agent2 == false)
    }

    @Test("alwaysConfirmWrites round-trips")
    func alwaysConfirmRoundTrips() async {
        let store = InMemoryEnablementStore()
        var initial = await store.alwaysConfirmWrites(kind: .calendar, conversationId: "c")
        #expect(initial == false)
        await store.setAlwaysConfirmWrites(true, kind: .calendar, conversationId: "c")
        var after = await store.alwaysConfirmWrites(kind: .calendar, conversationId: "c")
        #expect(after == true)
        await store.setAlwaysConfirmWrites(false, kind: .calendar, conversationId: "c")
        after = await store.alwaysConfirmWrites(kind: .calendar, conversationId: "c")
        #expect(after == false)
        _ = initial
    }

    @Test("allEnablements includes every capability sorted deterministically")
    func allEnablementsSortsEveryCapability() async {
        let store = InMemoryEnablementStore()
        await store.setEnabled(
            true,
            kind: .calendar,
            capability: .writeDelete,
            conversationId: "c",
            grantedToInboxId: Self.agent
        )
        await store.setEnabled(
            true,
            kind: .calendar,
            capability: .read,
            conversationId: "c",
            grantedToInboxId: Self.agent
        )
        await store.setEnabled(
            true,
            kind: .calendar,
            capability: .writeCreate,
            conversationId: "c",
            grantedToInboxId: Self.agent
        )

        let all = await store.allEnablements()
        let capabilities = all.map(\.capability)
        // Sorted by raw value: "read" < "write_create" < "write_delete"
        #expect(capabilities == [.read, .writeCreate, .writeDelete])
    }
}
