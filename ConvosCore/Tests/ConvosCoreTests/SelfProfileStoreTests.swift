@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Contract tests for `SelfProfileStoreProtocol`, run against both
/// implementations. Backed by the `myProfile` table; the GRDB store resolves the
/// current inbox via its provider.
@Suite("Self profile store")
struct SelfProfileStoreTests {
    @Test("GRDB implementation satisfies the contract")
    func grdbContract() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["convo-a", "convo-b"])
        let store = GRDBSelfProfileStore(
            databaseWriter: queue,
            databaseReader: queue,
            selfInboxIdProvider: { "me" }
        )
        try await runContract(store)
    }

    @Test("in-memory implementation satisfies the contract")
    func inMemoryContract() async throws {
        try await runContract(InMemorySelfProfileStore())
    }

    private func runContract(_ store: any SelfProfileStoreProtocol) async throws {
        let t = Date(timeIntervalSince1970: 1)
        let empty = try await store.load()
        #expect(empty == nil)

        try await store.save(DBMyProfile(inboxId: "me", name: "Me", updatedAt: t))
        let loaded = try await store.load()
        #expect(loaded?.name == "Me")

        try await store.save(DBMyProfile(inboxId: "me", name: "Me Renamed", updatedAt: t))
        let updated = try await store.load()
        #expect(updated?.name == "Me Renamed")

        try await store.clear()
        let cleared = try await store.load()
        #expect(cleared == nil)

        // Scoped metadata: per-conversation maps are independent of each other
        // and of the global profile row.
        let noScoped = try await store.scopedMetadata(inboxId: "me", conversationId: "convo-a")
        #expect(noScoped == nil)

        try await store.saveScopedMetadata(["connections": .string("grants-a")], inboxId: "me", conversationId: "convo-a", updatedAt: t)
        try await store.saveScopedMetadata(["connections": .string("grants-b")], inboxId: "me", conversationId: "convo-b", updatedAt: t)
        let scopedA = try await store.scopedMetadata(inboxId: "me", conversationId: "convo-a")
        let scopedB = try await store.scopedMetadata(inboxId: "me", conversationId: "convo-b")
        #expect(scopedA?["connections"] == .string("grants-a"))
        #expect(scopedB?["connections"] == .string("grants-b"))

        // Overwrite replaces the map for that conversation only.
        try await store.saveScopedMetadata(["timezone": .string("Europe/Paris")], inboxId: "me", conversationId: "convo-a", updatedAt: t)
        let replaced = try await store.scopedMetadata(inboxId: "me", conversationId: "convo-a")
        #expect(replaced?["timezone"] == .string("Europe/Paris"))
        #expect(replaced?["connections"] == nil)
        let untouched = try await store.scopedMetadata(inboxId: "me", conversationId: "convo-b")
        #expect(untouched?["connections"] == .string("grants-b"))

        // Nil and empty maps delete the row.
        try await store.saveScopedMetadata(nil, inboxId: "me", conversationId: "convo-a", updatedAt: t)
        let deleted = try await store.scopedMetadata(inboxId: "me", conversationId: "convo-a")
        #expect(deleted == nil)
        try await store.saveScopedMetadata([:], inboxId: "me", conversationId: "convo-b", updatedAt: t)
        let emptied = try await store.scopedMetadata(inboxId: "me", conversationId: "convo-b")
        #expect(emptied == nil)

        // clear() drops the scoped rows along with the profile, so a cleared
        // self never resurfaces a previous account's grants or timezone.
        try await store.saveScopedMetadata(["connections": .string("grants")], inboxId: "me", conversationId: "convo-a", updatedAt: t)
        try await store.clear()
        let scopedAfterClear = try await store.scopedMetadata(inboxId: "me", conversationId: "convo-a")
        #expect(scopedAfterClear == nil)

        // update(edit:) starts from a blank row when none exists.
        let created = try await store.update(SelfProfileEdit(name: .set("Fresh")), updatedAt: t)
        #expect(created.name == "Fresh")

        // update(edit:) is an atomic read-apply-write: two concurrent edits to
        // disjoint fields must both land (a snapshot-based read-modify-write
        // would let one silently revert the other).
        async let nameEdit = store.update(SelfProfileEdit(name: .set("Renamed")), updatedAt: t)
        async let metadataEdit = store.update(SelfProfileEdit(metadata: .set(["k": .string("v")])), updatedAt: t)
        _ = try await (nameEdit, metadataEdit)
        let afterConcurrent = try await store.load()
        #expect(afterConcurrent?.name == "Renamed")
        #expect(afterConcurrent?.metadata?["k"] == .string("v"))
    }
}
