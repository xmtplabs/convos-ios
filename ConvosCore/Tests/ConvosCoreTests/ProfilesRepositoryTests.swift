@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("ProfilesRepository")
struct ProfilesRepositoryTests {
    private let salt = Data(repeating: 1, count: 32)
    private let nonce = Data(repeating: 2, count: 12)
    private let key = Data(repeating: 3, count: 32)

    private func makeRepository(
        profileStore: any ProfileStoreProtocol = InMemoryProfileStore(),
        selfProfileStore: any SelfProfileStoreProtocol = InMemorySelfProfileStore(),
        publishStore: any ProfilePublishStoreProtocol = InMemoryProfilePublishStore(),
        databaseReader: (any DatabaseReader)? = nil,
        selfInboxId: String = "me"
    ) throws -> ProfilesRepository {
        ProfilesRepository(
            profileStore: profileStore,
            selfProfileStore: selfProfileStore,
            publishStore: publishStore,
            databaseReader: try databaseReader ?? DatabaseQueue(),
            selfInboxIdProvider: { selfInboxId }
        )
    }

    private func setAvatar(_ url: String) -> IncomingAvatar {
        .set(url: url, salt: salt, nonce: nonce, key: key)
    }

    private func event(
        inboxId: String,
        conversationId: String,
        name: String?,
        avatar: IncomingAvatar,
        source: ProfileSource = .profileUpdate,
        sentAt: Date
    ) -> ProfileDomainEvent {
        ProfileDomainEvent(
            inboxId: inboxId,
            conversationId: conversationId,
            source: source,
            identity: IncomingIdentity(name: name),
            avatar: avatar,
            sentAt: sentAt
        )
    }

    @Test("apply creates identity and avatar, readable via profile()")
    func applyCreatesProfile() async throws {
        let repository = try makeRepository()
        await repository.warmUp()
        await repository.apply(event(
            inboxId: "alice", conversationId: "c1", name: "Alice",
            avatar: setAvatar("u"), sentAt: Date(timeIntervalSince1970: 1)
        ))

        let profile = await repository.profile(inboxId: "alice")
        #expect(profile.name == "Alice")
        #expect(profile.displayAvatar(for: "c1")?.url == "u")
    }

    @Test("apply ignores events authored by the current user")
    func selfEchoIgnored() async throws {
        let repository = try makeRepository(selfInboxId: "me")
        await repository.warmUp()
        await repository.apply(event(
            inboxId: "me", conversationId: "c1", name: "Myself",
            avatar: .silent, sentAt: Date(timeIntervalSince1970: 1)
        ))

        let profile = await repository.profile(inboxId: "me")
        #expect(profile.name == nil)
    }

    @Test("apply respects merge precedence end to end")
    func applyRespectsPrecedence() async throws {
        let repository = try makeRepository()
        await repository.warmUp()
        await repository.apply(event(
            inboxId: "alice", conversationId: "c1", name: "Authoritative",
            avatar: .silent, source: .profileUpdate, sentAt: Date(timeIntervalSince1970: 2)
        ))
        // A lower-source, older event must not overwrite the name.
        await repository.apply(event(
            inboxId: "alice", conversationId: "c1", name: "Snapshot",
            avatar: .silent, source: .profileSnapshot, sentAt: Date(timeIntervalSince1970: 1)
        ))

        let profile = await repository.profile(inboxId: "alice")
        #expect(profile.name == "Authoritative")
    }

    @Test("warmUp loads persisted rows into the cache")
    func warmUpLoads() async throws {
        let profileStore = InMemoryProfileStore()
        try await profileStore.saveIdentity(
            DBProfile(inboxId: "bob", name: "Bob", profileSource: .profileUpdate, updatedAt: Date(timeIntervalSince1970: 1))
        )
        let repository = try makeRepository(profileStore: profileStore)
        await repository.warmUp()

        let profile = await repository.profile(inboxId: "bob")
        #expect(profile.name == "Bob")
    }

    @Test("updateSelfProfile persists and is reflected in selfProfile()")
    func updateSelf() async throws {
        let selfStore = InMemorySelfProfileStore()
        let repository = try makeRepository(selfProfileStore: selfStore)
        await repository.warmUp()
        try await repository.updateSelfProfile(SelfProfileEdit(name: .set("Me")))

        let profile = await repository.selfProfile()
        #expect(profile?.name == "Me")
        let persisted = try await selfStore.load()
        #expect(persisted?.name == "Me")
    }

    @Test("displayAvatar falls back to the newest slot without a conversation match")
    func displayAvatarFallback() async throws {
        let repository = try makeRepository()
        await repository.warmUp()
        await repository.apply(event(
            inboxId: "alice", conversationId: "c1", name: "Alice",
            avatar: setAvatar("old"), sentAt: Date(timeIntervalSince1970: 1)
        ))
        await repository.apply(event(
            inboxId: "alice", conversationId: "c2", name: "Alice",
            avatar: setAvatar("new"), sentAt: Date(timeIntervalSince1970: 5)
        ))

        let profile = await repository.profile(inboxId: "alice")
        #expect(profile.displayAvatar(for: "c2")?.url == "new")
        #expect(profile.displayAvatar(for: nil)?.url == "new")
        #expect(profile.displayAvatar(for: "unknown")?.url == "new")
    }

