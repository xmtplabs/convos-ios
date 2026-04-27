@testable import ConvosConnections
import Foundation
import Testing

@Suite("InMemoryEnablementStore")
struct InMemoryEnablementStoreTests {
    @Test("toggling enablement persists across reads")
    func togglePersists() async {
        let store = InMemoryEnablementStore()
        let isEnabledBefore = await store.isEnabled(kind: .health, conversationId: "conv-1")
        #expect(isEnabledBefore == false)

        await store.setEnabled(true, kind: .health, conversationId: "conv-1")
        let isEnabledAfter = await store.isEnabled(kind: .health, conversationId: "conv-1")
        #expect(isEnabledAfter == true)

        await store.setEnabled(false, kind: .health, conversationId: "conv-1")
        let isEnabledFinal = await store.isEnabled(kind: .health, conversationId: "conv-1")
        #expect(isEnabledFinal == false)
    }

    @Test("conversationIds(enabledFor:) returns only matching kind")
    func filterByKind() async {
        let store = InMemoryEnablementStore()
        await store.setEnabled(true, kind: .health, conversationId: "conv-a")
        await store.setEnabled(true, kind: .health, conversationId: "conv-b")
        await store.setEnabled(true, kind: .calendar, conversationId: "conv-c")

        let healthConversations = await store.conversationIds(enabledFor: .health)
        #expect(healthConversations == ["conv-a", "conv-b"])

        let calendarConversations = await store.conversationIds(enabledFor: .calendar)
        #expect(calendarConversations == ["conv-c"])

        let photosConversations = await store.conversationIds(enabledFor: .photos)
        #expect(photosConversations.isEmpty)
    }

    @Test("allEnablements returns a stable sort order")
    func allEnablementsIsSorted() async {
        let store = InMemoryEnablementStore()
        await store.setEnabled(true, kind: .photos, conversationId: "z")
        await store.setEnabled(true, kind: .health, conversationId: "b")
        await store.setEnabled(true, kind: .health, conversationId: "a")

        let all = await store.allEnablements()
        #expect(all.map(\.conversationId) == ["a", "b", "z"])
    }

    @Test("per-capability enablement is independent")
    func perCapabilityIndependence() async {
        let store = InMemoryEnablementStore()
        await store.setEnabled(true, kind: .calendar, capability: .writeCreate, conversationId: "c")
        let readEnabled = await store.isEnabled(kind: .calendar, capability: .read, conversationId: "c")
        let createEnabled = await store.isEnabled(kind: .calendar, capability: .writeCreate, conversationId: "c")
        let deleteEnabled = await store.isEnabled(kind: .calendar, capability: .writeDelete, conversationId: "c")
        #expect(readEnabled == false)
        #expect(createEnabled == true)
        #expect(deleteEnabled == false)
    }

    @Test("legacy read methods route to the .read capability")
    func legacyReadShimsUseReadCapability() async {
        let store = InMemoryEnablementStore()
        await store.setEnabled(true, kind: .calendar, conversationId: "c")
        let read = await store.isEnabled(kind: .calendar, capability: .read, conversationId: "c")
        let writeCreate = await store.isEnabled(kind: .calendar, capability: .writeCreate, conversationId: "c")
        #expect(read == true)
        #expect(writeCreate == false)
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
        await store.setEnabled(true, kind: .calendar, capability: .writeDelete, conversationId: "c")
        await store.setEnabled(true, kind: .calendar, capability: .read, conversationId: "c")
        await store.setEnabled(true, kind: .calendar, capability: .writeCreate, conversationId: "c")

        let all = await store.allEnablements()
        let capabilities = all.map(\.capability)
        // Sorted by raw value: "read" < "write_create" < "write_delete"
        #expect(capabilities == [.read, .writeCreate, .writeDelete])
    }
}
