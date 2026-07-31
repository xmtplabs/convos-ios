import Foundation
import GRDB
import os
import XMTPiOS

/// Keeps each conversation's consent in sync with the contact state of the
/// people responsible for it, which is the source of truth for feed
/// visibility. "Responsible" means either the inbox that added the local
/// user (`addedById`) or the group's creator (`creatorId`) - they differ
/// whenever a contact adds us to a group somebody else created:
///
/// - either is a non-blocked contact -> consent `.allowed` (visible)
/// - either is a blocked contact     -> consent `.denied`  (hidden)
///
/// Conversations where neither inbox is a contact are left untouched: an
/// unsolicited stranger stays `.unknown` (hidden) and a conversation the
/// local user joined stays `.allowed` (flipped at arrival by
/// `StreamProcessor`). The reconciler covers two contact-state visibility
/// transitions: promotion when a stranger becomes a contact
/// (`.unknown` -> `.allowed`) and demotion on block (`.allowed` -> `.denied`).
///
/// Demotion is no longer driven primarily from here: `ContactsWriter.block`
/// flips both the DB `consent` column and XMTP synchronously, so the feed
/// hides with zero window. For the block direction this reconciler is a
/// backstop - it only re-fires when re-sync rewrites the DB `consent` column
/// back to `.allowed` while the contact is still blocked. Promotion is still
/// driven from here via GRDB observation.
///
/// Only `.unknown` is promoted - never `.denied`. A `.denied` conversation
/// from a non-blocked contact is one the user explicitly deleted, so it is
/// left hidden (resurrecting it would undo the delete). As a consequence,
/// unblocking a contact does not auto-restore conversations that were hidden
/// while they were blocked.
///
/// Consent is flipped at the XMTP layer (so it survives re-sync, which
/// rewrites the DB `consent` column from XMTP) and mirrored into the DB
/// immediately so the feed updates on the next observation cycle.
///
/// `@unchecked Sendable` for the same reason as `SyncClientParams`: the
/// captured `XMTPClientProvider` is thread-safe in practice, and the only
/// mutable state (`observationTask`) is guarded by an unfair lock.
final class ConversationConsentReconciler: @unchecked Sendable {
    private let databaseReader: any DatabaseReader
    private let databaseWriter: any DatabaseWriter
    private let client: any XMTPClientProvider

    private let observationTask: OSAllocatedUnfairLock<Task<Void, Never>?> = .init(initialState: nil)

    struct Target: Equatable {
        let conversationId: String
        let consent: Consent
    }

    init(
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        client: any XMTPClientProvider
    ) {
        self.databaseReader = databaseReader
        self.databaseWriter = databaseWriter
        self.client = client
    }

    /// Begin observing. Safe to call repeatedly - the previous task is
    /// cancelled and replaced.
    func start() {
        observationTask.withLock { existing in
            existing?.cancel()
            existing = Task { [weak self] in
                await self?.observe()
            }
        }
    }

    func stop() {
        observationTask.withLock { existing in
            existing?.cancel()
            existing = nil
        }
    }

    /// Upper bound on concurrent in-flight reconciles per batch. Each
    /// reconcile is a network round-trip to XMTP, so we parallelize to
    /// shrink the tail-of-batch window without hammering the service.
    private static let maxConcurrentReconciles: Int = 6

    private func observe() async {
        let dbReader = databaseReader
        let stream = ValueObservation
            .tracking { db in
                try Self.fetchMismatchedTargets(db: db)
            }
            // An unrelated conversation/contact write re-emits the observation
            // even when the mismatched set is unchanged; skip re-driving the
            // (network-touching) reconcile loop when the targets are identical.
            .removeDuplicates()
            .values(in: dbReader)
        do {
            for try await targets in stream {
                if Task.isCancelled { return }
                await reconcileBatch(targets)
            }
        } catch {
            Log.error("ConversationConsentReconciler: stream failed: \(error.localizedDescription)")
        }
    }

