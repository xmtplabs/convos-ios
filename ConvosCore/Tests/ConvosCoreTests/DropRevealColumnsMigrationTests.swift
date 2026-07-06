@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Guards `SharedDatabaseMigrator.dropRevealColumns`, the upgrade that removes
/// the reveal-mode columns once incoming media always renders unblurred.
///
/// The migrator's `createMigrator()` is private and DEBUG enables
/// `eraseDatabaseOnSchemaChange`, so driving the migration through
/// `SharedDatabaseMigrator.shared.migrate(...)` in a debug `swift test` build
/// would erase-and-rebuild instead of exercising the real `DROP COLUMN` path.
/// These tests build the prior schema by hand, seed rows, then call the
/// extracted static helper directly (mirrors `AgentTemplateBackfillMigrationTests`).
@Suite("Drop reveal columns migration", .serialized)
struct DropRevealColumnsMigrationTests {
    private func makePriorSchema(_ db: Database) throws {
        try db.create(table: "photoPreferences") { t in
            t.column("conversationId", .text).notNull().primaryKey()
            t.column("autoReveal", .boolean).notNull().defaults(to: false)
            t.column("hasRevealedFirst", .boolean).notNull().defaults(to: false)
            t.column("updatedAt", .datetime).notNull()
            t.column("sendReadReceipts", .boolean)
        }
        try db.create(table: "attachmentLocalState") { t in
            t.column("attachmentKey", .text).notNull().primaryKey()
            t.column("conversationId", .text).notNull()
            t.column("isRevealed", .boolean).notNull().defaults(to: false)
            t.column("revealedAt", .datetime)
            t.column("width", .integer)
            t.column("height", .integer)
            t.column("isHiddenByOwner", .boolean).notNull().defaults(to: false)
            t.column("mimeType", .text)
            t.column("waveformLevels", .text)
            t.column("duration", .double)
        }
    }

    @Test("drops the reveal columns while preserving retained columns and row values")
    func dropsRevealColumns() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try self.makePriorSchema(db)
            try db.execute(
                sql: """
                    INSERT INTO photoPreferences (conversationId, autoReveal, hasRevealedFirst, updatedAt, sendReadReceipts)
                    VALUES ('c1', 0, 0, '2026-01-01 00:00:00', 1)
                    """
            )
            try db.execute(
                sql: """
                    INSERT INTO attachmentLocalState (attachmentKey, conversationId, isRevealed, isHiddenByOwner, width, height, mimeType)
                    VALUES ('k1', 'c1', 0, 1, 100, 200, 'image/jpeg')
                    """
            )
        }

        try dbQueue.write { db in
            try SharedDatabaseMigrator.dropRevealColumns(db)
        }

        try dbQueue.read { db in
            let photoColumns = try db.columns(in: "photoPreferences").map(\.name)
            #expect(!photoColumns.contains("autoReveal"))
            #expect(!photoColumns.contains("hasRevealedFirst"))
            #expect(photoColumns.contains("sendReadReceipts"))

            let attachmentColumns = try db.columns(in: "attachmentLocalState").map(\.name)
            #expect(!attachmentColumns.contains("isRevealed"))
            #expect(!attachmentColumns.contains("revealedAt"))
            #expect(!attachmentColumns.contains("isHiddenByOwner"))
            #expect(["width", "height", "mimeType", "waveformLevels", "duration"].allSatisfy(attachmentColumns.contains))

            let receipts = try Int.fetchOne(db, sql: "SELECT sendReadReceipts FROM photoPreferences WHERE conversationId = 'c1'")
            #expect(receipts == 1)
            let width = try Int.fetchOne(db, sql: "SELECT width FROM attachmentLocalState WHERE attachmentKey = 'k1'")
            #expect(width == 100)
        }
    }

    @Test("trimmed record structs round-trip through the dropped schema")
    func recordsRoundTripAfterDrop() throws {
        let dbQueue = try DatabaseQueue()

        try dbQueue.write { db in
            try self.makePriorSchema(db)
            try SharedDatabaseMigrator.dropRevealColumns(db)

            let prefs = DBPhotoPreferences.defaultPreferences(for: "c2").with(sendReadReceipts: true)
            try prefs.save(db)

            let state = AttachmentLocalState(
                attachmentKey: "k2",
                conversationId: "c2",
                width: 320,
                height: 240,
                mimeType: "image/png"
            )
            try state.insert(db)
        }

        try dbQueue.read { db in
            let prefs = try DBPhotoPreferences.fetchOne(db, key: "c2")
            #expect(prefs?.sendReadReceipts == true)

            let state = try AttachmentLocalState.fetchOne(db, key: "k2")
            #expect(state?.width == 320)
            #expect(state?.mimeType == "image/png")
        }
    }
}
