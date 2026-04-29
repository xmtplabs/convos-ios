import ConvosCore
import Foundation
import Observation

/// App-layer coordinator bridging the backup/restore UX into the core
/// actors. Owns the long-lived `BackupRestoreViewModel` and knows how
/// to initiate a restore given a discovered backup.
///
/// Lives on the main actor and is constructed once in `ConvosApp.init`;
/// passed down to anywhere that needs to show the settings screen or
/// drive a restore flow.
@MainActor
@Observable
final class BackupCoordinator {
    let viewModel: BackupRestoreViewModel
    private let convos: ConvosClient

    private(set) var isRestoring: Bool = false

    /// Human-readable message for the most recent restore failure, nil
    /// when there's no error to surface. Two-way bound from SwiftUI
    /// alerts: setting it to nil dismisses the alert and is the only
    /// way for the user to acknowledge the failure.
    var restoreErrorMessage: String? {
        get { restoreErrorMessageStorage }
        set { restoreErrorMessageStorage = newValue }
    }

    private var restoreErrorMessageStorage: String?

    /// True when the fresh-install restore prompt card should be shown.
    /// Set once on app start if a compatible backup is discovered and
    /// the user hasn't yet chosen Restore / Start fresh. Cleared by
    /// either `beginRestore` succeeding or `dismissRestorePrompt`.
    private(set) var showRestorePrompt: Bool = false

    /// True while the bootstrap gate is held closed waiting for iCloud
    /// (Documents and/or Keychain) to settle. Prevents the catastrophic
    /// race where a slow first-launch on Device B mints a fresh
    /// identity that then propagates back via iCloud Keychain and
    /// overwrites Device A's identity. UI shows a "checking iCloud"
    /// card during this phase. Cleared once `resolveBootstrapDecision`
    /// reaches a terminal state.
    private(set) var isAwaitingICloud: Bool = false

    /// Seconds remaining in the iCloud settle window. Drives the
    /// countdown on the awaiting-iCloud card so the user can see the
    /// wait isn't indefinite.
    private(set) var iCloudSettleSecondsRemaining: Int = 0

    private static let iCloudSettleTimeout: Duration = .seconds(60)
    private static let iCloudSettlePollInterval: Duration = .seconds(2)

    /// Increments whenever the session gate opens or the restored session
    /// is rebuilt. `ConvosApp` uses this to bind stale-device observation
    /// only to real session state machines, never to the bootstrap-gate
    /// placeholder.
    private(set) var sessionObservationGeneration: Int = 0

    /// Bumped to a fresh `UUID` on each successful restore. Views that
    /// own a sheet hosting the restore UI (e.g. `AppSettingsView`) watch
    /// this via `.onChange` and dismiss themselves when it fires, so the
    /// user lands back on the conversations list with the restored data
    /// instead of the now-irrelevant settings sheet.
    private(set) var lastRestoreSuccessId: UUID?

    init(convos: ConvosClient) {
        self.convos = convos
        self.viewModel = BackupRestoreViewModel(
            environment: convos.environment,
            conversationCountProvider: { [weak convos] in
                await convos?.conversationCount() ?? 0
            },
            restoreManagerFactory: { [weak convos] in
                convos?.makeRestoreManager()
            }
        )
    }

