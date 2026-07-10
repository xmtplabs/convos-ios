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
/// Mirroring follows one carry rule, bounded by a settling window: ids
/// present in the observer's initial backup stay in every written
/// snapshot until the database has shown them once or the window expires.
/// On a reinstall launch the database starts empty and refills over the
/// first minute as welcomes and syncs land; mirroring those partial
/// emissions directly would shrink the very backup the reconcile's
/// restore is reading. An id observed and later gone was denied by the
/// user and drops out immediately. An id never observed by the end of the
/// window is not refilling - it was denied from another device or its
/// conversation died network-side - and carrying it forever would
/// resurrect it on the next reinstall, so the window's expiry flush
/// drops it from the backup.
///
/// `@unchecked Sendable`: all mutable state lives behind unfair locks.
final class ConsentBackupMirror: @unchecked Sendable {
    private let databaseReader: any DatabaseReader
    private let identityStore: any KeychainIdentityStoreProtocol
    private let carryWindow: Duration

    private let observationTask: OSAllocatedUnfairLock<Task<Void, Never>?> = .init(initialState: nil)
    private let flushTask: OSAllocatedUnfairLock<Task<Void, Never>?> = .init(initialState: nil)
    private let state: OSAllocatedUnfairLock<MirrorState> = .init(initialState: MirrorState())

    private struct MirrorState {
        var everObservedIds: Set<String> = []
        var carriedBackupIds: Set<String>?
        var lastObservedIds: [String] = []
        var carryWindowExpired: Bool = false
        /// Set when a keychain write failed so the next attempt skips the
        /// unchanged-backup early return and retries the write.
        var lastSaveFailed: Bool = false
    }

    init(
        databaseReader: any DatabaseReader,
        identityStore: any KeychainIdentityStoreProtocol,
        carryWindow: Duration = .seconds(300)
    ) {
        self.databaseReader = databaseReader
        self.identityStore = identityStore
        self.carryWindow = carryWindow
    }

    /// Begin observing. Safe to call repeatedly - the previous tasks are
    /// cancelled and replaced, and the carry state resets.
    func start() {
        state.withLock { $0 = MirrorState() }
        observationTask.withLock { existing in
            existing?.cancel()
            existing = Task { [weak self] in
                await self?.observe()
            }
        }
        flushTask.withLock { [carryWindow] existing in
            existing?.cancel()
            existing = Task { [weak self] in
                try? await Task.sleep(for: carryWindow)
                await self?.flushAfterCarryWindow()
            }
        }
    }

    func stop() {
        observationTask.withLock { existing in
            existing?.cancel()
            existing = nil
        }
        flushTask.withLock { existing in
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
            for try await ids in stream {
                if Task.isCancelled { return }
                // Bookkeeping happens here, unconditionally, not inside
                // the fallible keychain path: an emission whose mirror
                // attempt fails must still count as observed, or a later
                // shrink would be misread as refill and resurrect a
                // user's deny into the backup.
                state.withLock { mirrorState in
                    mirrorState.everObservedIds.formUnion(ids)
                    mirrorState.lastObservedIds = ids
                }
                await mirror(allowedConversationIds: ids)
            }
        } catch {
            Log.error("ConsentBackupMirror: stream failed: \(error.localizedDescription)")
        }
    }

    /// Ends the carry window and re-mirrors the last observed set so ids
    /// that never appeared actually leave the backup - the observation
    /// only emits on database changes, so without this flush a quiet
    /// session would never drop them.
    private func flushAfterCarryWindow() async {
        if Task.isCancelled { return }
        let lastObserved = state.withLock { mirrorState in
            mirrorState.carryWindowExpired = true
            return mirrorState.lastObservedIds
        }
        await mirror(allowedConversationIds: lastObserved)
    }

    /// Writes the snapshot when the resulting backup differs from what's
    /// already in the keychain (or the previous write failed). The
    /// identity read failing (or no identity yet) skips the write; the
    /// observation re-fires on the next change and converges.
    private func mirror(allowedConversationIds: [String]) async {
        do {
            guard let inboxId = try identityStore.loadSync()?.inboxId else { return }
            let existing = try await identityStore.loadConsentBackup()
            // Cancellation is cooperative and the loop's check only runs
            // between emissions - a task cancelled while suspended on the
            // load above must not write, or a replaced observer's stale
            // snapshot could land after its successor's. (A delete-all
            // racing this write is additionally blocked by the store's
            // swept flag.)
            guard !Task.isCancelled else { return }
            let (pendingRefillIds, retrying) = state.withLock { mirrorState -> (Set<String>, Bool) in
                if mirrorState.carriedBackupIds == nil {
                    mirrorState.carriedBackupIds = existing?.inboxId == inboxId
                        ? Set(existing?.allowedConversationIds ?? [])
                        : []
                }
                let pending = mirrorState.carryWindowExpired
                    ? []
                    : (mirrorState.carriedBackupIds ?? []).subtracting(mirrorState.everObservedIds)
                return (pending.subtracting(allowedConversationIds), mirrorState.lastSaveFailed)
            }
            let target = Set(allowedConversationIds).union(pendingRefillIds).sorted()
            let backup = ConsentBackup(inboxId: inboxId, allowedConversationIds: target)
            guard backup != existing || retrying else { return }
            try await identityStore.saveConsentBackup(backup)
            state.withLock { $0.lastSaveFailed = false }
            Log.info("ConsentBackupMirror: mirrored \(target.count) allowed conversation(s) to keychain (\(pendingRefillIds.count) carried)")
        } catch {
            state.withLock { $0.lastSaveFailed = true }
            Log.warning("ConsentBackupMirror: failed to mirror consent backup (will retry on next change or flush): \(error)")
        }
    }
}
