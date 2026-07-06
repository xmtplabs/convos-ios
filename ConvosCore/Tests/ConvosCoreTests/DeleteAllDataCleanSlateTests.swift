@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Guards that "Delete All Data" leaves a true clean slate: every account-scoped
/// table, including the canonical profile tables, is empty afterward. A residual
/// row here means a re-paired or different account inherits stale identity data,
/// which also poisons the clean-slate assumption other manual repros rely on.
@Suite("Delete all data clean slate")
struct DeleteAllDataCleanSlateTests {
    private let salt = Data(repeating: 1, count: 32)
    private let nonce = Data(repeating: 2, count: 12)
    private let key = Data(repeating: 3, count: 32)

    @Test("wipeAccountScopedRows clears the canonical profile tables")
    func clearsCanonicalProfileTables() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        try await dbManager.dbWriter.write { db in
            try DBMember(inboxId: "me").save(db, onConflict: .ignore)
            try DBConversation(
                id: "c1",
                clientConversationId: "c1",
                inviteTag: "tag-c1",
                creatorId: "me",
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: nil,
                description: nil,
                imageURLString: nil,
                publicImageURLString: nil,
                includeInfoInPublicPreview: true,
                expiresAt: nil,
                debugInfo: .empty,
                isLocked: false,
                imageSalt: nil,
                imageNonce: nil,
                imageEncryptionKey: nil,
                conversationEmoji: nil,
                imageLastRenewed: nil,
                isUnused: false,
                hasHadVerifiedAgent: false
            ).insert(db)
            try DBMyProfile(inboxId: "me", name: "Me").save(db)
            try DBProfile(
                inboxId: "alice", name: "Alice", profileSource: .profileUpdate,
                updatedAt: Date(timeIntervalSince1970: 1)
            ).save(db)
            try DBProfileAvatar(
                inboxId: "alice", conversationId: "c1", url: "u", salt: salt, nonce: nonce,
                encryptionKey: key, profileSource: .profileUpdate, updatedAt: Date(timeIntervalSince1970: 1)
            ).save(db)
            try DBProfileAvatarSource(
                inboxId: "me", plaintext: Data(repeating: 9, count: 8), version: 1,
                updatedAt: Date(timeIntervalSince1970: 1)
            ).save(db)
            try DBProfilePublishJob(
                id: "job1", seq: 1, conversationId: "c1", sourceVersion: 1, hasAvatar: true,
                nextAttemptAt: Date(timeIntervalSince1970: 1), createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1)
            ).save(db)
        }

        try await dbManager.dbWriter.write { db in
            try SessionManager.wipeAccountScopedRows(db)
        }

        let counts = try await dbManager.dbWriter.read { db in
            (
                myProfile: try DBMyProfile.fetchCount(db),
                profile: try DBProfile.fetchCount(db),
                avatar: try DBProfileAvatar.fetchCount(db),
                avatarSource: try DBProfileAvatarSource.fetchCount(db),
                publishJob: try DBProfilePublishJob.fetchCount(db)
            )
        }
        #expect(counts.myProfile == 0)
        #expect(counts.profile == 0)
        #expect(counts.avatar == 0)
        #expect(counts.avatarSource == 0)
        #expect(counts.publishJob == 0)
    }
}
