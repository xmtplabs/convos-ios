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
        let queue = try ProfileStoreTestSupport.makeQueue()
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
    }
}
