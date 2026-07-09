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
            var hasObservedAllowedConversations = false
            for try await ids in stream {
                if Task.isCancelled { return }
                await mirror(
                    allowedConversationIds: ids,
                    hasObservedAllowedConversations: hasObservedAllowedConversations
                )
                if !ids.isEmpty {
                    hasObservedAllowedConversations = true
                }
            }
        } catch {
            Log.error("ConsentBackupMirror: stream failed: \(error.localizedDescription)")
        }
    }

    /// Writes the snapshot when it differs from what's already in the
    /// keychain. An empty set is written too - if the user deletes every
    /// conversation, a later reinstall must not resurrect them - but only
    /// after this session has seen a non-empty set: on a reinstall launch
    /// the database starts empty and the observation emits immediately,
    /// racing the reconcile's consent restore, and writing that first
    /// empty snapshot would clobber the very backup the restore is about
    /// to read. Skipping empty-over-non-empty until the set has genuinely
    /// transitioned through non-empty makes the mirror converge with the
    /// restore instead of racing it. The identity read failing (or no
    /// identity yet) also skips the write; the observation re-fires on
    /// the next change and converges.
    private func mirror(
        allowedConversationIds: [String],
        hasObservedAllowedConversations: Bool
    ) async {
        do {
            guard let inboxId = try identityStore.loadSync()?.inboxId else { return }
            let backup = ConsentBackup(inboxId: inboxId, allowedConversationIds: allowedConversationIds)
            let existing = try await identityStore.loadConsentBackup()
            guard backup != existing else { return }
            if allowedConversationIds.isEmpty,
               !hasObservedAllowedConversations,
               let existing,
               existing.inboxId == inboxId,
               !existing.allowedConversationIds.isEmpty {
                return
            }
            try await identityStore.saveConsentBackup(backup)
            Log.info("ConsentBackupMirror: mirrored \(allowedConversationIds.count) allowed conversation(s) to keychain")
        } catch {
            Log.warning("ConsentBackupMirror: failed to mirror consent backup: \(error)")
        }
    }
}