    @Test("purgeConversationAvatars drops only that conversation's slots")
    func purgeAvatars() async throws {
        let repository = try makeRepository()
        await repository.warmUp()
        await repository.apply(event(
            inboxId: "alice", conversationId: "c1", name: "Alice",
            avatar: setAvatar("a"), sentAt: Date(timeIntervalSince1970: 1)
        ))
        await repository.apply(event(
            inboxId: "alice", conversationId: "c2", name: "Alice",
            avatar: setAvatar("b"), sentAt: Date(timeIntervalSince1970: 2)
        ))

        await repository.purgeConversationAvatars("c1")

        let profile = await repository.profile(inboxId: "alice")
        #expect(profile.avatars["c1"] == nil)
        #expect(profile.avatars["c2"]?.url == "b")
    }

    @Test("fetchProfile hydrates identity and avatar from the database")
    func fetchProfileHydrates() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1"])
        let time = Date(timeIntervalSince1970: 1)
        try await queue.write { db in
            try DBProfile(inboxId: "alice", name: "Alice", profileSource: .profileUpdate, updatedAt: time).save(db)
            try DBProfileAvatar(
                inboxId: "alice", conversationId: "c1", url: "u", salt: salt, nonce: nonce,
                encryptionKey: key, profileSource: .profileUpdate, updatedAt: time
            ).save(db)
        }

        let profile = try await queue.read { db in
            try ProfilesRepository.fetchProfile(db, inboxId: "alice")
        }
        #expect(profile.name == "Alice")
        #expect(profile.displayAvatar(for: "c1")?.url == "u")

        let missing = try await queue.read { db in
            try ProfilesRepository.fetchProfile(db, inboxId: "nobody")
        }
        #expect(missing.name == nil)
    }

    @Test("fetchSelfProfile reads the self row, or nil when absent")
    func fetchSelfProfileReads() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue()
        try await queue.write { db in
            try DBMyProfile(inboxId: "me", name: "Me", updatedAt: Date(timeIntervalSince1970: 1)).save(db)
        }
        let selfProfile = try await queue.read { db in
            try ProfilesRepository.fetchSelfProfile(db)
        }
        #expect(selfProfile?.name == "Me")

        let emptyQueue = try ProfileStoreTestSupport.makeQueue()
        let none = try await emptyQueue.read { db in
            try ProfilesRepository.fetchSelfProfile(db)
        }
        #expect(none == nil)
    }

    @Test("publishMyProfileToConversation skips when a self avatar slot already exists")
    func seedSkipsWhenSelfAvatarPresent() async throws {
        let profileStore = InMemoryProfileStore()
        let publishStore = InMemoryProfilePublishStore()
        try await profileStore.saveAvatar(DBProfileAvatar(
            inboxId: "me", conversationId: "c1", url: "u", salt: salt, nonce: nonce,
            encryptionKey: key, profileSource: .profileUpdate, updatedAt: Date(timeIntervalSince1970: 1)
        ))
        let repository = try makeRepository(profileStore: profileStore, publishStore: publishStore)
        await repository.warmUp()

        try await repository.publishMyProfileToConversation("c1")

        let jobs = try await publishStore.activeJobs()
        #expect(jobs.isEmpty)
    }

    @Test("publishMyProfileToConversation seeds when no self avatar slot exists")
    func seedRunsWhenNoSelfAvatar() async throws {
        let publishStore = InMemoryProfilePublishStore()
        let repository = try makeRepository(publishStore: publishStore)
        await repository.warmUp()

        try await repository.publishMyProfileToConversation("c2")

        let jobs = try await publishStore.activeJobs()
        #expect(!jobs.isEmpty)
    }

    @Test("publishMyProfileToConversation re-seeds a tombstoned self avatar slot")
    func seedRunsWhenSelfAvatarTombstoned() async throws {
        let profileStore = InMemoryProfileStore()
        let publishStore = InMemoryProfilePublishStore()
        try await profileStore.saveAvatar(DBProfileAvatar(
            inboxId: "me", conversationId: "c1", url: nil, salt: nil, nonce: nil,
            encryptionKey: nil, profileSource: .profileUpdate, updatedAt: Date(timeIntervalSince1970: 1)
        ))
        let repository = try makeRepository(profileStore: profileStore, publishStore: publishStore)
        await repository.warmUp()

        try await repository.publishMyProfileToConversation("c1")

        let jobs = try await publishStore.activeJobs()
        #expect(!jobs.isEmpty)
    }
}
