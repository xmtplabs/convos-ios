import Foundation
import GRDB
import os
import XMTPiOS

/// Re-drives global-profile fan-out so a name/avatar edit reliably reaches
/// every conversation, even ones never opened and ones whose earlier publish
/// silently failed.
///
/// `MyProfileWriter.syncFromGlobalProfile` only fans out lazily, on a
/// conversation's `.ready` transition, and records a conversation as synced via
/// confirmed-published markers (`DBMemberProfile.publishedNameDigest` /
/// `publishedAvatarDigest`) that advance only after a successful send. This
/// reconciler observes those markers against `DBMyProfile`:
///
/// - On every start / resume it re-drives any conversation whose published
///   markers don't match the global profile (the app-foreground / network-
///   reconnect backstop, wired the same way as `ConversationConsentReconciler`).
/// - Because the observation reads `DBMyProfile`, editing the global profile
///   re-fires it and sweeps every conversation immediately - no separate
///   save-time hook needed.
///
/// Each target re-runs `syncFromGlobalProfile`, which is idempotent once the
/// markers match, so the observation converges. A `.ready`-driven sync racing
/// the reconciler at worst sends one redundant (recency-gated, harmless)
/// ProfileUpdate.
///
/// `@unchecked Sendable` for the same reason as `ConversationConsentReconciler`:
/// the captured client is thread-safe in practice and the only mutable state
/// (`observationTask`) is guarded by an unfair lock.
final class ProfileSyncReconciler: @unchecked Sendable {
    private let databaseReader: any DatabaseReader
    private let inboxId: String
    private let writer: any MyProfileWriterProtocol

    private let observationTask: OSAllocatedUnfairLock<Task<Void, Never>?> = .init(initialState: nil)

    init(
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        client: any XMTPClientProvider,
        apiClient: any ConvosAPIClientProtocol
    ) {
        self.databaseReader = databaseReader
        self.inboxId = client.inboxId
        // The reconciler runs inside SyncingManager, which has no
        // SessionStateManager. Bind a writer to the session's already-live
        // client so it reuses the exact gate + publish + avatar-upload logic.
        let ready = InboxReadyResult(client: client, apiClient: apiClient)
        self.writer = MyProfileWriter(databaseWriter: databaseWriter, resolveInboxReady: { ready })
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

    /// Upper bound on concurrent in-flight syncs per batch. Each sync is a
    /// network round-trip (and possibly an avatar upload), so a large mismatch
    /// set (every conversation, on first launch after the markers migration or
    /// after a global-profile edit) is processed with a sliding window rather
    /// than all at once.
    private static let maxConcurrentSyncs: Int = 6

    private func observe() async {
        let inboxId = self.inboxId
        let stream = ValueObservation
            .tracking { db in
                try Self.fetchMismatchedConversationIds(db: db, inboxId: inboxId)
            }
            // An unrelated write re-emits the observation even when the mismatch
            // set is unchanged; skip re-driving the network loop when identical.
            .removeDuplicates()
            .values(in: databaseReader)
        do {
            for try await ids in stream {
                if Task.isCancelled { return }
                await reconcileBatch(ids)
            }
        } catch {
            Log.error("ProfileSyncReconciler: stream failed: \(error.localizedDescription)")
        }
    }

    /// Conversations where the local user's confirmed-published markers don't
    /// match the global profile. Drafts are excluded (no XMTP group yet). Once a
    /// sync stamps the markers the row matches and drops out, so the observation
    /// converges.
    static func fetchMismatchedConversationIds(db: Database, inboxId: String) throws -> [String] {
        guard let global = try DBMyProfile
            .filter(DBMyProfile.Columns.inboxId == inboxId)
            .fetchOne(db) else {
            return []
        }
        let targetNameDigest = MyProfileWriter.nameDigest(global.name)
        let globalImageData = global.imageData
        let globalImageDigest = global.imageContentDigest

        let rows = try DBMemberProfile
            .filter(DBMemberProfile.Columns.inboxId == inboxId)
            .fetchAll(db)

        return rows.compactMap { row -> String? in
            if DBConversation.isDraft(id: row.conversationId) {
                return nil
            }
            let nameMismatch: Bool = row.publishedNameDigest != targetNameDigest
            let avatarMismatch: Bool
            if globalImageData == nil {
                // Cleared (digest also nil) -> a previously published avatar must
                // be removed. Not-rehydrated (digest present, bytes absent) -> leave.
                avatarMismatch = globalImageDigest == nil ? (row.publishedAvatarDigest != nil) : false
            } else {
                avatarMismatch = row.publishedAvatarDigest != globalImageDigest
            }
            return (nameMismatch || avatarMismatch) ? row.conversationId : nil
        }
    }

    private func reconcileBatch(_ conversationIds: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            var iterator = conversationIds.makeIterator()
            var inflight = 0
            while inflight < Self.maxConcurrentSyncs, let id = iterator.next() {
                group.addTask { [weak self] in await self?.reconcile(id) }
                inflight += 1
            }
            while await group.next() != nil {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let id = iterator.next() {
                    group.addTask { [weak self] in await self?.reconcile(id) }
                }
            }
        }
    }

    private func reconcile(_ conversationId: String) async {
        do {
            try await writer.syncFromGlobalProfile(conversationId: conversationId)
        } catch {
            // Markers stay stale on failure, so the next start / resume / global
            // edit re-drives this conversation.
            Log.error("ProfileSyncReconciler: sync failed for \(conversationId): \(error.localizedDescription)")
        }
    }
}
