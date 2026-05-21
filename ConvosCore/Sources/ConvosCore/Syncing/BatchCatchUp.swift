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
/// with one of each (for the regular-message path).
///
/// Flow:
/// 1. `client.conversationsProvider.listGroups(lastActivityAfterNs:)`
///    discovers conversations that had activity since the cursor.
/// 2. Per conversation, in parallel:
///    - Read the local `MAX(message.dateNs)` for that conversation
///    - `Group.messages(afterNs:)` to fetch the backlog from XMTP
///    - Split into "regular" messages (text, attachments, link previews,
///      group updates — go through `IncomingMessageWriter.persist` in
///      the batched transaction) and "supplementals" (reactions, read
///      receipts — each has its own per-type handler that the existing
///      stream-replay path also uses, but the libxmtp stream only
///      delivers events forward from connection time so we have to
///      apply supplementals ourselves before streams take over).
///    - Build a `PreparedConversation` + `[PreparedIncomingMessage]`
///      via the writers' prepare phases. All transaction-free.
/// 3. Open ONE `databaseWriter.write` and persist every prepared
///    conversation + its prepared regular messages inside that single
///    transaction. One observer fire, one SwiftUI re-render for the
///    regular-message path.
/// 4. After the transaction commits, apply per-conversation
///    supplementals via the existing reaction/read-receipt handlers
///    (each runs its own small transaction — same shape the stream
///    path uses via `fetchAndStoreLatestMessages`).
/// 5. Per-conversation side effects (prefetch + invite generation +
///    profile-from-history) fire off the foreground critical path so
///    they don't block the hook.
///
/// Why supplementals can't ride the main transaction: their handlers
/// (`handleReactionAddition/Removal`, `storeReadReceipt`) each open
/// their own `databaseWriter.write` block and do non-trivial conditional
/// logic (existence checks, timestamp comparisons). Inlining them into
/// the batched persist would require duplicating that logic; running
/// them via the existing handlers preserves a single source of truth.
/// The cost is N small transactions vs one big one, but in practice
/// supplementals are a small fraction of backlog traffic.
///
/// Stream redelivery of regular messages after the batch returns is
/// free thanks to:
/// - `saveConversation`'s no-op diff short-circuit (#857)
/// - `DBMessage` primary-key INSERT OR REPLACE semantics
/// - Reaction handler existence checks
/// Value type: stored properties are reference-typed but each conforms
/// to Sendable (`ConversationWriter` and `IncomingMessageWriter` are
/// `@unchecked Sendable`, GRDB's `DatabaseWriter` is Sendable), so
/// `BatchCatchUp` itself is implicitly Sendable with no annotation.
/// All transient state lives stack-local within `run`.
struct BatchCatchUp {
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

        // Phase 2: single-transaction persist of conversations + regular
        // messages. `saveResults[i]` corresponds to `prepared[i]` — needed
        // post-transaction because `saveConversation` may resolve a
        // different clientConversationId than the input (sticky-draft
        // logic), which the image-cache key downstream depends on.
        //
        // We also capture conversations where a backlog message removed
        // the local inbox — the stream path in
        // `IncomingMessageWriter.store` posts
        // `postLeftConversationNotification` for these; the batch path
        // must too or users removed while backgrounded never get notified.
        // Collected inside the transaction (only `persist` knows) but
        // dispatched after commit (notification posts are not a DB
        // operation).
        struct PersistOutcomes {
            let saveResults: [ConversationWriter.ConversationSaveResult]
            let conversationsRemovingLocalInbox: [DBConversation]
        }
        let outcomes: PersistOutcomes = try await databaseWriter.write { [conversationWriter, messageWriter] db in
            var results: [ConversationWriter.ConversationSaveResult] = []
            var removals: [DBConversation] = []
            results.reserveCapacity(prepared.count)
            for entry in prepared {
                let result = try conversationWriter.persist(entry.conversation, in: db)
                results.append(result)
                for preparedMessage in entry.regularMessages {
                    let messageResult = try messageWriter.persist(
                        preparedMessage,
                        conversation: entry.conversation.dbConversation,
                        in: db
                    )
                    if let messageResult,
                       messageResult.wasRemovedFromConversation,
                       !messageResult.messageAlreadyExists {
                        removals.append(entry.conversation.dbConversation)
                    }
                }
            }
            return PersistOutcomes(
                saveResults: results,
                conversationsRemovingLocalInbox: removals
            )
        }
        let saveResults = outcomes.saveResults

