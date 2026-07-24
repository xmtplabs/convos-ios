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

    @Test("creates all four tables with expected columns and primary keys")
    func createsTables() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try self.makeSchema(db)
        }

        try dbQueue.read { db in
            #expect(try db.tableExists("profile"))
            #expect(try db.tableExists("profileAvatar"))
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

    @Test("DBProfileAvatarSource round-trips")
    func sourceRoundTrip() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try self.makeSchema(db)
            try DBProfileAvatarSource(
                inboxId: "me",
                plaintext: Data(repeating: 9, count: 16),
                version: 3,
                updatedAt: Date(timeIntervalSince1970: 2)
            ).save(db)
        }

        try dbQueue.read { db in
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

    /// The strip step reads `myProfile`, so the scoped-metadata migration tests
    /// need that table in the minimal schema too.
    private func makeSchemaWithMyProfile(_ db: Database) throws {
        try makeSchema(db)
        try db.create(table: "myProfile") { t in
            t.column("inboxId", .text).notNull().primaryKey()
            t.column("name", .text)
            t.column("imageData", .blob)
            t.column("imageAssetIdentifier", .text)
            t.column("imageContentDigest", .text)
            t.column("metadata", .jsonText)
            t.column("updatedAt", .datetime).notNull()
        }
    }

    @Test("createSelfConversationMetadata creates the table, round-trips, and cascades on conversation delete")
    func createsSelfConversationMetadata() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try self.makeSchemaWithMyProfile(db)
            try SharedDatabaseMigrator.createSelfConversationMetadata(db)
            try self.insertConversation(db, id: "conv-1")
            try DBSelfConversationMetadata(
                inboxId: "me",
                conversationId: "conv-1",
                metadata: ["connections": .string("grants"), "timezone": .string("Europe/Paris")],
                updatedAt: Date(timeIntervalSince1970: 1)
            ).save(db)
        }

        try dbQueue.read { db in
            #expect(try db.tableExists("selfConversationMetadata"))
            let row = try DBSelfConversationMetadata.fetchOne(db)
            #expect(row?.metadata["connections"] == .string("grants"))
            #expect(row?.metadata["timezone"] == .string("Europe/Paris"))
        }

        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM conversation WHERE id = ?", arguments: ["conv-1"])
        }
        try dbQueue.read { db in
            let remaining = try DBSelfConversationMetadata.fetchCount(db)
            #expect(remaining == 0)
        }
    }

    @Test("createSelfConversationMetadata strips scoped keys from the global myProfile metadata")
    func stripsScopedKeysFromGlobalMetadata() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try self.makeSchemaWithMyProfile(db)
            // A build that ran the interim global routing: grants and timezone
            // were written into the global map next to real global keys.
            try DBMyProfile(
                inboxId: "me",
                name: "Me",
                metadata: [
                    "connections": .string("grants"),
                    "timezone": .string("Europe/Paris"),
                    "emoji": .string("kept")
                ],
                updatedAt: Date(timeIntervalSince1970: 1)
            ).save(db)
            try DBMyProfile(
                inboxId: "only-scoped",
                metadata: ["timezone": .string("America/New_York")],
                updatedAt: Date(timeIntervalSince1970: 1)
            ).save(db)
            try SharedDatabaseMigrator.createSelfConversationMetadata(db)
        }

        try dbQueue.read { db in
            let mixed = try DBMyProfile.filter(DBMyProfile.Columns.inboxId == "me").fetchOne(db)
            #expect(mixed?.metadata?["connections"] == nil)
            #expect(mixed?.metadata?["timezone"] == nil)
            #expect(mixed?.metadata?["emoji"] == .string("kept"))
            // A map that held only scoped keys collapses to nil.
            let onlyScoped = try DBMyProfile.filter(DBMyProfile.Columns.inboxId == "only-scoped").fetchOne(db)
            #expect(onlyScoped?.metadata == nil)
        }
    }

    @Test("addProfilePublishJobProfileUpdatedAt adds the column to an old table and no-ops on a fresh one")
    func addsProfilePublishJobProfileUpdatedAt() throws {
        // Upgrade path: a dev install whose profilePublishJob predates the
        // column.
        let upgraded = try DatabaseQueue()
        try upgraded.write { db in
            try db.create(table: "conversation") { t in
                t.column("id", .text).notNull().primaryKey()
            }
            try db.create(table: "profilePublishJob") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("seq", .integer).notNull()
                t.column("conversationId", .text).notNull()
                t.column("state", .text).notNull()
                t.column("nextAttemptAt", .datetime).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try SharedDatabaseMigrator.addProfilePublishJobProfileUpdatedAt(db)
            let columns = try db.columns(in: "profilePublishJob").map(\.name)
            #expect(columns.contains("profileUpdatedAt"))
        }

        // Fresh path: createProfileTables already includes the column; the
        // guarded migration must no-op instead of failing on a duplicate.
        let fresh = try DatabaseQueue()
        try fresh.write { db in
            try self.makeSchema(db)
            try SharedDatabaseMigrator.addProfilePublishJobProfileUpdatedAt(db)
            let columns = try db.columns(in: "profilePublishJob").map(\.name)
            #expect(columns.filter { $0 == "profileUpdatedAt" }.count == 1)
        }
    }
}
