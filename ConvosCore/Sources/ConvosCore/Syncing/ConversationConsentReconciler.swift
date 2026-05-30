import Foundation
import GRDB
import os
import XMTPiOS

/// Keeps each conversation's consent in sync with its creator's contact
/// state, which is the source of truth for feed visibility:
///
/// - creator is a non-blocked contact -> consent `.allowed` (visible)
/// - creator is a blocked contact     -> consent `.denied`  (hidden)
///
/// Conversations whose creator is not a contact are left untouched: an
/// unsolicited stranger stays `.unknown` (hidden) and a conversation the
/// local user joined stays `.allowed` (flipped at arrival by
/// `StreamProcessor`). The reconciler covers two contact-state visibility
/// transitions: promotion when a stranger becomes a contact
/// (`.unknown` -> `.allowed`) and demotion on block (`.allowed` -> `.denied`),
/// so `block` stays a pure contact-row write and this reconciler reacts to it
/// via GRDB observation.
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
        let new: Task<Void, Never> = Task { [weak self] in
            await self?.observe()
        }
        observationTask.withLock { existing in
            existing?.cancel()
            existing = new
        }
    }

    func stop() {
        observationTask.withLock { existing in
            existing?.cancel()
            existing = nil
        }
    }

    private func observe() async {
        let dbReader = databaseReader
        let stream = ValueObservation
            .tracking { db in
                try Self.fetchMismatchedTargets(db: db)
            }
            .values(in: dbReader)
        do {
            for try await targets in stream {
                if Task.isCancelled { return }
                for target in targets {
                    if Task.isCancelled { return }
                    await reconcile(target)
                }
            }
        } catch {
            Log.error("ConversationConsentReconciler: stream failed: \(error.localizedDescription)")
        }
    }

    /// Conversations whose stored consent disagrees with their creator's
    /// contact-block state. The `JOIN contact` self-limits to
    /// contact-created conversations; strangers and self-joined
    /// stranger conversations have no matching contact row and are
    /// ignored. Once a target is flipped its consent matches and it
    /// drops out of this result, so the observation converges.
    ///
    /// Promotion fires only for `.unknown` (a stranger that just became a
    /// contact), never for `.denied` - a `.denied` conversation from a
    /// non-blocked contact is one the user deleted, and must stay hidden.
    static func fetchMismatchedTargets(db: Database) throws -> [Target] {
        let allowed: String = Consent.allowed.rawValue
        let denied: String = Consent.denied.rawValue
        let unknown: String = Consent.unknown.rawValue
        let rows = try Row.fetchAll(db, sql: """
            SELECT conversation.id AS id,
                   CASE WHEN contact.blockedAt IS NULL THEN ? ELSE ? END AS target
            FROM conversation
            JOIN contact ON contact.inboxId = conversation.creatorId
            WHERE (contact.blockedAt IS NULL AND conversation.consent = ?)
               OR (contact.blockedAt IS NOT NULL AND conversation.consent <> ?)
            """, arguments: [allowed, denied, unknown, denied])
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
                try await conversation.updateConsentState(state: targetState)
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