    /// Called once from `ConvosApp.init`'s follow-up Task. Resolves the
    /// bootstrap gate:
    ///
    /// - If this install already has a DBInbox row, it's an existing
    ///   user on a device they've been using. Skip the prompt and
    ///   release the gate immediately so the normal session boots.
    /// - Otherwise — this is either a fresh install OR a new device
    ///   where iCloud Keychain synced the identity but no XMTP DB
    ///   exists yet. If a compatible backup is discovered, block the
    ///   gate and show the restore prompt. If not, release the gate
    ///   and let normal onboarding run.
    ///
    /// Blocking the gate is what prevents the "silent restore" bug:
    /// without it, `SessionManager` would run `.authorize` on the
    /// iCloud-Keychain-synced identity, Client.build would fail for
    /// lack of a local XMTP DB, Client.create would register a fresh
    /// installation on the existing inbox, and the user's conversations
    /// would quietly stream back in via welcome messages — all before
    /// we ever asked whether they wanted that to happen.
    func resolveBootstrapDecision() async {
        let alreadyInitialized = await convos.hasAnyUsedInbox()
        if alreadyInitialized {
            showRestorePrompt = false
            isAwaitingICloud = false
            convos.session.setRestoreBootstrapDecision(.noRestoreAvailable)
            advanceSessionObservationGeneration()
            return
        }

        let manager = convos.makeRestoreManager()
        // Quick check first — covers the common case where iCloud has
        // already delivered. Avoids the settle wait when unnecessary.
        if let available = await manager.findAvailableBackup() {
            if RestorePromptDismissalStorage.isDismissed(
                available.sidecar,
                environment: convos.environment
            ) {
                // User already tapped "Not now" on this exact bundle on
                // this device. Don't re-prompt; release the gate so they
                // can use the app normally. Settings → Backup & Restore
                // still surfaces the bundle if they change their mind.
                await viewModel.refresh()
                isAwaitingICloud = false
                showRestorePrompt = false
                convos.session.setRestoreBootstrapDecision(.dismissedByUser)
                advanceSessionObservationGeneration()
                return
            }
            await viewModel.refresh()
            isAwaitingICloud = false
            showRestorePrompt = true
            convos.session.setRestoreBootstrapDecision(.restoreAvailable)
            return
        }

        // Nothing visible yet. iCloud Documents AND iCloud Keychain may
        // still be syncing on a fresh install paired with another
        // device. Releasing the gate here would let `handleRegister`
        // mint fresh keys, which iCloud Keychain would then push back
        // and silently overwrite the original device's identity —
        // bricking it. Hold the gate closed for a bounded settle window
        // and re-check both sources before declaring this a true fresh
        // install.
        isAwaitingICloud = true
        let outcome = await waitForICloudSettle(manager: manager)
        isAwaitingICloud = false
        iCloudSettleSecondsRemaining = 0

        switch outcome {
        case .backupArrived:
            await viewModel.refresh()
            if let sidecar = viewModel.availableRestore?.sidecar,
               RestorePromptDismissalStorage.isDismissed(
                sidecar,
                environment: convos.environment
               ) {
                showRestorePrompt = false
                convos.session.setRestoreBootstrapDecision(.dismissedByUser)
                advanceSessionObservationGeneration()
            } else {
                showRestorePrompt = true
                convos.session.setRestoreBootstrapDecision(.restoreAvailable)
            }
        case .backupKeyArrived, .timeout:
            // Backup key arrived via iCloud Keychain but no bundle is
            // visible yet (still propagating, or no paired device has
            // ever made one). Or timeout — iCloud is genuinely
            // unreachable / this is the first device. Either way we
            // release the gate so the user can register fresh; if a
            // bundle shows up later they can still hit Restore from
            // settings.
            await viewModel.refresh()
            showRestorePrompt = false
            convos.session.setRestoreBootstrapDecision(.noRestoreAvailable)
            advanceSessionObservationGeneration()
        }
    }

    private enum ICloudSettleOutcome {
        case backupArrived
        /// Backup key arrived via iCloud Keychain — under the two-key
        /// model this means a paired device has set up Convos before
        /// and we should be ready to restore. The actual bundle may
        /// still be downloading via iCloud Documents, but the key half
        /// is here.
        case backupKeyArrived
        case timeout
    }

    /// Polls `findAvailableBackup` and `identityStore.loadBackupKeySync`
    /// until either returns non-nil, or the settle timeout expires.
    /// Under the two-key model the backup key is the SOLE synced item
    /// — its arrival is the strong "this Apple ID has Convos
    /// elsewhere" signal we used to get from the synced identity.
    private func waitForICloudSettle(manager: RestoreManager) async -> ICloudSettleOutcome {
        let identityStore = convos.identityStore
        let deadline = ContinuousClock.now.advanced(by: Self.iCloudSettleTimeout)
        iCloudSettleSecondsRemaining = Int(Self.iCloudSettleTimeout.components.seconds)

        while ContinuousClock.now < deadline {
            do {
                try await Task.sleep(for: Self.iCloudSettlePollInterval)
            } catch {
                return .timeout
            }
            iCloudSettleSecondsRemaining = max(
                0,
                Int(ContinuousClock.now.duration(to: deadline).components.seconds)
            )
            if await manager.findAvailableBackup() != nil {
                return .backupArrived
            }
            if (try? await identityStore.loadBackupKeySync()) != nil {
                return .backupKeyArrived
            }
        }
        return .timeout
    }

    /// Starts the restore against `available.bundleURL`. The actual
    /// pause/resume of the session is driven inside `RestoreManager`
    /// via `SessionManager.pauseForRestore/resumeAfterRestore`.
    func beginRestore(_ available: AvailableBackup) {
        // Reject reentrant calls. Without this, a second tap (or a
        // SwiftUI re-render that fires the action twice) spawns another
        // Task that hits `RestoreError.restoreAlreadyInProgress`,
        // catches it, then resets `isRestoring = false` while the first
        // restore is still mid-flight — UI would falsely show "done".
        guard !isRestoring else {
            Log.info("BackupCoordinator: beginRestore ignored — restore already in progress")
            return
        }
        isRestoring = true
        restoreErrorMessageStorage = nil
        Task { [weak self] in
            guard let self else { return }
            let manager = convos.makeRestoreManager()
            do {
                try await manager.restoreFromBackup(bundleURL: available.bundleURL)
                convos.session.setRestoreBootstrapDecision(.restoreSucceeded)
                showRestorePrompt = false
                advanceSessionObservationGeneration()
                lastRestoreSuccessId = UUID()
            } catch {
                restoreErrorMessageStorage = Self.userFacingMessage(for: error)
                Log.error("BackupCoordinator: restore failed — \(error)")
            }
            isRestoring = false
            await viewModel.refresh()
        }
    }

