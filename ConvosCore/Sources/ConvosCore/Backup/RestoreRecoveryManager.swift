import Foundation
import GRDB

/// Runs at app start to reconcile any `RestoreTransaction` persisted by a
/// prior launch that crashed mid-restore. Call `recoverIfNeeded()` before
/// `SessionManager` prewarm, scheduler registration, or restore-prompt
/// decision logic so the restore gate reflects the true on-disk state.
public struct RestoreRecoveryManager {
    /// Outcome surfaced back to the caller for telemetry / UI.
    public enum Outcome: Equatable {
        /// No transaction record present — nothing to do.
        case noTransaction
        /// Found a pre-commit transaction with rollback artifacts; they
        /// have been restored, the record has been cleared.
        case rolledBack
        /// Found a committed transaction; artifacts are gone. Flag cleared.
        case committedCleanup
        /// Transaction present but artifacts missing or stale; cleared
        /// without restoring. Caller should surface "Restore interrupted —
        /// please try again."
        case cleared(reason: String)
    }

    /// Safety window for a paused/databaseReplaced transaction. Anything
    /// older is considered stale (user walked away long enough that their
    /// restore attempt won't resume) and is cleared without rollback.
    public static let staleThreshold: TimeInterval = 60 * 60  // 1 hour

    private let environment: AppEnvironment
    private let databaseManager: any DatabaseManagerProtocol
    private let fileManager: FileManager

    public init(
        environment: AppEnvironment,
        databaseManager: any DatabaseManagerProtocol,
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.databaseManager = databaseManager
        self.fileManager = fileManager
    }

    @discardableResult
    public func recoverIfNeeded() -> Outcome {
        guard let transaction = RestoreTransactionStore.load(environment: environment) else {
            // Belt-and-suspenders: the in-progress flag should never be set
            // without a record, but clear it just in case.
            if RestoreInProgressFlag.isSet(environment: environment) {
                Log.warning("RestoreRecoveryManager: in-progress flag set without record, clearing")
                RestoreInProgressFlag.set(false, environment: environment)
            }
            return .noTransaction
        }

        Log.info("RestoreRecoveryManager: found transaction \(transaction.id) in phase \(transaction.phase.rawValue)")

        let age = Date().timeIntervalSince(transaction.startedAt)
        if age > Self.staleThreshold {
            return clear(transaction: transaction, reason: "stale (\(Int(age))s old)")
        }

        switch transaction.phase {
        case .committed:
            return finalizeCommitted(transaction: transaction)
        case .paused, .databaseReplaced:
            return attemptRollback(transaction: transaction)
        }
    }

    // MARK: - Outcomes

    private func finalizeCommitted(transaction: RestoreTransaction) -> Outcome {
        // Committed restores are no-rollback: the DB is already on the new
        // content. Just clear the bookkeeping and move on.
        cleanupArtifacts(for: transaction.id)
        RestoreTransactionStore.clear(environment: environment)
        RestoreInProgressFlag.set(false, environment: environment)
        Log.info("RestoreRecoveryManager: cleared committed transaction \(transaction.id)")
        return .committedCleanup
    }

    private func attemptRollback(transaction: RestoreTransaction) -> Outcome {
        let snapshotURL = RestoreArtifactLayout.grdbSnapshotURL(for: transaction.id, environment: environment)
        let stashURL = RestoreArtifactLayout.xmtpStashDirectory(for: transaction.id, environment: environment)

        let snapshotExists = fileManager.fileExists(atPath: snapshotURL.path)

        // If the DB was replaced but the rollback snapshot is gone (crash
        // between snapshot write and database swap, or the artifact dir
        // was cleared out-of-band), we cannot restore the pre-restore
        // state. Don't pretend the rollback succeeded — fall back to
        // `.cleared` so the caller knows the on-disk DB is now whatever
        // partial state the interrupted restore left behind, not the
        // user's original.
        if transaction.phase == .databaseReplaced {
            guard snapshotExists else {
                return clear(
                    transaction: transaction,
                    reason: "DB was replaced but snapshot missing — cannot roll back"
                )
            }
            do {
                try databaseManager.replaceDatabase(with: snapshotURL)
            } catch {
                Log.error("RestoreRecoveryManager: rollback restoreDatabase failed: \(error)")
                return clear(transaction: transaction, reason: "rollback restoreDatabase failed: \(error)")
            }
        }

        // Restore the XMTP stash if present. Best-effort: the stash may be
        // partial if the pre-restore stage crashed mid-copy.
        if fileManager.fileExists(atPath: stashURL.path) {
            restoreXMTPStash(from: stashURL)
        }

        cleanupArtifacts(for: transaction.id)
        RestoreTransactionStore.clear(environment: environment)
        RestoreInProgressFlag.set(false, environment: environment)
        Log.info("RestoreRecoveryManager: rolled back transaction \(transaction.id)")
        return .rolledBack
    }

