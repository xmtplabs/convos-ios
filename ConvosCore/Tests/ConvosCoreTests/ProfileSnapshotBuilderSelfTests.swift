@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Focused coverage for the self-union in `ProfileSnapshotBuilder.fetchDBProfiles`:
/// self identity lives in `myProfile` (not `profile`), so the outbound roster
/// must fold it in or a sender advertises no identity for itself and joiners
/// render the creator as "Somebody".
///
/// Inbox ids must be valid hex: the snapshot's `MemberProfile(inboxIdString:)`
/// decodes the id via `Data(hexString:)` and drops non-hex entries.
@Suite("ProfileSnapshotBuilder self union")
struct ProfileSnapshotBuilderSelfTests {
    private let salt = Data(repeating: 1, count: 32)
    private let nonce = Data(repeating: 2, count: 12)
    private let key = Data(repeating: 3, count: 32)
    private let meId = "abcdef01"
    private let aliceId = "abcdef02"

    @Test("fetchDBProfiles folds in the self identity from myProfile")
    func fetchDBProfilesUnionsSelf() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1"])
        let time = Date(timeIntervalSince1970: 1)
        try await queue.write { db in
            try DBProfile(inboxId: aliceId, name: "Alice", profileSource: .profileUpdate, updatedAt: time).save(db)
            try DBMyProfile(inboxId: meId, name: "Me").save(db)
            try DBProfileAvatar(
                inboxId: meId, conversationId: "c1", url: "u", salt: salt, nonce: nonce,
                encryptionKey: key, profileSource: .profileUpdate, updatedAt: time
            ).save(db)
        }

        let profiles = try await ProfileSnapshotBuilder.fetchDBProfiles(
            queue, conversationId: "c1", memberInboxIds: [aliceId, meId]
        )

        let me = profiles.first { $0.inboxIdString == meId }
        #expect(me != nil)
        #expect(me?.name == "Me")
        #expect(me?.encryptedImage.url == "u")
        #expect(profiles.contains { $0.inboxIdString == aliceId })
    }

    @Test("fetchDBProfiles prefers the canonical profile row over myProfile")
    func fetchDBProfilesPrefersCanonical() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1"])
        let time = Date(timeIntervalSince1970: 1)
        try await queue.write { db in
            try DBProfile(inboxId: meId, name: "Canonical", profileSource: .profileUpdate, updatedAt: time).save(db)
            try DBMyProfile(inboxId: meId, name: "Self").save(db)
        }

        let profiles = try await ProfileSnapshotBuilder.fetchDBProfiles(
            queue, conversationId: "c1", memberInboxIds: [meId]
        )

        let me = profiles.first { $0.inboxIdString == meId }
        #expect(me?.name == "Canonical")
    }

    @Test("fetchDBProfiles omits self when it is not a member")
    func fetchDBProfilesOmitsNonMemberSelf() async throws {
        let queue = try ProfileStoreTestSupport.makeQueue(conversations: ["c1"])
        let time = Date(timeIntervalSince1970: 1)
        try await queue.write { db in
            try DBProfile(inboxId: aliceId, name: "Alice", profileSource: .profileUpdate, updatedAt: time).save(db)
            try DBMyProfile(inboxId: meId, name: "Me").save(db)
        }

        let profiles = try await ProfileSnapshotBuilder.fetchDBProfiles(
            queue, conversationId: "c1", memberInboxIds: [aliceId]
        )

        #expect(!profiles.contains { $0.inboxIdString == meId })
    }
}
