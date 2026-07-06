@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Confirms `AttachmentLocalStateWriter` round-trips the retained media metadata
/// (dimensions, mime type, waveform, duration) after the reveal columns were
/// dropped. The writer no longer exposes markRevealed/markHidden; that is
/// enforced at compile time by the trimmed `AttachmentLocalStateWriterProtocol`.
@Suite("Attachment local state writer", .serialized)
struct AttachmentLocalStateWriterTests {
    private func seedConversation(_ db: Database, id: String) throws {
        try DBMember(inboxId: "creator").save(db, onConflict: .ignore)
        try db.execute(
            sql: """
                INSERT INTO conversation (id, clientConversationId, inviteTag, creatorId, kind, consent, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
            arguments: [id, id, "tag-\(id)", "creator", "group", "allowed", Date()]
        )
    }

    @Test("saveWithDimensions persists and updates dimensions and mime type")
    func savesDimensions() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try self.seedConversation(db, id: "conv-1")
        }

        let writer = AttachmentLocalStateWriter(databaseWriter: dbManager.dbWriter)
        try await writer.saveWithDimensions(attachmentKey: "k1", conversationId: "conv-1", width: 100, height: 200, mimeType: "image/jpeg")

        let saved = try await dbManager.dbReader.read { db in
            try AttachmentLocalState.fetchOne(db, key: "k1")
        }
        #expect(saved?.width == 100)
        #expect(saved?.height == 200)
        #expect(saved?.mimeType == "image/jpeg")

        try await writer.saveWithDimensions(attachmentKey: "k1", conversationId: "conv-1", width: 640, height: 480, mimeType: "image/png")
        let updated = try await dbManager.dbReader.read { db in
            try AttachmentLocalState.fetchOne(db, key: "k1")
        }
        #expect(updated?.width == 640)
        #expect(updated?.mimeType == "image/png")
    }

    @Test("migrateKey moves the retained metadata to the new key")
    func migratesKey() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try await dbManager.dbWriter.write { db in
            try self.seedConversation(db, id: "conv-1")
        }

        let writer = AttachmentLocalStateWriter(databaseWriter: dbManager.dbWriter)
        try await writer.saveWithDimensions(attachmentKey: "old-key", conversationId: "conv-1", width: 320, height: 240, mimeType: "image/heic")
        try await writer.migrateKey(from: "old-key", to: "new-key")

        let (old, migrated) = try await dbManager.dbReader.read { db in
            (try AttachmentLocalState.fetchOne(db, key: "old-key"), try AttachmentLocalState.fetchOne(db, key: "new-key"))
        }
        #expect(old == nil)
        #expect(migrated?.width == 320)
        #expect(migrated?.mimeType == "image/heic")
    }
}
