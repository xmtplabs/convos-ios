@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for `MyProfileRepository.observedProfile`: the current user's
/// identity comes from `DBMyProfile` and the avatar from the newest
/// `DBProfileAvatar` slot, so a self-avatar upload surfaces on the My Profile
/// screen instead of showing a blank photo.
@Suite("MyProfileRepository self profile")
struct MyProfileRepositoryTests {
    private let salt = Data(repeating: 1, count: 32)
    private let nonce = Data(repeating: 2, count: 12)
    private let key = Data(repeating: 3, count: 32)

    @Test("surfaces the latest self avatar alongside the name")
    func surfacesSelfAvatar() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1", "c2"])
        try await queue.write { db in
            try DBMyProfile(inboxId: "me", name: "Me").save(db)
            try DBProfileAvatar(
                inboxId: "me", conversationId: "c1", url: "old", salt: salt, nonce: nonce,
                encryptionKey: key, profileSource: .profileUpdate, updatedAt: Date(timeIntervalSince1970: 1)
            ).save(db)
            try DBProfileAvatar(
                inboxId: "me", conversationId: "c2", url: "new", salt: salt, nonce: nonce,
                encryptionKey: key, profileSource: .profileUpdate, updatedAt: Date(timeIntervalSince1970: 5)
            ).save(db)
        }

        let profile = try await queue.read { db in
            try MyProfileRepository.observedProfile(db, inboxId: "me", conversationId: "c1")
        }

        #expect(profile.name == "Me")
        // Newest slot wins.
        #expect(profile.avatar == "new")
        #expect(profile.isAvatarEncrypted)
    }

    @Test("no avatar slot leaves the avatar nil but keeps the name")
    func nameOnlyWhenNoAvatar() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1"])
        try await queue.write { db in
            try DBMyProfile(inboxId: "me", name: "Me").save(db)
        }

        let profile = try await queue.read { db in
            try MyProfileRepository.observedProfile(db, inboxId: "me", conversationId: "c1")
        }

        #expect(profile.name == "Me")
        #expect(profile.avatar == nil)
    }

    @Test("no self row resolves to an empty profile")
    func emptyWhenNoSelfRow() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1"])

        let profile = try await queue.read { db in
            try MyProfileRepository.observedProfile(db, inboxId: "me", conversationId: "c1")
        }

        #expect(profile.name == nil)
        #expect(profile.avatar == nil)
    }
}
