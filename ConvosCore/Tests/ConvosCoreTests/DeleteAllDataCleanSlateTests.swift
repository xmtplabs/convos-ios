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

        try await dbManager.dbWriter.read { db in
            #expect(try DBMyProfile.fetchCount(db) == 0)
            #expect(try DBProfile.fetchCount(db) == 0)
            #expect(try DBProfileAvatar.fetchCount(db) == 0)
            #expect(try DBProfileAvatarSource.fetchCount(db) == 0)
            #expect(try DBProfilePublishJob.fetchCount(db) == 0)
        }
    }
}
