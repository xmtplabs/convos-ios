@testable import ConvosCore
import Foundation
import GRDB
import Testing
import XMTPiOS

/// Tests for clientConversationId priority logic in ConversationWriter
///
/// When a conversation is saved and there's an existing conversation with the same
/// inviteTag but different clientConversationId, the following priority is applied:
/// 1. If incoming has a draft ID (starts with "draft-"), use incoming
/// 2. Otherwise keep existing
///
/// This ensures that draft IDs (used for image caching and default emoji) are
/// preserved regardless of the order in which stream processing and explicit
/// conversation creation occur.
@Suite("clientConversationId Priority Tests")
struct ClientConversationIdPriorityTests {
    private enum TestError: Error {
        case missingClients
    }

    // MARK: - DBConversation.isDraft Tests

    @Test("isDraft returns true for draft prefixed IDs")
    func testIsDraftReturnsTrueForDraftPrefix() {
        let draftId = DBConversation.generateDraftConversationId()
        #expect(DBConversation.isDraft(id: draftId))
        #expect(draftId.hasPrefix("draft-"))
    }

    @Test("isDraft returns false for XMTP group IDs")
    func testIsDraftReturnsFalseForXMTPIds() {
        let xmtpId = "ab0072d354857faceec1d5864e259ac1"
        #expect(!DBConversation.isDraft(id: xmtpId))
    }

    @Test("isDraft returns false for UUID strings")
    func testIsDraftReturnsFalseForUUIDs() {
        let uuidId = UUID().uuidString
        #expect(!DBConversation.isDraft(id: uuidId))
    }

    @Test("generateDraftConversationId creates unique IDs")
    func testGenerateDraftConversationIdCreatesUniqueIds() {
        let id1 = DBConversation.generateDraftConversationId()
        let id2 = DBConversation.generateDraftConversationId()
        #expect(id1 != id2)
        #expect(DBConversation.isDraft(id: id1))
        #expect(DBConversation.isDraft(id: id2))
    }

    // MARK: - Integration Tests (ConversationWriter)

    @Test("Store with draft ID after stream stored with XMTP ID preserves draft ID")
    func testStoreWithDraftIdAfterStreamPreservesDraftId() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB,
              let clientIdA = fixtures.clientIdA else {
            throw TestError.missingClients
        }

        let inboxIdA = clientA.inboxID

        // Insert DBInbox record so ConversationWriter can look it up
        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date()).insert(db)
        }

        // Create a group
        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxId],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        let conversationId = group.id

        // Create ConversationWriter
        let mockMessageWriter = MockIncomingMessageWriter()
        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: mockMessageWriter
        )

        // First store: simulate stream processing (uses XMTP group ID as clientConversationId)
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil // Stream doesn't pass a draft ID
        )

        // Verify initial clientConversationId equals the conversation ID
        let afterStream = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        #expect(afterStream?.clientConversationId == conversationId)

        // Second store: simulate explicit creation with draft ID
        let draftId = DBConversation.generateDraftConversationId()
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: draftId
        )

        // Verify draft ID took priority
        let afterExplicit = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        #expect(afterExplicit?.clientConversationId == draftId)

        try? await fixtures.cleanup()
    }

    @Test("Store with XMTP ID after draft ID was stored preserves draft ID")
    func testStoreWithXmtpIdAfterDraftPreservesDraftId() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB,
              let clientIdA = fixtures.clientIdA else {
            throw TestError.missingClients
        }

        let inboxIdA = clientA.inboxID

        // Insert DBInbox record so ConversationWriter can look it up
        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date()).insert(db)
        }

        // Create a group
        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxId],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        let conversationId = group.id

        // Create ConversationWriter
        let mockMessageWriter = MockIncomingMessageWriter()
        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: mockMessageWriter
        )

        // First store: simulate explicit creation with draft ID
        let draftId = DBConversation.generateDraftConversationId()
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: draftId
        )

        // Verify draft ID was stored
        let afterExplicit = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        #expect(afterExplicit?.clientConversationId == draftId)

        // Second store: simulate stream processing (uses XMTP group ID)
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil // Stream doesn't pass a draft ID
        )

        // Verify draft ID was preserved (not overwritten by stream)
        let afterStream = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        #expect(afterStream?.clientConversationId == draftId)

        try? await fixtures.cleanup()
    }

    @Test("Multiple stores without draft ID keep first clientConversationId")
    func testMultipleStoresWithoutDraftKeepFirst() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB,
              let clientIdA = fixtures.clientIdA else {
            throw TestError.missingClients
        }

        let inboxIdA = clientA.inboxID

        // Insert DBInbox record so ConversationWriter can look it up
        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date()).insert(db)
        }

        // Create a group
        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxId],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        let conversationId = group.id

        // Create ConversationWriter
        let mockMessageWriter = MockIncomingMessageWriter()
        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: mockMessageWriter
        )

        // First store without draft ID
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil
        )

        let afterFirst = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        let firstClientConversationId = afterFirst?.clientConversationId
        #expect(firstClientConversationId == conversationId)

        // Second store without draft ID (simulates another stream event)
        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil
        )

        // Verify original clientConversationId was preserved
        let afterSecond = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        #expect(afterSecond?.clientConversationId == firstClientConversationId)

        try? await fixtures.cleanup()
    }
}