    /// Called by the fresh-install restore prompt when the user chooses
    /// "Not now." Per-device, non-destructive — records the dismissed
    /// bundle's fingerprint in app-group UserDefaults so the prompt
    /// stays hidden on this device, then releases the bootstrap gate.
    ///
    /// Critically, this does **not** delete the synced backup key.
    /// Earlier iterations did, on the theory that "Skip" meant "Start
    /// fresh on this Apple ID" — but iCloud Keychain (CKKS) propagates
    /// `deleteBackupKey()` to every paired device, so a single tap on
    /// Device A would silently brick Device B's backup. A genuine
    /// "Start fresh / wipe iCloud backups" gesture belongs in Settings
    /// where it can be explicitly labeled and confirmed; "Skip on this
    /// prompt for now" must remain harmless.
    func dismissRestorePrompt() {
        if let sidecar = viewModel.availableRestore?.sidecar {
            RestorePromptDismissalStorage.record(sidecar, environment: convos.environment)
        }
        showRestorePrompt = false
        convos.session.setRestoreBootstrapDecision(.dismissedByUser)
        advanceSessionObservationGeneration()
    }

    /// Erases the synced backup key from this Apple ID's iCloud Keychain.
    /// The deletion propagates via CKKS to every paired device, which is
    /// the *intended* effect — this is the explicit "I am leaving this
    /// account; existing iCloud bundles should become unreadable
    /// everywhere" gesture. Surfaced from Settings → Backup & Restore
    /// behind a destructive-confirmation alert. Never wired to the
    /// fresh-install prompt's Skip button (that's the bug we just
    /// recovered from).
    @discardableResult
    func eraseICloudBackupKey() async -> Bool {
        do {
            try await convos.identityStore.deleteBackupKey()
            Log.info("BackupCoordinator: erased synced backup key from iCloud Keychain")
            await viewModel.refresh()
            return true
        } catch {
            Log.warning("BackupCoordinator: erase backup key failed: \(error)")
            return false
        }
    }

    /// Called after `SessionManager.deleteAllInboxes()` tears the cached
    /// session down (e.g. the StaleDeviceBanner reset path). Re-resolves
    /// the bootstrap gate as if the app had just launched fresh: if a
    /// compatible backup is visible the prompt re-appears, otherwise the
    /// gate releases for normal registration. Either resolution path also
    /// bumps `sessionObservationGeneration`, so any stale-device observer
    /// bound to the now-dead state machine rebinds to the rebuilt one.
    func notifySessionReset() async {
        showRestorePrompt = false
        restoreErrorMessageStorage = nil
        isRestoring = false
        convos.session.setRestoreBootstrapDecision(.unknown)
        await resolveBootstrapDecision()
    }

    private func advanceSessionObservationGeneration() {
        sessionObservationGeneration += 1
    }

    /// Read-only peek at the keychain identity for the debug view.
    /// `loadSync` is `nonisolated` and safe to call from the main actor.
    func identityStoreSnapshot() throws -> KeychainIdentity? {
        try convos.identityStore.loadSync()
    }

    /// Translates a `RestoreError` (or any surfaced error) into a string
    /// that makes sense to a user. The raw `localizedDescription` on
    /// `decryptionFailed` reads like `Backup decryption failed:
    /// authenticationFailure` which doesn't explain the root cause — in
    /// practice it nearly always means the identity on this device and
    /// the identity that sealed the bundle have diverged (iCloud
    /// Keychain hasn't delivered the sender's key yet, or the user did
    /// "Delete all app data" and regenerated keys after the backup was
    /// taken). Call this out explicitly so the user can decide whether
    /// to wait, retry, or start fresh.
    private static func userFacingMessage(for error: any Error) -> String {
        if let restoreError = error as? RestoreError {
            switch restoreError {
            case .decryptionFailed:
                return "We couldn't unlock this backup on this device. "
                    + "iCloud Keychain may still be syncing your identity — "
                    + "wait a moment and try again. If this keeps happening, "
                    + "the backup was made with a different account or after "
                    + "a key reset, and can't be restored here."
            case .schemaGenerationMismatch:
                return "This backup was made on an older version of the app "
                    + "and isn't compatible. Update the app on the device "
                    + "that made the backup and try again."
            case .bundleCorrupt:
                return "This backup file appears to be corrupt. "
                    + "Try creating a fresh backup from the source device."
            case .replaceDatabaseFailed:
                return "We couldn't apply the backup to this device. "
                    + "Restart the app and try again."
            case .missingComponent:
                return "This backup is incomplete. "
                    + "Try creating a fresh backup from the source device."
            case .identityNotAvailable:
                return "Your identity hasn't synced to this device yet. "
                    + "Check iCloud Keychain, wait a minute, and try again."
            case .backupKeyNotAvailable:
                return "The backup key isn't on this Apple ID's iCloud Keychain. "
                    + "If you previously chose Start fresh, the backup is no longer "
                    + "recoverable. Otherwise, wait for iCloud Keychain to sync and try again."
            case .restoreAlreadyInProgress:
                return "A restore is already in progress. Please wait."
            }
        }
        return error.localizedDescription
    }
}
