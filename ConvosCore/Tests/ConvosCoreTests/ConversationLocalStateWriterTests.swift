@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("ConversationLocalStateWriter Tests", .serialized)
struct ConversationLocalStateWriterTests {
    /// Inserts a minimal `conversation` row so `conversationLocalState`
    /// can FK against it. `setHidesInviteCard` (and the other writer
    /// methods) guard against missing conversation rows via
    /// `DBConversation.fetchOne`, so this seed is required for the
    /// happy-path tests below.
    private static func seedMinimalConversation(_ db: Database, id: String) throws {
        let creatorInboxId = "creator-\(id)"
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
            hasHadVerifiedAgent: false
        ).insert(db)
    }

    private static func fetchLocalState(
        _ dbReader: any DatabaseReader,
        for conversationId: String
    ) throws -> ConversationLocalState? {
        try dbReader.read { db in
            try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == conversationId)
                .fetchOne(db)
        }
    }

    @Test("setHidesInviteCard creates a local-state row when none exists, with other flags defaulting to false")
    func testSetHidesInviteCardCreatesRowIfMissing() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ConversationLocalStateWriter(databaseWriter: dbManager.dbWriter)

        let conversationId = "convo-new"
        try await dbManager.dbWriter.write { db in
            try Self.seedMinimalConversation(db, id: conversationId)
        }

        try await writer.setHidesInviteCard(true, for: conversationId)

        let state = try Self.fetchLocalState(dbManager.dbReader, for: conversationId)
        #expect(state?.hidesInviteCard == true)
        // The picker-seeded flow only flips hidesInviteCard - other
        // local flags must stay at their default values so the
        // conversation does not accidentally land pinned / muted / etc.
        #expect(state?.isPinned == false)
        #expect(state?.isUnread == false)
        #expect(state?.isMuted == false)
        #expect(state?.pinnedOrder == nil)
    }

    @Test("setHidesInviteCard mutates only the hidesInviteCard column on an existing row")
    func testSetHidesInviteCardLeavesOtherFlagsIntact() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ConversationLocalStateWriter(databaseWriter: dbManager.dbWriter)

        let conversationId = "convo-existing"
        try await dbManager.dbWriter.write { db in
            try Self.seedMinimalConversation(db, id: conversationId)
            try ConversationLocalState(
                conversationId: conversationId,
                isPinned: true,
                isUnread: true,
                isUnreadUpdatedAt: Date(),
                isMuted: true,
                pinnedOrder: 3,
                hidesInviteCard: false,
                wasRemoved: false
            ).insert(db)
        }

        try await writer.setHidesInviteCard(true, for: conversationId)

        let state = try Self.fetchLocalState(dbManager.dbReader, for: conversationId)
        #expect(state?.hidesInviteCard == true)
        #expect(state?.isPinned == true)
        #expect(state?.isUnread == true)
        #expect(state?.isMuted == true)
        #expect(state?.pinnedOrder == 3)
    }

    @Test("setHidesInviteCard(false) clears a previously-set flag")
    func testSetHidesInviteCardCanToggleOff() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ConversationLocalStateWriter(databaseWriter: dbManager.dbWriter)

        let conversationId = "convo-toggle"
        try await dbManager.dbWriter.write { db in
            try Self.seedMinimalConversation(db, id: conversationId)
        }

        try await writer.setHidesInviteCard(true, for: conversationId)
        try await writer.setHidesInviteCard(false, for: conversationId)

        let state = try Self.fetchLocalState(dbManager.dbReader, for: conversationId)
        #expect(state?.hidesInviteCard == false)
    }

    @Test("setHidesInviteCard throws conversationNotFound when the conversation row is missing")
    func testSetHidesInviteCardRequiresConversation() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = ConversationLocalStateWriter(databaseWriter: dbManager.dbWriter)

        await #expect(throws: ConversationLocalStateWriterError.conversationNotFound) {
            try await writer.setHidesInviteCard(true, for: "missing-convo")
        }
    }
}
