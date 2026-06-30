@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Contract tests for `ProfileStoreProtocol`, run against both the GRDB-backed
/// and in-memory implementations so the two stay behaviorally identical.
@Suite("Profile store")
struct ProfileStoreTests {
    @Test("GRDB implementation satisfies the contract")
    func grdbContract() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["conv-1", "conv-2"])
        let store = GRDBProfileStore(databaseWriter: queue, databaseReader: queue)
        try await runContract(store)
    }

    @Test("in-memory implementation satisfies the contract")
    func inMemoryContract() async throws {
        try await runContract(InMemoryProfileStore())
    }

    private func runContract(_ store: any ProfileStoreProtocol) async throws {
        let t = Date(timeIntervalSince1970: 1)
        try await store.saveIdentity(DBProfile(inboxId: "inbox-1", name: "Alice", profileSource: .profileUpdate, updatedAt: t))
        try await store.saveIdentity(DBProfile(inboxId: "inbox-2", name: "Bob", profileSource: .profileUpdate, updatedAt: t))

        let alice = try await store.identity(inboxId: "inbox-1")
        #expect(alice?.name == "Alice")
        let both = try await store.identities(inboxIds: ["inbox-1", "inbox-2"])
        #expect(both.count == 2)
        let allIdentities = try await store.allIdentities()
        #expect(allIdentities.count == 2)

        try await store.saveAvatar(DBProfileAvatar(inboxId: "inbox-1", conversationId: "conv-1", url: "a", profileSource: .profileUpdate, updatedAt: t))
        try await store.saveAvatar(DBProfileAvatar(inboxId: "inbox-1", conversationId: "conv-2", url: "b", profileSource: .profileUpdate, updatedAt: t))
        try await store.saveAvatar(DBProfileAvatar(inboxId: "inbox-2", conversationId: "conv-1", url: "c", profileSource: .profileUpdate, updatedAt: t))

        let oneAvatar = try await store.avatar(inboxId: "inbox-1", conversationId: "conv-1")
        #expect(oneAvatar?.url == "a")
        let aliceAvatars = try await store.avatars(inboxId: "inbox-1")
        #expect(aliceAvatars.count == 2)
        let batchAvatars = try await store.avatars(inboxIds: ["inbox-1", "inbox-2"])
        #expect(batchAvatars.count == 3)
        let allAvatars = try await store.allAvatars()
        #expect(allAvatars.count == 3)

        try await store.deleteAvatars(conversationId: "conv-1")
        let afterConvDelete = try await store.allAvatars()
        #expect(afterConvDelete.count == 1)
        let survivor = try await store.avatar(inboxId: "inbox-1", conversationId: "conv-2")
        #expect(survivor?.url == "b")

        try await store.deleteProfile(inboxId: "inbox-1")
        let goneIdentity = try await store.identity(inboxId: "inbox-1")
        #expect(goneIdentity == nil)
        let remainingIdentities = try await store.allIdentities()
        #expect(remainingIdentities.count == 1)
        let remainingAvatars = try await store.allAvatars()
        #expect(remainingAvatars.isEmpty)

        try await store.deleteAll()
        let empty = try await store.allIdentities()
        #expect(empty.isEmpty)
    }
}
