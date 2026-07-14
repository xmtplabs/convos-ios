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

        let result = try await batch.run(client: clientB, inboxId: inboxIdB, since: nil, activeConversationId: nil)

        // Headline assertions: the batch saw the conversation and at least
        // all N user messages. libxmtp emits group-membership update messages
        // alongside our content (the membership-add when B was invited), so
        // the actual stored count is `messageCount + 1` (or +N where N is
        // however many membership updates fired before we started sending).
        // What we care about: all the user content made it.
        #expect(result.conversationsProcessed == 1, "Expected 1 changed conversation, got \(result.conversationsProcessed)")
        #expect(result.messagesProcessed >= messageCount, "Expected at least \(messageCount) messages persisted, got \(result.messagesProcessed)")

        // Single transaction for the whole backlog persist + one post-commit
        // `setUnread` write that mirrors the stream path's tail in
        // `fetchAndStoreLatestMessages` (the conversation here has 25
        // messages from A, so it qualifies for unread marking on B) + one
        // catch-up cursor advance. The headline property is that the
        // *persist* is one transaction regardless of N messages — not that
        // the entire `run` does zero post-commit work.
        #expect(counter.commitCount == 3, "Expected exactly 3 committed transactions during batch.run (1 persist + 1 unread mark + 1 cursor advance), got \(counter.commitCount)")

        // Messages actually landed in B's DB.
        let storedMessageCount = try await fixtures.databaseManager.dbReader.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM message WHERE conversationId = ?
            """, arguments: [group.id])
        } ?? 0
        #expect(storedMessageCount >= messageCount, "Expected at least \(messageCount) message rows in DB, got \(storedMessageCount)")

        // Conversation row exists.
        let conversationStored = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, id: group.id)
        }
        #expect(conversationStored != nil, "Expected the group's DBConversation row to exist")

        try? await fixtures.cleanup()
    }

    @Test("History backfill re-ingests messages behind the catch-up cursor")
    func historyBackfillIgnoresCursors() async throws {
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

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxID],
            name: "Backfill Test Group"
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

        // First batch persists the conversation row - the state a freshly
        // paired installation is in right after welcomes are ingested.
        _ = try await batch.run(client: clientB, inboxId: inboxIdB, since: nil, activeConversationId: nil)

        // Now messages land in libxmtp's local database while the app-side
        // cursor sits ahead of their sentNs - the exact state a history-
        // archive import produces (imported messages keep their original,
        // older timestamps and emit no stream events).
        let messageCount = 3
        for i in 1...messageCount {
            _ = try await group.send(content: "Backfill msg \(i)")
        }
        let cursorNs = Int64(Date().nanosecondsSince1970)
        try await fixtures.databaseManager.dbWriter.write { db in
            try DBConversationCatchUpCursor.advance(to: cursorNs, for: group.id, in: db)
        }

        let storedBefore = try await fixtures.databaseManager.dbReader.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM message WHERE conversationId = ?
            """, arguments: [group.id])
        } ?? 0

        // A forward-only batch fetches afterNs: cursor and must miss the
        // older messages entirely - this is the bug shape the backfill
        // exists for.
        let forwardOnly = try await batch.run(client: clientB, inboxId: inboxIdB, since: nil, activeConversationId: nil)
        #expect(forwardOnly.messagesProcessed == 0, "Forward-only batch should see nothing behind the cursor, got \(forwardOnly.messagesProcessed)")

        // The backfill ignores the cursor and re-ingests everything.
        let backfill = try await batch.run(
            client: clientB,
            inboxId: inboxIdB,
            since: nil,
            activeConversationId: nil,
            fetchFromBeginning: true
        )
        #expect(backfill.messagesProcessed >= messageCount, "Backfill should ingest the \(messageCount) pre-cursor messages, got \(backfill.messagesProcessed)")

        let storedAfter = try await fixtures.databaseManager.dbReader.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM message WHERE conversationId = ?
            """, arguments: [group.id])
        } ?? 0
        #expect(storedAfter - storedBefore >= messageCount, "Expected the \(messageCount) pre-cursor messages to be new rows, got \(storedAfter - storedBefore) (before=\(storedBefore), after=\(storedAfter))")

        try? await fixtures.cleanup()
    }

    @Test("Batch does not mark the conversation the user is viewing as unread")
    func batchSkipsUnreadForActiveConversation() async throws {
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

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxID],
            name: "Active Conversation Group"
        )
        try await clientB.conversations.sync()

        let messageCount = 5
        for i in 1...messageCount {
            _ = try await group.send(content: "Active msg \(i)")
        }

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

        // The user is currently viewing this conversation, so the backlog
        // drain must persist the messages but skip the unread mark -- the
        // same gate the stream path applies in `StreamProcessor`.
        let result = try await batch.run(
            client: clientB,
            inboxId: inboxIdB,
            since: nil,
            activeConversationId: group.id
        )

        #expect(result.messagesProcessed >= messageCount, "Expected at least \(messageCount) messages persisted, got \(result.messagesProcessed)")
        // One transaction for the persist plus the catch-up cursor advance,
        // and crucially no transaction for an unread mark -- the
        // conversation is active.
        #expect(counter.commitCount == 2, "Expected exactly 2 committed transactions (persist + cursor advance, no unread mark) for the active conversation, got \(counter.commitCount)")

        let isUnread = try await fixtures.databaseManager.dbReader.read { db in
            try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == group.id)
                .fetchOne(db)?
                .isUnread ?? false
        }
        #expect(isUnread == false, "Active conversation should not be marked unread after batch catch-up")

        try? await fixtures.cleanup()
    }

    @Test("Batch routes thinking messages to the thinking-session store, not normal messages")
    func batchStoresThinkingViaSessionWriter() async throws {
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

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxID],
            name: "Thinking Group"
        )
        try await clientB.conversations.sync()

        // A sends one regular message and one thinking message.
        _ = try await group.send(content: "hello")
        let thinking = ThinkingContent(
            state: .start,
            targetMessageId: "target-message-1",
            content: "Thinking about hello"
        )
        let thinkingMessageId = try await group.send(
            encodedContent: try ThinkingCodec().encode(content: thinking)
        )

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

        _ = try await batch.run(client: clientB, inboxId: inboxIdB, since: nil, activeConversationId: nil)

        // The backlog thinking message lands in the thinking-session store...
        let thinkingMomentCount = try await fixtures.databaseManager.dbReader.read { db in
            try DBThinkingMoment
                .filter(DBThinkingMoment.Columns.conversationId == group.id)
                .fetchCount(db)
        }
        #expect(thinkingMomentCount == 1, "Expected the backlog thinking message to create one thinking moment, got \(thinkingMomentCount)")

        // ...and is not persisted as a normal chat message.
        let thinkingAsMessage = try await fixtures.databaseManager.dbReader.read { db in
            try DBMessage.filter(DBMessage.Columns.id == thinkingMessageId).fetchOne(db)
        }
        #expect(thinkingAsMessage == nil, "Thinking message must not be stored as a normal DBMessage")

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
            since: Date(timeIntervalSinceNow: 60),
            activeConversationId: nil
        )

        #expect(result.conversationsProcessed == 0, "Expected 0 changed conversations, got \(result.conversationsProcessed)")
        #expect(result.messagesProcessed == 0, "Expected 0 messages persisted, got \(result.messagesProcessed)")

        try? await fixtures.cleanup()
    }

    @Test("Catch-up does not skip read receipts older than the newest stored message")
    func catchUpFetchesReadReceiptBehindNewerStoredMessage() async throws {
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

        let group = try await clientA.conversations.newGroup(
            with: [clientB.inboxID],
            name: "Receipt Cursor Group"
        )
        try await clientB.conversations.sync()

        // Seed: one message from A, then a first catch-up so the
        // conversation, members, and catch-up cursor all exist locally.
        _ = try await group.send(content: "seed")

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
        _ = try await batch.run(client: clientB, inboxId: inboxIdB, since: nil, activeConversationId: nil)

        let seededCursor = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversationCatchUpCursor.caughtUpToNs(for: group.id, in: db)
        }
        #expect(seededCursor != nil, "First catch-up should seed the catch-up cursor")

        // While B is "offline": A reads (sends a read receipt), then a newer
        // regular message lands in B's DB via the NSE without any catch-up
        // running — so MAX(message.dateNs) moves ahead of the receipt while
        // the cursor stays put. Pre-cursor, the next catch-up cut at
        // MAX(message.dateNs) and skipped the receipt forever.
        _ = try await group.send(encodedContent: ReadReceiptCodec().encode(content: ReadReceipt()))
        _ = try await group.send(content: "newer than the receipt")

        let pushedDate = Date(timeIntervalSinceNow: 60)
        try await fixtures.databaseManager.dbWriter.write { db in
            try DBMessage(
                id: "nse-pushed-message",
                clientMessageId: "nse-pushed-message",
                conversationId: group.id,
                senderId: clientA.inboxID,
                dateNs: pushedDate.nanosecondsSince1970,
                date: pushedDate,
                sortId: 999,
                status: .published,
                messageType: .original,
                contentType: .text,
                text: "pushed while app was closed",
                emoji: nil,
                invite: nil,
                linkPreview: nil,
                sourceMessageId: nil,
                attachmentUrls: [],
                update: nil
            ).insert(db)
        }

        _ = try await batch.run(client: clientB, inboxId: inboxIdB, since: nil, activeConversationId: nil)

        // The read receipt behind the pushed message must have been fetched
        // and stored.
        let receipt = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversationReadReceipt
                .filter(
                    DBConversationReadReceipt.Columns.conversationId == group.id
                        && DBConversationReadReceipt.Columns.inboxId == clientA.inboxID
                )
                .fetchOne(db)
        }
        #expect(receipt != nil, "Read receipt older than the newest stored message must still be caught up")

        try? await fixtures.cleanup()
    }

    // Note: a multi-conversation parallel-fanout test belongs here too, but
    // libxmtp's `newGroup` doesn't set Convos invite tags (those come from
    // the `SignedInvite` -> `createPlaceholderConversation` flow), and the
    // `conversation.inviteTag` UNIQUE constraint rejects N groups all
    // sharing the empty default. Real-world conversations always have
    // unique invite tags from the invite-creation path, so this isn't a
    // production concern — just a test-rig gap. A multi-conv test would
    // need to drive group creation through `createPlaceholderConversation`
    // first, then have A send messages, then B catch up. Deferred.
}