    private func clear(transaction: RestoreTransaction, reason: String) -> Outcome {
        cleanupArtifacts(for: transaction.id)
        RestoreTransactionStore.clear(environment: environment)
        RestoreInProgressFlag.set(false, environment: environment)
        Log.warning("RestoreRecoveryManager: cleared transaction \(transaction.id) — \(reason)")
        return .cleared(reason: reason)
    }

    // MARK: - Filesystem helpers

    private func cleanupArtifacts(for transactionId: UUID) {
        let dir = RestoreArtifactLayout.transactionDirectory(for: transactionId, environment: environment)
        try? fileManager.removeItem(at: dir)
    }

    private func restoreXMTPStash(from stashURL: URL) {
        let targetDir = environment.defaultDatabasesDirectoryURL
        // `.skipsSubdirectoryDescendants` keeps the enumerator at the top
        // level. `copyItem(at:to:)` already recursively copies a directory's
        // subtree, so descending into it would re-attempt copies of children
        // that already exist at the destination — wasted work and a source
        // of spurious failures. The stash is flat in current usage, but the
        // option is the correct defensive shape regardless.
        guard let enumerator = fileManager.enumerator(
            at: stashURL,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return
        }
        for case let src as URL in enumerator {
            // The enumerator is flat (`.skipsSubdirectoryDescendants`),
            // so `lastPathComponent` is the full relative name. The
            // previous `replacingOccurrences(of: stashURL.path + "/")`
            // calc could silently fail and produce the absolute path
            // when `src.path` didn't carry the expected separator —
            // a fragile shape now that we don't actually need.
            let dst = targetDir.appendingPathComponent(src.lastPathComponent)
            restoreSingleStashItem(from: src, to: dst)
        }
    }

    /// Restores one stashed file in place. The previous shape did
    /// `removeItem(dst)` + `copyItem(src, to: dst)` — if the copy
    /// failed, `dst` was already deleted and the source would be
    /// permanently discarded a few lines later by `cleanupArtifacts`.
    /// Use copy-to-temp + atomic replace so a failure leaves whatever
    /// was at `dst` intact.
    private func restoreSingleStashItem(from src: URL, to dst: URL) {
        if !fileManager.fileExists(atPath: dst.path) {
            do {
                try fileManager.copyItem(at: src, to: dst)
            } catch {
                Log.error(
                    "RestoreRecoveryManager: failed to restore stash file "
                    + "\(src.lastPathComponent): \(error)"
                )
            }
            return
        }

        // Stage the source under a temp name in the destination
        // directory, then atomically swap. `replaceItemAt` is atomic
        // when temp + dst share a volume (they always will here —
        // both live in the shared app-group container).
        let tempName = "convos-restore-stash-\(UUID().uuidString)-\(src.lastPathComponent)"
        let temp = dst.deletingLastPathComponent().appendingPathComponent(tempName)
        do {
            try fileManager.copyItem(at: src, to: temp)
        } catch {
            Log.error(
                "RestoreRecoveryManager: failed to stage stash file "
                + "\(src.lastPathComponent) to temp: \(error)"
            )
            return
        }
        do {
            _ = try fileManager.replaceItemAt(dst, withItemAt: temp)
        } catch {
            // Replace failed — clean up the temp and leave dst alone.
            // The user keeps whatever interrupted-restore state they
            // had, but at least we did not delete it irrecoverably.
            try? fileManager.removeItem(at: temp)
            Log.error(
                "RestoreRecoveryManager: failed to atomic-replace "
                + "\(dst.lastPathComponent): \(error)"
            )
        }
    }
}
