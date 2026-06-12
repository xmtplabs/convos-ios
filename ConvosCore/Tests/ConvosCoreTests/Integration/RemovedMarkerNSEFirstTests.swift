@testable import ConvosCore
import Foundation
import GRDB
import Testing
@preconcurrency import XMTPiOS

/// NSE-first convergence for the removed-from-conversation marker, against a
/// local XMTP node (`./dev/up`). When the Notification Service Extension
/// saves the removal `GroupUpdated` message row first, the main app
/// re-encounters it as an existing row (`messageAlreadyExists == true`) and
/// must still persist the removed marker - the marker logic is deliberately
/// independent of row existence. Regression coverage for the 2026-06-04
/// incident where removal handling keyed off "new row" and a relaunch
/// resurrected a dead conversation.
@Suite("Removed marker NSE-first Integration Tests", .serialized)
struct RemovedMarkerNSEFirstTests {
    private enum TestError: Error {
        case missingClients
        case missingRemovalMessage
    }

    @Test("Re-storing an existing removal message still persists the marker")
    func markerConvergesWhenMessageRowAlreadyExists() async throws {
        let fixtures = TestFixtures()
        try await fixtures.createTestClients()

        guard let clientA = fixtures.clientA as? Client,
              let clientB = fixtures.clientB as? Client,
              let clientIdB = fixtures.clientIdB else {
            throw TestError.missingClients
        }
        let inboxIdB = clientB.inboxID

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: inboxIdB, clientId: clientIdB, createdAt: Date()).insert(db)
        }

        // A creates a group with B; B syncs and persists its local view of
        // the conversation (so the message row insert below has its parent).
        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxID],
            name: "Removal Group"
        )
        try await clientB.conversations.sync()
        let groupB = try #require(try clientB.conversations.listGroups().first { $0.id == group.id })

        let messageWriter = IncomingMessageWriter(databaseWriter: fixtures.databaseManager.dbWriter)
        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: messageWriter
        )
        _ = try await conversationWriter.store(
            conversation: groupB,
            inboxId: inboxIdB
        )

        // A removes B; B syncs so libxmtp processes the removal commit and
        // materializes the GroupUpdated message naming B locally. The group
        // is inactive for B afterwards, so further syncs may throw - the
        // message list read below is local-only.
        _ = try await group.removeMembers(inboxIds: [clientB.inboxID])
        try? await groupB.sync()
        try? await clientB.conversations.sync()

        let recentMessages = try await groupB.messages(limit: 20, direction: .descending)
        var foundMessage: XMTPiOS.DecodedMessage?
        var foundDBMessage: DBMessage?
        for message in recentMessages {
            guard let dbMessage = try? message.dbRepresentation(),
                  dbMessage.update?.removedInboxIds.contains(inboxIdB) == true else { continue }
            foundMessage = message
            foundDBMessage = dbMessage
            break
        }
        guard let removalMessage = foundMessage, let removalDBMessage = foundDBMessage else {
            throw TestError.missingRemovalMessage
        }

        // Simulate the NSE having saved the message row first: insert the
        // row directly, without any of the writer's side effects. The marker
        // must still be unset at this point.
        try await fixtures.databaseManager.dbWriter.write { db in
            try removalDBMessage.save(db)
        }
        let stateBeforeStore = try await fixtures.databaseManager.dbReader.read { db in
            try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == group.id)
                .fetchOne(db)
        }
        #expect(stateBeforeStore?.wasRemoved != true, "Direct row insert must not set the marker")

        // Main app re-encounters the same message through the writer.
        let dbConversation = try #require(try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: group.id)
        })
        let result = try await messageWriter.store(message: removalMessage, for: dbConversation)

        #expect(result.messageAlreadyExists, "The NSE-saved row should be seen as existing")
        #expect(result.wasRemovedFromConversation, "Removal detection must not key off row novelty")
        let stateAfterStore = try await fixtures.databaseManager.dbReader.read { db in
            try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == group.id)
                .fetchOne(db)
        }
        #expect(stateAfterStore?.wasRemoved == true, "Marker must converge on the existing-row path")

        try? await fixtures.cleanup()
    }
}
