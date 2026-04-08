@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Tests for ConversationLocalStateWriter
///
/// Covers the inactive conversation mode introduced for post-restore handling:
/// - setActive(_:for:) toggles the per-conversation flag
/// - markAllConversationsInactive() bulk-flips every row in one transaction
@Suite("ConversationLocalStateWriter Tests")
struct ConversationLocalStateWriterTests {
    @Test("setActive flips a single conversation between active and inactive")
    func testSetActiveTogglesSingleConversation() async throws {
        let fixtures = TestFixtures()
        let writer = ConversationLocalStateWriter(databaseWriter: fixtures.databaseManager.dbWriter)

        let conversationId = try await seedConversation(in: fixtures, id: "conv-1")

        try await writer.setActive(false, for: conversationId)
        let inactive = try await fetchLocalState(in: fixtures, conversationId: conversationId)
        #expect(inactive?.isActive == false)

        try await writer.setActive(true, for: conversationId)
        let active = try await fetchLocalState(in: fixtures, conversationId: conversationId)
        #expect(active?.isActive == true)

        try? await fixtures.cleanup()
    }

    @Test("setActive throws when conversation does not exist")
    func testSetActiveThrowsForUnknownConversation() async throws {
        let fixtures = TestFixtures()
        let writer = ConversationLocalStateWriter(databaseWriter: fixtures.databaseManager.dbWriter)

        await #expect(throws: ConversationLocalStateWriterError.self) {
            try await writer.setActive(false, for: "missing")
        }

        try? await fixtures.cleanup()
    }

    @Test("markAllConversationsInactive flips every existing row in one pass")
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

    @Test("markAllConversationsInactive is a no-op when there are no rows")
    func testMarkAllConversationsInactiveOnEmptyDatabase() async throws {
        let fixtures = TestFixtures()
        let writer = ConversationLocalStateWriter(databaseWriter: fixtures.databaseManager.dbWriter)

        try await writer.markAllConversationsInactive()

        let count = try await fixtures.databaseManager.dbReader.read { db in
            try ConversationLocalState.fetchCount(db)
        }
        #expect(count == 0)

        try? await fixtures.cleanup()
    }

    @Test("setActive on one conversation does not affect another")
    func testSetActiveIsScopedToSingleConversation() async throws {
        let fixtures = TestFixtures()
        let writer = ConversationLocalStateWriter(databaseWriter: fixtures.databaseManager.dbWriter)

        let firstId = try await seedConversation(in: fixtures, id: "conv-x")
        let secondId = try await seedConversation(in: fixtures, id: "conv-y")

        try await writer.setActive(false, for: firstId)

        let firstState = try await fetchLocalState(in: fixtures, conversationId: firstId)
        let secondState = try await fetchLocalState(in: fixtures, conversationId: secondId)
        #expect(firstState?.isActive == false)
        #expect(secondState?.isActive == true)

        try? await fixtures.cleanup()
    }

    // MARK: - Helpers

    private func seedConversation(in fixtures: TestFixtures, id: String) async throws -> String {
        try await fixtures.databaseManager.dbWriter.write { db in
            let conversation = DBConversation(
                id: id,
                inboxId: "inbox-\(id)",
                clientId: "client-\(id)",
                clientConversationId: id,
                inviteTag: "tag-\(id)",
                creatorId: "inbox-\(id)",
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
                imageLastRenewed: nil,
                isUnused: false
            )
            try conversation.save(db)

            let localState = ConversationLocalState(
                conversationId: id,
                isPinned: false,
                isUnread: false,
                isUnreadUpdatedAt: Date.distantPast,
                isMuted: false,
                pinnedOrder: nil,
                isActive: true
            )
            try localState.save(db)
        }
        return id
    }

    private func fetchLocalState(
        in fixtures: TestFixtures,
        conversationId: String
    ) async throws -> ConversationLocalState? {
        try await fixtures.databaseManager.dbReader.read { db in
            try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == conversationId)
                .fetchOne(db)
        }
    }
}
