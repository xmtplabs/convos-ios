@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("ProfileBackfill", .serialized)
struct ProfileBackfillTests {
    private let salt = Data(repeating: 1, count: 32)
    private let nonce = Data(repeating: 2, count: 12)
    private let key = Data(repeating: 3, count: 32)

    /// Builds a queue with just the legacy `memberProfile` columns the
    /// `DBMemberProfile` record decodes - enough to seed rows and read them back.
    private func makeMemberProfileQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.create(table: "memberProfile") { t in
                t.column("conversationId", .text).notNull()
                t.column("inboxId", .text).notNull()
                t.column("name", .text)
                t.column("avatar", .text)
                t.column("avatarSalt", .blob)
                t.column("avatarNonce", .blob)
                t.column("avatarKey", .blob)
                t.column("avatarLastRenewed", .datetime)
                t.column("imageSourceAssetIdentifier", .text)
                t.column("imageSourceContentDigest", .text)
                t.column("memberKind", .text)
                t.column("metadata", .jsonText)
                t.primaryKey(["conversationId", "inboxId"])
            }
        }
        return queue
    }

    private func seed(_ queue: DatabaseQueue, _ rows: [DBMemberProfile]) throws {
        try queue.write { db in
            for row in rows {
                try row.save(db)
            }
        }
    }

    @Test("migrates member rows into identity, avatar, and self stores")
    func backfillsAll() async throws {
        let queue = try makeMemberProfileQueue()
        try seed(queue, [
            DBMemberProfile(conversationId: "c1", inboxId: "alice", name: "Alice", avatar: "u", avatarSalt: salt, avatarNonce: nonce, avatarKey: key),
            DBMemberProfile(conversationId: "c1", inboxId: "me", name: "Me", avatar: nil),
        ])
        let profileStore = InMemoryProfileStore()
        let selfStore = InMemorySelfProfileStore()
        let backfill = ProfileBackfill(databaseReader: queue, profileStore: profileStore, selfProfileStore: selfStore, selfInboxId: "me")

        try await backfill.run()

        let alice = try await profileStore.identity(inboxId: "alice")
        #expect(alice?.name == "Alice")
        #expect(alice?.profileSource == .contact)
        let aliceAvatar = try await profileStore.avatar(inboxId: "alice", conversationId: "c1")
        #expect(aliceAvatar?.url == "u")

        // The current user's identity goes to the self store, not the profile store.
        let me = try await selfStore.load()
        #expect(me?.name == "Me")
        let meProfile = try await profileStore.identity(inboxId: "me")
        #expect(meProfile == nil)
    }

    @Test("is idempotent - a second run produces the same result")
    func idempotent() async throws {
        let queue = try makeMemberProfileQueue()
        try seed(queue, [
            DBMemberProfile(conversationId: "c1", inboxId: "alice", name: "Alice", avatar: "u", avatarSalt: salt, avatarNonce: nonce, avatarKey: key),
        ])
        let profileStore = InMemoryProfileStore()
        let selfStore = InMemorySelfProfileStore()
        let backfill = ProfileBackfill(databaseReader: queue, profileStore: profileStore, selfProfileStore: selfStore, selfInboxId: "me")

        try await backfill.run()
        try await backfill.run()

        let identities = try await profileStore.allIdentities()
        #expect(identities.count == 1)
        let avatars = try await profileStore.allAvatars()
        #expect(avatars.count == 1)
    }

    @Test("never overwrites a value already set by a real event")
    func doesNotClobberRealData() async throws {
        let queue = try makeMemberProfileQueue()
        try seed(queue, [
            DBMemberProfile(conversationId: "c1", inboxId: "alice", name: "Legacy", avatar: nil),
        ])
        let profileStore = InMemoryProfileStore()
        // A real profileUpdate already landed for alice.
        try await profileStore.saveIdentity(
            DBProfile(inboxId: "alice", name: "Real", profileSource: .profileUpdate, updatedAt: Date(timeIntervalSince1970: 100))
        )
        let backfill = ProfileBackfill(databaseReader: queue, profileStore: profileStore, selfProfileStore: InMemorySelfProfileStore(), selfInboxId: "me")

        try await backfill.run()

        let alice = try await profileStore.identity(inboxId: "alice")
        #expect(alice?.name == "Real")
        #expect(alice?.profileSource == .profileUpdate)
    }

    @Test("mirror(_:) populates the stores from provided rows")
    func mirrorFromRows() async throws {
        let profileStore = InMemoryProfileStore()
        let selfStore = InMemorySelfProfileStore()
        let backfill = ProfileBackfill(databaseReader: try DatabaseQueue(), profileStore: profileStore, selfProfileStore: selfStore, selfInboxId: "me")

        try await backfill.mirror([
            DBMemberProfile(conversationId: "c1", inboxId: "alice", name: "Alice", avatar: "u", avatarSalt: salt, avatarNonce: nonce, avatarKey: key),
        ])

        let alice = try await profileStore.identity(inboxId: "alice")
        #expect(alice?.name == "Alice")
        let avatar = try await profileStore.avatar(inboxId: "alice", conversationId: "c1")
        #expect(avatar?.url == "u")
    }

    @Test("mirror(_:) tracks a changed value on re-run")
    func mirrorTracksChange() async throws {
        let profileStore = InMemoryProfileStore()
        let backfill = ProfileBackfill(databaseReader: try DatabaseQueue(), profileStore: profileStore, selfProfileStore: InMemorySelfProfileStore(), selfInboxId: "me")

        try await backfill.mirror([DBMemberProfile(conversationId: "c1", inboxId: "alice", name: "Alice", avatar: nil)])
        try await backfill.mirror([DBMemberProfile(conversationId: "c1", inboxId: "alice", name: "Alicia", avatar: nil)])

        let alice = try await profileStore.identity(inboxId: "alice")
        #expect(alice?.name == "Alicia")
    }

    @Test("does nothing when there are no legacy rows")
    func emptyIsNoop() async throws {
        let queue = try makeMemberProfileQueue()
        let profileStore = InMemoryProfileStore()
        let selfStore = InMemorySelfProfileStore()
        let backfill = ProfileBackfill(databaseReader: queue, profileStore: profileStore, selfProfileStore: selfStore, selfInboxId: "me")

        try await backfill.run()

        let identities = try await profileStore.allIdentities()
        #expect(identities.isEmpty)
        let me = try await selfStore.load()
        #expect(me == nil)
    }
}
