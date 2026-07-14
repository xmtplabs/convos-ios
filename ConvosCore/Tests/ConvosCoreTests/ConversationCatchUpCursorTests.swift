@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("Conversation CatchUp Cursor Tests", .serialized)
struct ConversationCatchUpCursorTests {
    @Test("returns nil before any catch-up has completed")
    func returnsNilWithoutRow() throws {
        let db = MockDatabaseManager.makeTestDatabase()
        try db.dbWriter.write { db in
            try seedConversation(db: db, conversationId: "conv-1")
            #expect(try DBConversationCatchUpCursor.caughtUpToNs(for: "conv-1", in: db) == nil)
        }
    }

    @Test("advance writes and reads back the cursor")
    func advanceWritesCursor() throws {
        let db = MockDatabaseManager.makeTestDatabase()
        try db.dbWriter.write { db in
            try seedConversation(db: db, conversationId: "conv-1")
            try DBConversationCatchUpCursor.advance(to: 1_000, for: "conv-1", in: db)
            #expect(try DBConversationCatchUpCursor.caughtUpToNs(for: "conv-1", in: db) == 1_000)
        }
    }

    @Test("advance is monotonic - an older batch can't roll the cursor back")
    func advanceIsMonotonic() throws {
        let db = MockDatabaseManager.makeTestDatabase()
        try db.dbWriter.write { db in
            try seedConversation(db: db, conversationId: "conv-1")
            try DBConversationCatchUpCursor.advance(to: 2_000, for: "conv-1", in: db)
            try DBConversationCatchUpCursor.advance(to: 1_500, for: "conv-1", in: db)
            #expect(try DBConversationCatchUpCursor.caughtUpToNs(for: "conv-1", in: db) == 2_000)
            try DBConversationCatchUpCursor.advance(to: 3_000, for: "conv-1", in: db)
            #expect(try DBConversationCatchUpCursor.caughtUpToNs(for: "conv-1", in: db) == 3_000)
        }
    }

    @Test("cursors are scoped per conversation")
    func cursorsAreScopedPerConversation() throws {
        let db = MockDatabaseManager.makeTestDatabase()
        try db.dbWriter.write { db in
            try seedConversation(db: db, conversationId: "conv-1")
            try seedConversation(db: db, conversationId: "conv-2", clientConversationId: "client-conv-2")
            try DBConversationCatchUpCursor.advance(to: 1_000, for: "conv-1", in: db)
            #expect(try DBConversationCatchUpCursor.caughtUpToNs(for: "conv-2", in: db) == nil)
        }
    }

    @Test("deleting the conversation cascades to its cursor row")
    func deletingConversationCascades() throws {
        let db = MockDatabaseManager.makeTestDatabase()
        try db.dbWriter.write { db in
            try seedConversation(db: db, conversationId: "conv-1")
            try DBConversationCatchUpCursor.advance(to: 1_000, for: "conv-1", in: db)
            _ = try DBConversation.deleteOne(db, key: "conv-1")
            #expect(try DBConversationCatchUpCursor.caughtUpToNs(for: "conv-1", in: db) == nil)
        }
    }

    // MARK: - Helpers

    private func seedConversation(
        db: Database,
        conversationId: String,
        clientConversationId: String = "client-conv-1"
    ) throws {
        let currentInboxId = "current-user"
        try DBMember(inboxId: currentInboxId).save(db)

        try DBConversation(
            id: conversationId,
            clientConversationId: clientConversationId,
            inviteTag: "tag-\(conversationId)",
            creatorId: currentInboxId,
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
            name: "Test",
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
            hasHadVerifiedAgent: false
        ).insert(db)
    }
}
