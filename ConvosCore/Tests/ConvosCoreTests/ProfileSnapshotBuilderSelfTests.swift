@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Focused coverage for the self-union in `ProfileSnapshotBuilder.fetchDBProfiles`:
/// self identity lives in `myProfile` (not `profile`), so the outbound roster
/// must fold it in or a sender advertises no identity for itself and joiners
/// render the creator as "Somebody".
@Suite("ProfileSnapshotBuilder self union")
struct ProfileSnapshotBuilderSelfTests {
    private let salt = Data(repeating: 1, count: 32)
    private let nonce = Data(repeating: 2, count: 12)
    private let key = Data(repeating: 3, count: 32)

    @Test("fetchDBProfiles folds in the self identity from myProfile")
    func fetchDBProfilesUnionsSelf() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1"])
        let time = Date(timeIntervalSince1970: 1)
        try await queue.write { db in
            try DBProfile(inboxId: "alice", name: "Alice", profileSource: .profileUpdate, updatedAt: time).save(db)
            try DBMyProfile(inboxId: "me", name: "Me").save(db)
            try DBProfileAvatar(
                inboxId: "me", conversationId: "c1", url: "u", salt: salt, nonce: nonce,
                encryptionKey: key, profileSource: .profileUpdate, updatedAt: time
            ).save(db)
        }

        let profiles = try await ProfileSnapshotBuilder.fetchDBProfiles(
            queue, conversationId: "c1", memberInboxIds: ["alice", "me"]
        )

        let me = profiles.first { $0.inboxIdString == "me" }
        #expect(me != nil)
        #expect(me?.name == "Me")
        #expect(me?.encryptedImage.url == "u")
        #expect(profiles.contains { $0.inboxIdString == "alice" })
    }

    @Test("fetchDBProfiles prefers the canonical profile row over myProfile")
    func fetchDBProfilesPrefersCanonical() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1"])
        let time = Date(timeIntervalSince1970: 1)
        try await queue.write { db in
            try DBProfile(inboxId: "me", name: "Canonical", profileSource: .profileUpdate, updatedAt: time).save(db)
            try DBMyProfile(inboxId: "me", name: "Self").save(db)
        }

        let profiles = try await ProfileSnapshotBuilder.fetchDBProfiles(
            queue, conversationId: "c1", memberInboxIds: ["me"]
        )

        let me = profiles.first { $0.inboxIdString == "me" }
        #expect(me?.name == "Canonical")
    }

    @Test("fetchDBProfiles omits self when it is not a member")
    func fetchDBProfilesOmitsNonMemberSelf() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1"])
        let time = Date(timeIntervalSince1970: 1)
        try await queue.write { db in
            try DBProfile(inboxId: "alice", name: "Alice", profileSource: .profileUpdate, updatedAt: time).save(db)
            try DBMyProfile(inboxId: "me", name: "Me").save(db)
        }

        let profiles = try await ProfileSnapshotBuilder.fetchDBProfiles(
            queue, conversationId: "c1", memberInboxIds: ["alice"]
        )

        #expect(!profiles.contains { $0.inboxIdString == "me" })
    }
}
