@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// `ConversationLocalStateWriter` — post-restore inactive-conversation API.
///
/// Covers the two new operations introduced by PR 2 of the backup stack:
/// `setActive(_:for:)` toggles a single row, `markAllConversationsInactive`
/// bulk-flips every row in one transaction for `RestoreManager`.
@Suite("ConversationLocalStateWriter Tests")
struct ConversationLocalStateWriterTests {
    @Test("setActive flips a single conversation between active and inactive")
    func testSetActiveTogglesSingleConversation() async throws {
        let fixtures = TestFixtures()
        let writer = ConversationLocalStateWriter(databaseWriter: fixtures.databaseManager.dbWriter)
        let id = try await seedConversation(in: fixtures, id: "conv-1")

        try await writer.setActive(false, for: id)
        let afterFalse = try await fetchLocalState(in: fixtures, conversationId: id)
        #expect(afterFalse?.isActive == false)

        try await writer.setActive(true, for: id)
        let afterTrue = try await fetchLocalState(in: fixtures, conversationId: id)
        #expect(afterTrue?.isActive == true)

        try? await fixtures.cleanup()
    }

    @Test("setActive throws when the conversation doesn't exist")
    func testSetActiveThrowsForUnknownConversation() async throws {
        let fixtures = TestFixtures()
        let writer = ConversationLocalStateWriter(databaseWriter: fixtures.databaseManager.dbWriter)

        await #expect(throws: ConversationLocalStateWriterError.self) {
            try await writer.setActive(false, for: "does-not-exist")
        }

        try? await fixtures.cleanup()
    }

    @Test("markAllConversationsInactive flips every existing row")
    func testMarkAllConversationsInactive() async throws {
        let fixtures = TestFixtures()
        let writer = ConversationLocalStateWriter(databaseWriter: fixtures.databaseManager.dbWriter)
        let ids = ["conv-a", "conv-b", "conv-c"]
        for id in ids {
            _ = try await seedConversation(in: fixtures, id: id)
        }

        try await writer.markAllConversationsInactive()

        for id in ids {
            let state = try await fetchLocalState(in: fixtures, conversationId: id)
            #expect(state?.isActive == false, "expected \(id) to be inactive")
        }

        try? await fixtures.cleanup()
    }

    @Test("markAllConversationsInactive is a no-op on empty database")
    func testMarkAllConversationsInactiveOnEmpty() async throws {
        let fixtures = TestFixtures()
        let writer = ConversationLocalStateWriter(databaseWriter: fixtures.databaseManager.dbWriter)

        try await writer.markAllConversationsInactive()

        let count = try await fixtures.databaseManager.dbReader.read { db in
            try ConversationLocalState.fetchCount(db)
        }
        #expect(count == 0)

        try? await fixtures.cleanup()
    }

    @Test("setActive on one conversation doesn't touch another")
    func testSetActiveIsScoped() async throws {
        let fixtures = TestFixtures()
        let writer = ConversationLocalStateWriter(databaseWriter: fixtures.databaseManager.dbWriter)
        let a = try await seedConversation(in: fixtures, id: "conv-x")
        let b = try await seedConversation(in: fixtures, id: "conv-y")

        try await writer.setActive(false, for: a)

        let stateA = try await fetchLocalState(in: fixtures, conversationId: a)
        let stateB = try await fetchLocalState(in: fixtures, conversationId: b)
        #expect(stateA?.isActive == false)
        #expect(stateB?.isActive == true)

        try? await fixtures.cleanup()
    }

    // MARK: - Helpers

    private func seedConversation(in fixtures: TestFixtures, id: String) async throws -> String {
        try await fixtures.databaseManager.dbWriter.write { db in
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
            try ConversationLocalState(
                conversationId: id,
                isPinned: false,
                isUnread: false,
                isUnreadUpdatedAt: Date(),
                isMuted: false,
                pinnedOrder: nil,
                isActive: true
            ).insert(db)
        }
        return id
    }

    private func fetchLocalState(in fixtures: TestFixtures, conversationId: String) async throws -> ConversationLocalState? {
        try await fixtures.databaseManager.dbReader.read { db in
            try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == conversationId)
                .fetchOne(db)
        }
    }
}
