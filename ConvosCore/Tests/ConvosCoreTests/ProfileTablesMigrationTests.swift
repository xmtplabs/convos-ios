@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Guards `SharedDatabaseMigrator.createProfileTables`, the additive schema for
/// the canonical Profile-table identity model (see
/// docs/plans/2026-06-29-profile-table-implementation.md).
///
/// The migrator's `createMigrator()` is private and DEBUG enables
/// `eraseDatabaseOnSchemaChange`, so these tests build the conversation table the
/// new tables reference, call the extracted static helper directly, then seed and
/// read rows (mirrors `DropRevealColumnsMigrationTests`).
@Suite("Create profile tables migration", .serialized)
struct ProfileTablesMigrationTests {
    /// The new avatar/job tables carry foreign keys to `conversation`, so a
    /// minimal conversation table must exist before `createProfileTables` runs.
    private func makeSchema(_ db: Database) throws {
        try db.create(table: "conversation") { t in
            t.column("id", .text).notNull().primaryKey()
        }
        try SharedDatabaseMigrator.createProfileTables(db)
    }

    private func insertConversation(_ db: Database, id: String) throws {
        try db.execute(sql: "INSERT INTO conversation (id) VALUES (?)", arguments: [id])
    }

    @Test("creates all five tables with expected columns and primary keys")
    func createsTables() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try self.makeSchema(db)
        }

        try dbQueue.read { db in
            #expect(try db.tableExists("profile"))
            #expect(try db.tableExists("profileAvatar"))
            #expect(try db.tableExists("selfProfile"))
            #expect(try db.tableExists("profileAvatarSource"))
            #expect(try db.tableExists("profilePublishJob"))

            let profileColumns = try db.columns(in: "profile").map(\.name)
            let expectedProfileColumns = [
                "inboxId", "name", "memberKind", "metadata",
                "profileSource", "avatarContentDigest", "updatedAt"
            ]
            #expect(expectedProfileColumns.allSatisfy(profileColumns.contains))

            let avatarColumns = try db.columns(in: "profileAvatar").map(\.name)
            let expectedAvatarColumns = [
                "inboxId", "conversationId", "url", "salt", "nonce",
                "encryptionKey", "profileSource", "contentDigest", "updatedAt"
            ]
            #expect(expectedAvatarColumns.allSatisfy(avatarColumns.contains))

            let jobColumns = try db.columns(in: "profilePublishJob").map(\.name)
            let expectedJobColumns = [
                "id", "seq", "conversationId", "sourceVersion", "hasAvatar",
                "state", "ciphertext", "salt", "nonce", "groupKey", "filename",
                "uploadedURL", "attemptCount", "nextAttemptAt", "lastError",
                "createdAt", "updatedAt"
            ]
            #expect(expectedJobColumns.allSatisfy(jobColumns.contains))

            let avatarPK = try db.primaryKey("profileAvatar")
            #expect(avatarPK.columns == ["inboxId", "conversationId"])
        }
    }

    @Test("DBProfile round-trips, including metadata and member kind")
    func profileRoundTrips() throws {
        let dbQueue = try DatabaseQueue()
        let updatedAt = Date(timeIntervalSince1970: 1_000_000)
        try dbQueue.write { db in
            try self.makeSchema(db)
            let profile = DBProfile(
                inboxId: "inbox-1",
                name: "Alice",
                memberKind: .verifiedConvos,
                metadata: ["templateId": .string("tmpl-1")],
                profileSource: .profileUpdate,
                updatedAt: updatedAt
            )
            try profile.save(db)
        }

        try dbQueue.read { db in
            let fetched = try DBProfile.fetchOne(db, inboxId: "inbox-1")
            #expect(fetched?.name == "Alice")
            #expect(fetched?.memberKind == .verifiedConvos)
            #expect(fetched?.profileSource == .profileUpdate)
            #expect(fetched?.metadata?["templateId"]?.stringValue == "tmpl-1")
            #expect(fetched?.avatarContentDigest == nil)
            #expect(fetched?.updatedAt == updatedAt)
        }
    }

    @Test("DBProfileAvatar round-trips by composite key")
    func avatarRoundTrips() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try self.makeSchema(db)
            try self.insertConversation(db, id: "conv-1")
            let avatar = DBProfileAvatar(
                inboxId: "inbox-1",
                conversationId: "conv-1",
                url: "https://example.com/a.enc",
                salt: Data(repeating: 1, count: 32),
                nonce: Data(repeating: 2, count: 12),
                encryptionKey: Data(repeating: 3, count: 32),
                profileSource: .profileSnapshot,
                updatedAt: Date(timeIntervalSince1970: 1)
            )
            try avatar.save(db)
        }

        try dbQueue.read { db in
            let fetched = try DBProfileAvatar.fetchOne(db, inboxId: "inbox-1", conversationId: "conv-1")
            #expect(fetched?.url == "https://example.com/a.enc")
            #expect(fetched?.salt?.count == 32)
            #expect(fetched?.nonce?.count == 12)
            #expect(fetched?.encryptionKey?.count == 32)
            #expect(fetched?.profileSource == .profileSnapshot)
            #expect(fetched?.hasValidEncryptedAvatar == true)
        }
    }

    @Test("DBSelfProfile and DBProfileAvatarSource round-trip")
    func selfAndSourceRoundTrip() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try self.makeSchema(db)
            try DBSelfProfile(inboxId: "me", name: "Me", updatedAt: Date(timeIntervalSince1970: 2)).save(db)
            try DBProfileAvatarSource(
                inboxId: "me",
                plaintext: Data(repeating: 9, count: 16),
                version: 3,
                updatedAt: Date(timeIntervalSince1970: 2)
            ).save(db)
        }

        try dbQueue.read { db in
            let selfProfile = try DBSelfProfile.fetchOne(db, inboxId: "me")
            #expect(selfProfile?.name == "Me")
            let source = try DBProfileAvatarSource.fetchOne(db, inboxId: "me")
            #expect(source?.version == 3)
            #expect(source?.plaintext.count == 16)
        }
    }

    @Test("DBProfilePublishJob round-trips with state default and pinned source version")
    func publishJobRoundTrips() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try self.makeSchema(db)
            try self.insertConversation(db, id: "conv-1")
            let job = DBProfilePublishJob(
                id: "job-1",
                seq: 1,
                conversationId: "conv-1",
                sourceVersion: 7,
                hasAvatar: true,
                nextAttemptAt: Date(timeIntervalSince1970: 5),
                createdAt: Date(timeIntervalSince1970: 5),
                updatedAt: Date(timeIntervalSince1970: 5)
            )
            try job.save(db)
        }

        try dbQueue.read { db in
            let fetched = try DBProfilePublishJob.fetchOne(db, id: "job-1")
            #expect(fetched?.state == .pending)
            #expect(fetched?.sourceVersion == 7)
            #expect(fetched?.hasAvatar == true)
            #expect(fetched?.attemptCount == 0)
        }
    }

    @Test("deleting a conversation cascades to its avatar slots and publish jobs")
    func conversationDeleteCascades() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try self.makeSchema(db)
            try self.insertConversation(db, id: "conv-1")
            try DBProfileAvatar(
                inboxId: "inbox-1",
                conversationId: "conv-1",
                profileSource: .profileUpdate,
                updatedAt: Date(timeIntervalSince1970: 1)
            ).save(db)
            try DBProfilePublishJob(
                id: "job-1",
                seq: 1,
                conversationId: "conv-1",
                nextAttemptAt: Date(timeIntervalSince1970: 1),
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1)
            ).save(db)
        }

        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: ["conv-1"])
        }

        try dbQueue.read { db in
            let avatar = try DBProfileAvatar.fetchOne(db, inboxId: "inbox-1", conversationId: "conv-1")
            #expect(avatar == nil)
            let job = try DBProfilePublishJob.fetchOne(db, id: "job-1")
            #expect(job == nil)
        }
    }
}
