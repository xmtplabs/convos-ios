@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for `SessionManager.deleteStaleStrangerConversations(db:cutoff:)`
/// - the stale-stranger garbage collector that reclaims unsolicited stranger
/// shells. It must only delete empty `.unknown` conversations older than the
/// cutoff, and never delete a conversation that holds any local message or
/// whose consent the user/contact-state already resolved.
@Suite("StaleStrangerGC Tests", .serialized)
struct StaleStrangerGCTests {
    private static let cutoff: Date = Date(timeIntervalSince1970: 1_000_000)
    private static let old: Date = Date(timeIntervalSince1970: 0)
    private static let recent: Date = Date(timeIntervalSince1970: 2_000_000)

    @Test("Empty old .unknown stranger is deleted")
    func testDeletesEmptyOldUnknown() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "old-empty", consent: .unknown, createdAt: Self.old)
        }

        let deleted = try dbManager.dbWriter.write { db in
            try SessionManager.deleteStaleStrangerConversations(db: db, cutoff: Self.cutoff)
        }

        #expect(deleted == 1)
        let remaining = try dbManager.dbReader.read { db in try DBConversation.fetchCount(db) }
        #expect(remaining == 0)
    }

    @Test("Old .unknown with a local message is preserved - content is never deleted")
    func testPreservesOldUnknownWithMessages() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "old-engaged", consent: .unknown, createdAt: Self.old)
            try Self.seedMessage(db: db, conversationId: "old-engaged")
        }

        let deleted = try dbManager.dbWriter.write { db in
            try SessionManager.deleteStaleStrangerConversations(db: db, cutoff: Self.cutoff)
        }

        #expect(deleted == 0)
    }

    @Test("Recent empty .unknown (created after the cutoff) is preserved")
    func testPreservesRecentUnknown() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "recent", consent: .unknown, createdAt: Self.recent)
        }

        let deleted = try dbManager.dbWriter.write { db in
            try SessionManager.deleteStaleStrangerConversations(db: db, cutoff: Self.cutoff)
        }

        #expect(deleted == 0)
    }

    @Test("Old empty .allowed and .denied conversations are preserved")
    func testPreservesNonUnknownConsent() throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        try dbManager.dbWriter.write { db in
            try Self.seedConversation(db: db, id: "old-allowed", consent: .allowed, createdAt: Self.old)
            try Self.seedConversation(db: db, id: "old-denied", consent: .denied, createdAt: Self.old)
        }

        let deleted = try dbManager.dbWriter.write { db in
            try SessionManager.deleteStaleStrangerConversations(db: db, cutoff: Self.cutoff)
        }

        #expect(deleted == 0)
        let remaining = try dbManager.dbReader.read { db in try DBConversation.fetchCount(db) }
        #expect(remaining == 2)
    }

    private static func seedConversation(
        db: Database,
        id: String,
        consent: Consent,
        createdAt: Date
    ) throws {
        try DBMember(inboxId: "creator-\(id)").save(db, onConflict: .ignore)
        try DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: "tag-\(id)",
            creatorId: "creator-\(id)",
            kind: .group,
            consent: consent,
            createdAt: createdAt,
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
            hasHadVerifiedAgent: false
        ).insert(db)
    }

    private static func seedMessage(db: Database, conversationId: String) throws {
        try DBMember(inboxId: "sender").save(db, onConflict: .ignore)
        try DBMessage(
            id: "msg-\(conversationId)",
            clientMessageId: "msg-\(conversationId)",
            conversationId: conversationId,
            senderId: "sender",
            dateNs: 1,
            date: Date(timeIntervalSince1970: 0),
            sortId: nil,
            status: .published,
            messageType: .original,
            contentType: .text,
            text: "hi",
            emoji: nil,
            invite: nil,
            linkPreview: nil,
            sourceMessageId: nil,
            attachmentUrls: [],
            update: nil
        ).insert(db)
    }
}
