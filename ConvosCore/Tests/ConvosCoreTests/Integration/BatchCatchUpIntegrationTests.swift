@testable import ConvosCore
import Foundation
import GRDB
import Testing
@preconcurrency import XMTPiOS

/// Integration tests for `BatchCatchUp` that exercise the full batched
/// catch-up flow against a local XMTP node (`./dev/up`). These verify the
/// foreground / cold-start backlog drain shape: client B is "offline" (no
/// stream, no per-event processing) while client A sends N messages to a
/// shared group; `BatchCatchUp.run` then drains the backlog into B's local
/// DB in one transaction.
///
/// The single-transaction property is asserted by counting GRDB
/// `didCommit` events during `run`. Stream-replay redelivery after the
/// batch returns is out of scope for these tests — that's covered by the
/// no-op save short-circuit in #857 and DBMessage primary-key INSERT OR
/// REPLACE semantics, both of which already have unit coverage.
@Suite("BatchCatchUp Integration Tests", .serialized)
struct BatchCatchUpIntegrationTests {
    private enum TestError: Error {
        case missingClients
    }

    /// Counts committed write transactions on a GRDB database. Used by the
    /// tests below to assert "one transaction for the whole backlog".
    private final class CommitCounter: TransactionObserver, @unchecked Sendable {
        private(set) var commitCount: Int = 0

        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
        func databaseDidChange(with event: DatabaseEvent) {}
        func databaseDidCommit(_ db: Database) {
            commitCount += 1
        }
        func databaseDidRollback(_ db: Database) {}
    }

    @Test("Batch fetches and persists all missed messages in one transaction")
    func batchCatchesUpMissedMessagesInOneTransaction() async throws {
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

        // A creates a group with B; A sends N messages.
        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxID],
            name: "Batch Test Group"
        )
        // Sync B once so its libxmtp installation receives the welcome and
        // is registered as a group member. This is "before the device went
        // offline" — analogous to the iOS app having joined the conversation
        // in a prior session.
        try await clientB.conversations.sync()

        let messageCount = 25
        for i in 1...messageCount {
            _ = try await group.send(content: "Batch msg \(i)")
        }
        // Critically: do NOT sync B again. The next sync runs inside
        // `BatchCatchUp.run` and feeds messages into the batched persist.

        // Wire writers + coordinator the way SyncingManager does for the
        // foreground hook (commit d09e7639). Stateless wrappers around the
        // test database.
        let messageWriter = IncomingMessageWriter(databaseWriter: fixtures.databaseManager.dbWriter)
        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: messageWriter
        )
        let batch = BatchCatchUp(
            conversationWriter: conversationWriter,
            messageWriter: messageWriter,
            databaseWriter: fixtures.databaseManager.dbWriter
        )

        // Snapshot the commit count before `run`, then register the observer.
        // We only care about commits that happen *during* the batch — anything
        // before doesn't matter.
        let counter = CommitCounter()
        fixtures.databaseManager.dbWriter.add(transactionObserver: counter)

        let result = try await batch.run(client: clientB, inboxId: inboxIdB, since: nil)

        // Headline assertions: the batch saw the conversation and all N messages.
        #expect(result.conversationsProcessed == 1, "Expected 1 changed conversation, got \(result.conversationsProcessed)")
        #expect(result.messagesProcessed == messageCount, "Expected \(messageCount) messages persisted, got \(result.messagesProcessed)")

        // Single transaction for the whole backlog. The batched persist is
        // `databaseWriter.write { db in ... persist all conversations + all
        // messages ... }` — exactly one commit, regardless of N.
        #expect(counter.commitCount == 1, "Expected exactly 1 committed transaction during batch.run, got \(counter.commitCount)")

        // Messages actually landed in B's DB.
        let storedMessageCount = try await fixtures.databaseManager.dbReader.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM message WHERE conversationId = ?
            """, arguments: [group.id])
        } ?? 0
        #expect(storedMessageCount == messageCount, "Expected \(messageCount) message rows in DB, got \(storedMessageCount)")

        // Conversation row exists.
        let conversationStored = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: group.id)
        }
        #expect(conversationStored != nil, "Expected the group's DBConversation row to exist")

        try? await fixtures.cleanup()
    }

    @Test("Batch with no missed activity is a near no-op")
    func batchWithEmptyBacklogIsNoOp() async throws {
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

        // A creates a group with B, no messages.
        _ = try await clientA.conversations.newGroup(
            with: [clientB.inboxID],
            name: "Empty Group"
        )
        try await clientB.conversations.sync()

        let messageWriter = IncomingMessageWriter(databaseWriter: fixtures.databaseManager.dbWriter)
        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: messageWriter
        )
        let batch = BatchCatchUp(
            conversationWriter: conversationWriter,
            messageWriter: messageWriter,
            databaseWriter: fixtures.databaseManager.dbWriter
        )

        // Pass a `since` in the future so list returns nothing.
        let result = try await batch.run(
            client: clientB,
            inboxId: inboxIdB,
            since: Date(timeIntervalSinceNow: 60)
        )

        #expect(result.conversationsProcessed == 0, "Expected 0 changed conversations, got \(result.conversationsProcessed)")
        #expect(result.messagesProcessed == 0, "Expected 0 messages persisted, got \(result.messagesProcessed)")

        try? await fixtures.cleanup()
    }

    @Test("Batch fans out across N conversations in parallel")
    func batchHandlesMultipleConversationsConcurrently() async throws {
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

        // A creates 3 groups with B; sends a few messages in each.
        var groupIds: [String] = []
        for groupIndex in 1...3 {
            let group = try await clientA.conversations.newGroup(
                with: [clientB.inboxID],
                name: "Multi Group \(groupIndex)"
            )
            groupIds.append(group.id)
            for i in 1...5 {
                _ = try await group.send(content: "G\(groupIndex) msg \(i)")
            }
        }

        // B syncs ONCE so it has the welcomes — but doesn't pull the messages
        // (no per-conv `.messages(...)` call). The messages are what the
        // batch should fetch.
        try await clientB.conversations.sync()

        let messageWriter = IncomingMessageWriter(databaseWriter: fixtures.databaseManager.dbWriter)
        let conversationWriter = ConversationWriter(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            messageWriter: messageWriter
        )
        let batch = BatchCatchUp(
            conversationWriter: conversationWriter,
            messageWriter: messageWriter,
            databaseWriter: fixtures.databaseManager.dbWriter
        )

        let counter = CommitCounter()
        fixtures.databaseManager.dbWriter.add(transactionObserver: counter)

        let result = try await batch.run(client: clientB, inboxId: inboxIdB, since: nil)

        #expect(result.conversationsProcessed == 3, "Expected 3 conversations, got \(result.conversationsProcessed)")
        #expect(result.messagesProcessed == 15, "Expected 15 messages across 3 groups, got \(result.messagesProcessed)")
        #expect(counter.commitCount == 1, "Expected exactly 1 commit for the whole 3-group backlog, got \(counter.commitCount)")

        // Each group's messages should be in B's DB.
        for groupId in groupIds {
            let count = try await fixtures.databaseManager.dbReader.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM message WHERE conversationId = ?
                """, arguments: [groupId])
            } ?? 0
            #expect(count == 5, "Expected 5 messages in \(groupId), got \(count)")
        }

        try? await fixtures.cleanup()
    }
}