        // Post-commit notifications, matching the stream path's tail in
        // `IncomingMessageWriter.store`.
        for conversation in outcomes.conversationsRemovingLocalInbox {
            conversation.postLeftConversationNotification()
        }

        // Phase 3: apply supplementals (reactions + read receipts) via the
        // existing per-type handlers. libxmtp's `streamAllMessages` only
        // delivers events forward from connection time — it does NOT
        // replay historical backlog, so these would be lost if we relied
        // on the stream to pick them up. Each handler runs its own small
        // transaction; cheap because supplementals are a small fraction
        // of typical backlog volume.
        var supplementalCount = 0
        for entry in prepared {
            if entry.supplementalMessages.isEmpty { continue }
            supplementalCount += entry.supplementalMessages.count
            await conversationWriter.applyBacklogSupplementals(
                entry.supplementalMessages,
                for: entry.conversation.dbConversation
            )
        }

        // Phase 4: per-conversation side effects (prefetch, invite
        // generation, profile-from-history), off the foreground critical
        // path. `saveResult.clientConversationId` is the *actual*
        // persisted id and is what the image cache must key off.
        Task.detached(priority: .background) { [conversationWriter, prepared, saveResults] in
            for (entry, saveResult) in zip(prepared, saveResults) {
                await conversationWriter.runPostPersistSideEffects(
                    prepared: entry.conversation,
                    saveResult: saveResult,
                    group: entry.group
                )
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let totalRegular = prepared.reduce(0) { $0 + $1.regularMessages.count }
        Log.info("[PERF] catchup.batch.messages: \(Int(elapsed * 1000))ms convs=\(prepared.count) messages=\(totalRegular) supplementals=\(supplementalCount)")
        return BatchCatchUpResult(
            conversationsProcessed: prepared.count,
            messagesProcessed: totalRegular,
            durationSeconds: elapsed
        )
    }

    // MARK: - Private

    private struct PreparedEntry {
        let group: XMTPiOS.Group
        let conversation: ConversationWriter.PreparedConversation
        let regularMessages: [IncomingMessageWriter.PreparedIncomingMessage]
        let supplementalMessages: [XMTPiOS.DecodedMessage]
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

                    var regularMessages: [IncomingMessageWriter.PreparedIncomingMessage] = []
                    var supplementalMessages: [XMTPiOS.DecodedMessage] = []
                    regularMessages.reserveCapacity(allMessages.count)
                    for message in allMessages {
                        switch Self.classify(message) {
                        case .regular:
                            let prepared = try await messageWriter.prepare(message: message)
                            regularMessages.append(prepared)
                        case .supplemental:
                            supplementalMessages.append(message)
                        case .skip:
                            continue
                        }
                    }

                    return PreparedEntry(
                        group: group,
                        conversation: preparedConv,
                        regularMessages: regularMessages,
                        supplementalMessages: supplementalMessages
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

    private enum MessageClassification {
        /// Goes through `IncomingMessageWriter.persist` in the batched transaction.
        case regular
        /// Handled post-transaction via `ConversationWriter.applyBacklogSupplementals`
        /// (reactions, read receipts). These have per-type handlers that
        /// the stream-driven path also uses; we apply them here because
        /// the libxmtp stream doesn't replay historical backlog.
        case supplemental
        /// Drop entirely (typing indicators, profile messages, undecodable).
        /// Typing indicators are inherently live-only; profile messages
        /// are handled by `processProfileMessagesFromHistory` post-persist.
        case skip
    }

    private static func classify(_ message: XMTPiOS.DecodedMessage) -> MessageClassification {
        if message.isProfileMessage || message.isTypingIndicator {
            return .skip
        }
        if message.isReadReceipt {
            return .supplemental
        }
        guard let contentType = try? message.encodedContent.type else {
            return .skip
        }
        if contentType == ContentTypeReaction || contentType == ContentTypeReactionV2 {
            return .supplemental
        }
        return .regular
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
