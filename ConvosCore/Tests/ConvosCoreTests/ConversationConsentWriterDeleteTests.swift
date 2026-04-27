@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Coverage for `ConversationConsentWriter.delete(conversation:)` — the path
/// that powers the conversations-list "Delete" action. The writer must flip
/// the local DB row's `consent` column to `.denied` so that the next
/// `ConversationsRepository(for: [.allowed])` emit filters the row out and
/// the delete survives an app restart.
@Suite("ConversationConsentWriter delete persistence", .serialized)
struct ConversationConsentWriterDeleteTests {
    @Test("delete(conversation:) writes consent=.denied to the local DB row")
    func deleteFlipsConsentToDenied() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conv-delete-1"
        try seedAllowedConversation(in: dbManager.dbWriter, conversationId: conversationId)

        let writer = ConversationConsentWriter(
            sessionStateManager: MockSessionStateManager(),
            databaseWriter: dbManager.dbWriter
        )

        try await writer.delete(conversation: .mock(id: conversationId))

        let stored = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        #expect(stored?.consent == .denied)
    }

    @Test("delete(conversation:) no-ops cleanly when the DB row is missing")
    func deleteWithMissingRowIsNoOp() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        let writer = ConversationConsentWriter(
            sessionStateManager: MockSessionStateManager(),
            databaseWriter: dbManager.dbWriter
        )

        try await writer.delete(conversation: .mock(id: "conv-missing"))

        let stored = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: "conv-missing")
        }
        #expect(stored == nil)
    }

    @Test("After delete, a fetch filtered on [.allowed] no longer returns the row")
    func repositoryFilterExcludesDeniedRow() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let conversationId = "conv-delete-2"
        try seedAllowedConversation(in: dbManager.dbWriter, conversationId: conversationId)

        let beforeDelete = try await dbManager.dbReader.read { db in
            try DBConversation
                .filter([Consent.allowed].contains(DBConversation.Columns.consent))
                .filter(DBConversation.Columns.id == conversationId)
                .fetchOne(db)
        }
        #expect(beforeDelete?.consent == .allowed)

        let writer = ConversationConsentWriter(
            sessionStateManager: MockSessionStateManager(),
            databaseWriter: dbManager.dbWriter
        )
        try await writer.delete(conversation: .mock(id: conversationId))

        let afterDelete = try await dbManager.dbReader.read { db in
            try DBConversation
                .filter([Consent.allowed].contains(DBConversation.Columns.consent))
                .filter(DBConversation.Columns.id == conversationId)
                .fetchOne(db)
        }
        #expect(afterDelete == nil)
    }
}

// MARK: - Helpers

private func seedAllowedConversation(
    in writer: any DatabaseWriter,
    conversationId: String
) throws {
    try writer.write { db in
        try DBConversation(
            id: conversationId,
            clientConversationId: "client-\(conversationId)",
            inviteTag: "invite-\(conversationId)",
            creatorId: "inbox-1",
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
            hasHadVerifiedAssistant: false,
        ).insert(db)
    }
}
