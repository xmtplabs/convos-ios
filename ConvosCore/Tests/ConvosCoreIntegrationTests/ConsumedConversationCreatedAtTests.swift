@testable import ConvosCore
import Foundation
import GRDB
import Testing
import XMTPiOS

@Suite("Consumed Conversation createdAt Preservation Tests")
struct ConsumedConversationCreatedAtTests {
    private enum TestError: Error {
        case missingClients
    }

    @Test("Re-storing a consumed conversation preserves its createdAt")
    func testRestorePreservesCreatedAtForConsumedConversation() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB,
              let clientIdA = fixtures.clientIdA else {
            throw TestError.missingClients
        }

        let inboxIdA = clientA.inboxID

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date()).insert(db)
        }

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxId],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        let conversationId = group.id

        let mockMessageWriter = MockIncomingMessageWriter()
        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: mockMessageWriter
        )

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil
        )

        let xmtpCreatedAt = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)?.createdAt
        }
        #expect(xmtpCreatedAt != nil)

        let consumedAt = Date()
        try await fixtures.databaseManager.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE conversation SET isUnused = ?, createdAt = ? WHERE id = ?",
                arguments: [false, consumedAt, conversationId]
            )
        }

        let afterConsume = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        #expect(afterConsume?.isUnused == false)
        let storedConsumedAt = try #require(afterConsume?.createdAt)
        #expect(abs(storedConsumedAt.timeIntervalSince(consumedAt)) < 1)

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil
        )

        let afterRestore = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        let finalCreatedAt = try #require(afterRestore?.createdAt)
        #expect(abs(finalCreatedAt.timeIntervalSince(consumedAt)) < 1)

        try? await fixtures.cleanup()
    }

    @Test("Re-storing an unused conversation does not preserve its createdAt")
    func testRestoreDoesNotPreserveCreatedAtForUnusedConversation() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB,
              let clientIdA = fixtures.clientIdA else {
            throw TestError.missingClients
        }

        let inboxIdA = clientA.inboxID

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdA, clientId: clientIdA, createdAt: Date()).insert(db)
        }

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxId],
            name: "Test Group",
            imageUrl: "",
            description: ""
        )
        let conversationId = group.id

        let mockMessageWriter = MockIncomingMessageWriter()
        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: mockMessageWriter
        )

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil
        )

        try await fixtures.databaseManager.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE conversation SET isUnused = ? WHERE id = ?",
                arguments: [true, conversationId]
            )
        }

        _ = try await conversationWriter.store(
            conversation: group,
            inboxId: inboxIdA,
            clientConversationId: nil
        )

        let afterRestore = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: conversationId)
        }
        let finalCreatedAt = try #require(afterRestore?.createdAt)
        #expect(abs(finalCreatedAt.timeIntervalSince(group.createdAt)) < 1)

        try? await fixtures.cleanup()
    }
}