    /// Reconciles a batch with bounded concurrency. A large mismatch set
    /// (block-all, or first launch after the backfill migration) would
    /// otherwise serialize N network round-trips; a sliding window of at
    /// most `maxConcurrentReconciles` keeps the tail short.
    private func reconcileBatch(_ targets: [Target]) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = targets.makeIterator()
            var inflight = 0
            while inflight < Self.maxConcurrentReconciles, let target = iterator.next() {
                group.addTask { [weak self] in await self?.reconcile(target) }
                inflight += 1
            }
            while await group.next() != nil {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let target = iterator.next() {
                    group.addTask { [weak self] in await self?.reconcile(target) }
                }
            }
        }
    }

    /// Conversations whose stored consent disagrees with the contact-block
    /// state of the people responsible for them. A conversation has up to
    /// two such inboxes and both count: `addedById` (who added the local
    /// user) and `creatorId` (who made the group). They differ whenever a
    /// contact adds us to a group somebody else created — matching on the
    /// creator alone never promoted those, so a conversation a contact
    /// invited us to stayed `.unknown` and out of the feed.
    ///
    /// Conversations with no contact row on either inbox are ignored:
    /// strangers and self-joined stranger conversations. Once a target is
    /// flipped its consent matches and it drops out of this result, so the
    /// observation converges.
    ///
    /// Blocking dominates: if *either* inbox is a blocked contact the
    /// target is `.denied`, so a contact can't be used as a conduit for
    /// someone the user blocked. Otherwise a contact on either inbox makes
    /// the target `.allowed`.
    ///
    /// Promotion fires only for `.unknown` (a stranger that just became a
    /// contact), never for `.denied` - a `.denied` conversation from a
    /// non-blocked contact is one the user deleted, and must stay hidden.
    ///
    /// Written with EXISTS sub-queries rather than a `JOIN contact`: with
    /// two candidate inboxes a join would emit one row per matching
    /// contact, and a conversation whose adder and creator disagree on
    /// block state would yield two conflicting targets for the same id.
    static func fetchMismatchedTargets(db: Database) throws -> [Target] {
        let allowed: String = Consent.allowed.rawValue
        let denied: String = Consent.denied.rawValue
        let unknown: String = Consent.unknown.rawValue
        // `IN (creatorId, addedById)` handles a NULL `addedById` naturally:
        // NULL matches no contact row.
        let anyRelatedContact = """
            EXISTS (
                SELECT 1 FROM contact
                WHERE contact.inboxId IN (conversation.creatorId, conversation.addedById)
            )
            """
        let anyRelatedContactBlocked = """
            EXISTS (
                SELECT 1 FROM contact
                WHERE contact.inboxId IN (conversation.creatorId, conversation.addedById)
                  AND contact.blockedAt IS NOT NULL
            )
            """
        let rows = try Row.fetchAll(db, sql: """
            SELECT conversation.id AS id,
                   CASE WHEN \(anyRelatedContactBlocked) THEN ? ELSE ? END AS target
            FROM conversation
            WHERE \(anyRelatedContact)
              AND (
                    (NOT \(anyRelatedContactBlocked) AND conversation.consent = ?)
                 OR (\(anyRelatedContactBlocked) AND conversation.consent <> ?)
              )
            """, arguments: [denied, allowed, unknown, denied])
        return rows.compactMap { row -> Target? in
            guard let id: String = row["id"],
                  let rawConsent: String = row["target"],
                  let consent = Consent(rawValue: rawConsent) else {
                return nil
            }
            return Target(conversationId: id, consent: consent)
        }
    }

    private func reconcile(_ target: Target) async {
        do {
            guard let conversation = try await client.conversationsProvider.findConversation(
                conversationId: target.conversationId
            ) else {
                return
            }
            // Only hit the network when XMTP isn't already at the target.
            // The mismatch was detected against the DB column, so XMTP can
            // already match (e.g. a prior reconcile flipped XMTP but its DB
            // write lost a race with a `ConversationWriter` save). Skipping
            // the redundant `updateConsentState` also narrows the window in
            // which a concurrent save can observe a stale XMTP value.
            let targetState: ConsentState = target.consent.consentState
            if try conversation.consentState() != targetState {
                // Retry transient failures in-session; a fully failed target
                // stays mismatched and is re-driven on the next tracked-region
                // change, app foreground, or network reconnect (all restart
                // this observation).
                try await withExponentialBackoffRetry {
                    try await conversation.updateConsentState(state: targetState)
                }
            }
            let consent: Consent = target.consent
            let conversationId: String = target.conversationId
            try await databaseWriter.write { db in
                try DBConversation
                    .filter(DBConversation.Columns.id == conversationId)
                    .updateAll(db, DBConversation.Columns.consent.set(to: consent))
            }
            Log.info("ConversationConsentReconciler: set \(target.consent) for \(target.conversationId)")
        } catch {
            Log.error(
                "ConversationConsentReconciler: failed to set \(target.consent) for \(target.conversationId): \(error.localizedDescription)"
            )
        }
    }
}
