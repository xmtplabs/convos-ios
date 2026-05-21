import Foundation
import GRDB
@preconcurrency import XMTPiOS

struct BatchCatchUpResult: Sendable {
    let conversationsProcessed: Int
    let messagesProcessed: Int
    let durationSeconds: Double
}

/// Drains the backlog of conversation/message activity that arrived while
/// the app was backgrounded or killed, *before* streams resume — so the
/// foreground stream restart doesn't re-deliver the backlog as per-event
/// traffic. Replaces N writes / N observer fires / N SwiftUI re-renders
/// with one of each.
///
/// Flow:
/// 1. `client.conversationsProvider.listGroups(lastActivityAfterNs:)`
///    discovers conversations that had activity since the cursor.
/// 2. Per conversation, in parallel:
///    - Read the local `MAX(message.dateNs)` for that conversation
///    - `Group.messages(afterNs:)` to fetch the backlog from XMTP
///    - Filter to "regular" messages (text, attachments, link previews,
///      updates) — reactions, typing indicators, read receipts, and
///      profile messages have their own per-event handlers that
///      activate once the stream takes over after the batch returns.
///    - Build a `PreparedConversation` + `[PreparedIncomingMessage]`
///      via the writers' prepare phases. All transaction-free.
/// 3. Open ONE `databaseWriter.write` and persist every prepared
///    conversation + its prepared messages inside that single
///    transaction. One observer fire, one SwiftUI re-render.
/// 4. After the transaction commits, fire per-conversation side
///    effects (prefetch + invite generation) off the critical path so
///    they don't block the foreground hook.
///
/// Stream redelivery after the batch returns is free thanks to:
/// - `saveConversation`'s no-op diff short-circuit (#857)
/// - `DBMessage` primary-key INSERT OR REPLACE semantics
/// - Reaction handler existence checks
actor BatchCatchUp {
    private let conversationWriter: ConversationWriter
    private let messageWriter: IncomingMessageWriter
    private let databaseWriter: any DatabaseWriter

    init(
        conversationWriter: ConversationWriter,
        messageWriter: IncomingMessageWriter,
        databaseWriter: any DatabaseWriter
    ) {
        self.conversationWriter = conversationWriter
        self.messageWriter = messageWriter
        self.databaseWriter = databaseWriter
    }

    /// Run the batch catch-up against the given client. `since` is the
    /// cursor — typically the value persisted by the NSE in
    /// `lastWelcomeProcessed`. A `nil` cursor means "fetch everything
    /// available" (cold launch).
    func run(
        client: any XMTPClientProvider,
        inboxId: String,
        since: Date?
    ) async throws -> BatchCatchUpResult {
        let started = CFAbsoluteTimeGetCurrent()
        let cursorNs: Int64? = since.map { Int64($0.nanosecondsSince1970) }

        let groups = try client.conversationsProvider.listGroups(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityAfterNs: cursorNs,
            lastActivityBeforeNs: nil,
            limit: nil,
            consentStates: [.allowed, .unknown],
            orderBy: .lastActivity
        )

        guard !groups.isEmpty else {
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            Log.info("[PERF] catchup.batch.messages: \(Int(elapsed * 1000))ms convs=0 messages=0")
            return BatchCatchUpResult(conversationsProcessed: 0, messagesProcessed: 0, durationSeconds: elapsed)
        }

        // Phase 1: parallel prepare (network-bound, transaction-free).
        let prepared = try await prepareAll(groups: groups, inboxId: inboxId)

        // Phase 2: single-transaction persist.
        try await databaseWriter.write { [conversationWriter, messageWriter] db in
            for entry in prepared {
                _ = try conversationWriter.persist(entry.conversation, in: db)
                for preparedMessage in entry.messages {
                    _ = try messageWriter.persist(
                        preparedMessage,
                        conversation: entry.conversation.dbConversation,
                        in: db
                    )
                }
            }
        }

        // Phase 3: per-conversation side effects, off the foreground critical
        // path. Same helpers the stream path runs after each individual save.
        Task.detached(priority: .background) { [conversationWriter] in
            for entry in prepared {
                await conversationWriter.runPostPersistSideEffects(
                    prepared: entry.conversation,
                    group: entry.group
                )
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let totalMessages = prepared.reduce(0) { $0 + $1.messages.count }
        Log.info("[PERF] catchup.batch.messages: \(Int(elapsed * 1000))ms convs=\(prepared.count) messages=\(totalMessages)")
        return BatchCatchUpResult(
            conversationsProcessed: prepared.count,
            messagesProcessed: totalMessages,
            durationSeconds: elapsed
        )
    }

    // MARK: - Private

    private struct PreparedEntry {
        let group: XMTPiOS.Group
        let conversation: ConversationWriter.PreparedConversation
        let messages: [IncomingMessageWriter.PreparedIncomingMessage]
    }

    private func prepareAll(
        groups: [XMTPiOS.Group],
        inboxId: String
    ) async throws -> [PreparedEntry] {
        try await withThrowingTaskGroup(of: PreparedEntry.self) { [conversationWriter, messageWriter, databaseWriter] taskGroup in
            for group in groups {
                taskGroup.addTask {
                    let preparedConv = try await conversationWriter.prepare(
                        conversation: group,
                        inboxId: inboxId
                    )

                    let perConvCursorNs = try await Self.readLastMessageNs(
                        for: group.id,
                        in: databaseWriter
                    )
                    let allMessages = try await group.messages(afterNs: perConvCursorNs)
                    let storable = allMessages.filter { Self.isStorableForBatch($0) }
                    var preparedMessages: [IncomingMessageWriter.PreparedIncomingMessage] = []
                    preparedMessages.reserveCapacity(storable.count)
                    for message in storable {
                        let prepared = try await messageWriter.prepare(message: message)
                        preparedMessages.append(prepared)
                    }

                    return PreparedEntry(
                        group: group,
                        conversation: preparedConv,
                        messages: preparedMessages
                    )
                }
            }

            var results: [PreparedEntry] = []
            for try await entry in taskGroup {
                results.append(entry)
            }
            return results
        }
    }

    /// Only batch messages that go through the regular `IncomingMessageWriter.persist` path.
    /// Reactions, typing indicators, read receipts, and profile messages have their own
    /// per-event handlers that pick them up via the stream after the batch returns.
    private static func isStorableForBatch(_ message: XMTPiOS.DecodedMessage) -> Bool {
        if message.isProfileMessage || message.isTypingIndicator || message.isReadReceipt {
            return false
        }
        guard let contentType = try? message.encodedContent.type else {
            return false
        }
        if contentType == ContentTypeReaction || contentType == ContentTypeReactionV2 {
            return false
        }
        return true
    }

    /// `MAX(dateNs)` for the conversation, or `0` when the local DB has no messages
    /// for this conversation yet (cold/new). Mirrors the cursor `fetchAndStoreLatestMessages`
    /// uses today on the stream catch-up path.
    private static func readLastMessageNs(
        for conversationId: String,
        in databaseWriter: any DatabaseWriter
    ) async throws -> Int64 {
        try await databaseWriter.read { db in
            let value: Int64? = try Int64.fetchOne(db, sql: """
                SELECT MAX(dateNs) FROM message
                WHERE conversationId = ?
            """, arguments: [conversationId])
            return value ?? 0
        }
    }
}
