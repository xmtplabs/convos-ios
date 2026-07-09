import Foundation
import GRDB
import os

/// Session-scoped observer that mirrors the allowed-conversation set into
/// the device-local keychain (`ConsentBackup`) whenever it changes, so a
/// reinstall can restore the user's consent (see `ConsentBackupRestorer`
/// for why the network can't). Owned by `SyncingManager` alongside
/// `ConversationConsentReconciler`, so it only runs in the full app
/// session, never in the notification service extension.
///
/// `@unchecked Sendable` for the same reason as the reconciler: the only
/// mutable state (`observationTask`) is guarded by an unfair lock.
final class ConsentBackupMirror: @unchecked Sendable {
    private let databaseReader: any DatabaseReader
    private let identityStore: any KeychainIdentityStoreProtocol

    private let observationTask: OSAllocatedUnfairLock<Task<Void, Never>?> = .init(initialState: nil)

    init(
        databaseReader: any DatabaseReader,
        identityStore: any KeychainIdentityStoreProtocol
    ) {
        self.databaseReader = databaseReader
        self.identityStore = identityStore
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

    private func observe() async {
        let stream = ValueObservation
            .tracking { db in
                try ConsentBackup.allowedConversationIds(db: db)
            }
            .removeDuplicates()
            .values(in: databaseReader)
        do {
            var everObservedIds = Set<String>()
            var carriedBackupIds: Set<String>?
            for try await ids in stream {
                if Task.isCancelled { return }
                await mirror(
                    allowedConversationIds: ids,
                    everObservedIds: &everObservedIds,
                    carriedBackupIds: &carriedBackupIds
                )
            }
        } catch {
            Log.error("ConsentBackupMirror: stream failed: \(error.localizedDescription)")
        }
    }

    /// Writes the snapshot when the resulting backup differs from what's
    /// already in the keychain, with one carry rule: ids present in the
    /// session's initial backup stay in every written snapshot until the
    /// database has actually shown them once. On a reinstall launch the
    /// database starts empty and refills over the first minute as
    /// welcomes and syncs land, and the observation emits each partial
    /// state immediately - mirroring those directly would shrink or
    /// clobber the very backup the reconcile's restore is reading, and a
    /// second uninstall inside that window would lose the missing
    /// conversations. An id the session has observed and that later
    /// disappears was denied by the user, so it drops out (deleting
    /// every conversation still mirrors an empty set once everything has
    /// been seen); ids never observed are still refilling and are
    /// carried. In a steady-state session the first emission covers the
    /// whole backup and the carry set is empty from the start. The
    /// identity read failing (or no identity yet) skips the write; the
    /// observation re-fires on the next change and converges.
    private func mirror(
        allowedConversationIds: [String],
        everObservedIds: inout Set<String>,
        carriedBackupIds: inout Set<String>?
    ) async {
        do {
            guard let inboxId = try identityStore.loadSync()?.inboxId else { return }
            let existing = try await identityStore.loadConsentBackup()
            // Cancellation is cooperative and the loop's check only runs
            // between emissions - a task cancelled while suspended on the
            // load above must not write, or a replaced observer's stale
            // snapshot could land after its successor's.
            guard !Task.isCancelled else { return }
            if carriedBackupIds == nil {
                carriedBackupIds = existing?.inboxId == inboxId
                    ? Set(existing?.allowedConversationIds ?? [])
                    : []
            }
            everObservedIds.formUnion(allowedConversationIds)
            let pendingRefillIds = (carriedBackupIds ?? []).subtracting(everObservedIds)
            let target = Set(allowedConversationIds).union(pendingRefillIds).sorted()
            let backup = ConsentBackup(inboxId: inboxId, allowedConversationIds: target)
            guard backup != existing else { return }
            try await identityStore.saveConsentBackup(backup)
            Log.info("ConsentBackupMirror: mirrored \(target.count) allowed conversation(s) to keychain (\(pendingRefillIds.count) carried)")
        } catch {
            Log.warning("ConsentBackupMirror: failed to mirror consent backup: \(error)")
        }
    }
}
