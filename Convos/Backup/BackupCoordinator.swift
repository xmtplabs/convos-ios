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
        if await manager.findAvailableBackup() != nil {
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
            showRestorePrompt = true
            convos.session.setRestoreBootstrapDecision(.restoreAvailable)
        case .identityArrived, .timeout:
            // Identity present but no backup → take the .authorize
            // branch by releasing the gate. Timeout → assume true fresh
            // install (or iCloud is unavailable; user can still register).
            await viewModel.refresh()
            showRestorePrompt = false
            convos.session.setRestoreBootstrapDecision(.noRestoreAvailable)
            advanceSessionObservationGeneration()
        }
    }

    private enum ICloudSettleOutcome {
        case backupArrived
        case identityArrived
        case timeout
    }

    /// Polls `findAvailableBackup` and `identityStore.loadSync` until
    /// either returns non-nil, or the settle timeout expires. The
    /// remaining time is published via `iCloudSettleSecondsRemaining`
    /// so the UI can show a countdown instead of a frozen spinner.
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
            if (try? identityStore.loadSync()) != nil {
                return .identityArrived
            }
        }
        return .timeout
    }

    /// Starts the restore against `available.bundleURL`. The actual
    /// pause/resume of the session is driven inside `RestoreManager`
    /// via `SessionManager.pauseForRestore/resumeAfterRestore`.
    func beginRestore(_ available: AvailableBackup) {
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
            } catch {
                restoreErrorMessageStorage = Self.userFacingMessage(for: error)
                Log.error("BackupCoordinator: restore failed — \(error)")
            }
            isRestoring = false
            await viewModel.refresh()
        }
    }

    /// Called by the fresh-install restore prompt when the user chooses
    /// "Start fresh." Releases the bootstrap gate so registration can
    /// proceed normally.
    func dismissRestorePrompt() {
        showRestorePrompt = false
        convos.session.setRestoreBootstrapDecision(.dismissedByUser)
        advanceSessionObservationGeneration()
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
            case .restoreAlreadyInProgress:
                return "A restore is already in progress. Please wait."
            }
        }
        return error.localizedDescription
    }
}
