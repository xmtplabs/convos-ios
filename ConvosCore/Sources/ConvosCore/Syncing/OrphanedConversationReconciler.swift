import Foundation
import GRDB
@preconcurrency import XMTPiOS

/// Reconciles GRDB conversation rows against libxmtp's local store after
/// session start. If GRDB has rows that libxmtp does not, they are
/// flipped to `isActive = false` so the UI surfaces "Awaiting
/// reconnection" until the conversation comes back via #725's
/// `InactiveConversationReactivator`.
///
/// Two known sources of drift this routine heals:
///
/// 1. Build 800's `LegacyDataWipe` deleted libxmtp's `xmtp-*.db3`
///    files but missed `convos-single-inbox.sqlite`, leaving GRDB rows
///    pointing at conversations the freshly-rebuilt libxmtp does not
///    know about.
/// 2. Pre-existing drift on healthy installs (observed in production
///    logs from before the broken wipe shipped). The exact code path
///    is still open — possible candidates include welcome packets
///    dropped between NSE and main app, draft upgrades that wrote to
///    GRDB before the libxmtp group was live, or invite-join races
///    where the libxmtp commit silently failed. The QAEvent emitted
///    here is the canary: a non-zero `flipped` count on a healthy
///    user post-fix means the second bug is still firing.
///
/// Drafts (`id` prefix `draft-`) are excluded — by design they have
/// no libxmtp counterpart until publish.
///
/// Not an actor because the only call site is single-threaded
/// (SyncingManager runs `reconcile` once per session-ready transition)
/// and `actor` isolation on `reconcile(client:)` collides with the
/// non-Sendable `any ConversationsProvider` the call has to await on.
public final class OrphanedConversationReconciler: @unchecked Sendable {
    private let databaseReader: any DatabaseReader
    private let stateWriter: any ConversationLocalStateWriterProtocol

    public init(
        databaseReader: any DatabaseReader,
        stateWriter: any ConversationLocalStateWriterProtocol
    ) {
        self.databaseReader = databaseReader
        self.stateWriter = stateWriter
    }

    /// Idempotent. Runs once after first `syncAllConversations` per
    /// session-ready transition. Failures are logged; the caller does
    /// not need to react.
    public func reconcile(client: any XMTPClientProvider) async {
        let xmtpConversationIds: Set<String>
        do {
            let conversations = try await client.conversationsProvider.list(
                createdAfterNs: nil,
                createdBeforeNs: nil,
                lastActivityBeforeNs: nil,
                lastActivityAfterNs: nil,
                limit: nil,
                consentStates: nil,
                orderBy: .lastActivity
            )
            xmtpConversationIds = Set(conversations.map(\.id))
        } catch {
            Log.error("OrphanedConversationReconciler: failed to list libxmtp conversations: \(error)")
            return
        }
        await reconcile(xmtpConversationIDs: xmtpConversationIds)
    }

    /// Test entry point — bypasses libxmtp listing because constructing
    /// `XMTPiOS.Conversation` values in unit tests requires the Rust
    /// runtime. Production goes through `reconcile(client:)`.
    func reconcile(xmtpConversationIDs: Set<String>) async {
        let grdbConversationIds: Set<String>
        do {
            grdbConversationIds = try await databaseReader.read { db in
                let ids = try String.fetchAll(
                    db,
                    DBConversation
                        .filter(!DBConversation.Columns.id.like("draft-%"))
                        .select(DBConversation.Columns.id)
                )
                return Set(ids)
            }
        } catch {
            Log.error("OrphanedConversationReconciler: failed to read GRDB conversation IDs: \(error)")
            return
        }

        let orphans = grdbConversationIds.subtracting(xmtpConversationIDs)
        guard !orphans.isEmpty else {
            QAEvent.emit(.sync, "reconciliation_no_orphans", [
                "grdb": String(grdbConversationIds.count),
                "xmtp": String(xmtpConversationIDs.count),
            ])
            return
        }

        var flipped: Int = 0
        for id in orphans {
            do {
                try await stateWriter.setActive(false, for: id)
                flipped += 1
            } catch {
                Log.error("OrphanedConversationReconciler: failed to mark \(id) inactive: \(error)")
            }
        }

        QAEvent.emit(.sync, "reconciliation_completed", [
            "orphans": String(orphans.count),
            "flipped": String(flipped),
            "grdb": String(grdbConversationIds.count),
            "xmtp": String(xmtpConversationIDs.count),
        ])
        Log.info(
            "OrphanedConversationReconciler: flipped \(flipped)/\(orphans.count) orphans inactive "
            + "(grdb=\(grdbConversationIds.count), xmtp=\(xmtpConversationIDs.count))"
        )
    }
}
