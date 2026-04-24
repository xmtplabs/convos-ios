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

    /// Last restore outcome, surfaced so the UI can react after
    /// `beginRestore` returns.
    private(set) var lastRestoreError: (any Error)?
    private(set) var isRestoring: Bool = false

    /// True when the fresh-install restore prompt card should be shown.
    /// Set once on app start if a compatible backup is discovered and
    /// the user hasn't yet chosen Restore / Start fresh. Cleared by
    /// either `beginRestore` succeeding or `dismissRestorePrompt`.
    private(set) var showRestorePrompt: Bool = false

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
            convos.session.setRestoreBootstrapDecision(.noRestoreAvailable)
            return
        }

        let manager = convos.makeRestoreManager()
        let available = await manager.findAvailableBackup()
        await viewModel.refresh()
        if available != nil {
            showRestorePrompt = true
            convos.session.setRestoreBootstrapDecision(.restoreAvailable)
        } else {
            showRestorePrompt = false
            convos.session.setRestoreBootstrapDecision(.noRestoreAvailable)
        }
    }

    /// Starts the restore against `available.bundleURL`. The actual
    /// pause/resume of the session is driven inside `RestoreManager`
    /// via `SessionManager.pauseForRestore/resumeAfterRestore`.
    func beginRestore(_ available: AvailableBackup) {
        isRestoring = true
        lastRestoreError = nil
        Task { [weak self] in
            guard let self else { return }
            let manager = convos.makeRestoreManager()
            do {
                try await manager.restoreFromBackup(bundleURL: available.bundleURL)
                convos.session.setRestoreBootstrapDecision(.restoreSucceeded)
                showRestorePrompt = false
            } catch {
                lastRestoreError = error
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
    }
}
