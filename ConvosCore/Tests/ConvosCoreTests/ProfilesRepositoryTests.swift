@testable import ConvosCore
import Foundation
import Testing

@Suite("ProfilesRepository")
struct ProfilesRepositoryTests {
    private let salt = Data(repeating: 1, count: 32)
    private let nonce = Data(repeating: 2, count: 12)
    private let key = Data(repeating: 3, count: 32)

    private func makeRepository(
        profileStore: any ProfileStoreProtocol = InMemoryProfileStore(),
        selfProfileStore: any SelfProfileStoreProtocol = InMemorySelfProfileStore(),
        selfInboxId: String = "me"
    ) -> ProfilesRepository {
        ProfilesRepository(profileStore: profileStore, selfProfileStore: selfProfileStore, selfInboxId: selfInboxId)
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
    func applyCreatesProfile() async {
        let repository = makeRepository()
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
    func selfEchoIgnored() async {
        let repository = makeRepository(selfInboxId: "me")
        await repository.warmUp()
        await repository.apply(event(
            inboxId: "me", conversationId: "c1", name: "Myself",
            avatar: .silent, sentAt: Date(timeIntervalSince1970: 1)
        ))

        let profile = await repository.profile(inboxId: "me")
        #expect(profile.name == nil)
    }

    @Test("apply respects merge precedence end to end")
    func applyRespectsPrecedence() async {
        let repository = makeRepository()
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
        let repository = makeRepository(profileStore: profileStore)
        await repository.warmUp()

        let profile = await repository.profile(inboxId: "bob")
        #expect(profile.name == "Bob")
    }

    @Test("updateSelfProfile persists and is reflected in selfProfile()")
    func updateSelf() async throws {
        let selfStore = InMemorySelfProfileStore()
        let repository = makeRepository(selfProfileStore: selfStore)
        await repository.warmUp()
        try await repository.updateSelfProfile(SelfProfileEdit(name: .set("Me")))

        let profile = await repository.selfProfile()
        #expect(profile?.name == "Me")
        let persisted = try await selfStore.load()
        #expect(persisted?.name == "Me")
    }

    @Test("displayAvatar falls back to the newest slot without a conversation match")
    func displayAvatarFallback() async {
        let repository = makeRepository()
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
    func purgeAvatars() async {
        let repository = makeRepository()
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
}
