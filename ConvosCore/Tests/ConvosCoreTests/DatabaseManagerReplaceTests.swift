@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// `DatabaseManager.replaceDatabase` (exercised via `MockDatabaseManager`).
///
/// The mock implementation mirrors the real one's pool-to-pool +
/// rollback-snapshot + migration-after-swap contract — tests verify
/// the *contract*, not the file-system transport. File-system / NSE
/// coordination are tested manually on device.
@Suite("DatabaseManager.replaceDatabase")
struct DatabaseManagerReplaceTests {
    @Test("successful replace copies rows from backup file into the live pool")
    func testSuccessfulReplace() async throws {
        let fixtures = TestFixtures()
        defer { try? fixtures.databaseManager.dbPool.erase() }

        // Seed the live DB with one conversation, then create a separate
        // backup file with a different conversation. After replace, the
        // live DB should reflect the backup's contents.
        try await fixtures.databaseManager.dbWriter.write { db in
            try seedConversation(id: "pre-restore", in: db)
        }

        let backupPath = try makeBackupFile(seedConversationId: "post-restore")
        defer { try? FileManager.default.removeItem(at: backupPath) }

        try fixtures.databaseManager.replaceDatabase(with: backupPath)

        let ids = try await fixtures.databaseManager.dbReader.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM conversation ORDER BY id")
        }
        #expect(ids == ["post-restore"])

        try? await fixtures.cleanup()
    }

    @Test("missing backup file throws backupFileMissing before touching the live pool")
    func testMissingBackupFile() async throws {
        let fixtures = TestFixtures()
        defer { try? fixtures.databaseManager.dbPool.erase() }

        try await fixtures.databaseManager.dbWriter.write { db in
            try seedConversation(id: "pre-restore", in: db)
        }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).sqlite")

        #expect(throws: DatabaseManagerError.self) {
            try fixtures.databaseManager.replaceDatabase(with: missing)
        }

        // Live DB untouched.
        let ids = try await fixtures.databaseManager.dbReader.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM conversation")
        }
        #expect(ids == ["pre-restore"])

        try? await fixtures.cleanup()
    }

    @Test("corrupt backup rolls back — live pool returns to pre-restore state")
    func testRollbackOnCorruptBackup() async throws {
        let fixtures = TestFixtures()
        defer { try? fixtures.databaseManager.dbPool.erase() }

        try await fixtures.databaseManager.dbWriter.write { db in
            try seedConversation(id: "pre-restore", in: db)
        }

        // Write a non-SQLite file masquerading as a .sqlite backup.
        let corrupt = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-\(UUID().uuidString).sqlite")
        try Data("not a sqlite database".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }

        // Expect *some* throw — could be the DatabaseQueue init, the
        // backup call, or the migrate pass. Either way, rollback runs
        // and the live DB ends up with the original row.
        do {
            try fixtures.databaseManager.replaceDatabase(with: corrupt)
            Issue.record("expected replaceDatabase to throw on corrupt file")
        } catch {
            // Expected — continue to state assertion.
        }

        let ids = try await fixtures.databaseManager.dbReader.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM conversation")
        }
        #expect(ids == ["pre-restore"], "rollback must leave the live DB at pre-restore state")

        try? await fixtures.cleanup()
    }

    // MARK: - Helpers

    /// Seed a single `DBConversation` row. Mirrors the helper in
    /// `InactiveConversationReactivatorTests` but kept local here so
    /// the two files don't couple.
    private func seedConversation(id: String, in db: Database) throws {
        let creatorInboxId = "inbox-\(id)"
        try DBMember(inboxId: creatorInboxId).save(db, onConflict: .ignore)
        try DBConversation(
            id: id,
            clientConversationId: id,
            inviteTag: "tag-\(id)",
            creatorId: creatorInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
            name: nil,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: false,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            imageLastRenewed: nil,
            isUnused: false,
            hasHadVerifiedAssistant: false
        ).insert(db)
    }

    /// Produce an on-disk, migrated GRDB file seeded with one conversation.
    /// The result is a valid `.sqlite` at a unique temp path; caller owns cleanup.
    private func makeBackupFile(seedConversationId: String) throws -> URL {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-\(UUID().uuidString).sqlite")
        let queue = try DatabaseQueue(path: path.path)
        try SharedDatabaseMigrator.shared.migrate(database: queue)
        try queue.write { db in
            try seedConversation(id: seedConversationId, in: db)
        }
        return path
    }
}
