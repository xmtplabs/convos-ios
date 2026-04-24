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

    init(convos: ConvosClient) {
        self.convos = convos
        self.viewModel = BackupRestoreViewModel(
            environment: convos.environment,
            restoreManagerFactory: { [weak convos] in
                convos?.makeRestoreManager()
            }
        )
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
        convos.session.setRestoreBootstrapDecision(.dismissedByUser)
    }
}
