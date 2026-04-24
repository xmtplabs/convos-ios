import ConvosCore
import Foundation
import Observation

/// Drives the `BackupRestoreSettingsView`. Observes the scheduler's
/// `isBackupInProgress` flag, the persisted `lastSuccessfulAt`
/// timestamp, and the `PendingArchiveImportFailure` summary so the UI
/// can surface a partial-restore warning until the user re-runs restore.
@MainActor
@Observable
final class BackupRestoreViewModel {
    private(set) var isBackupInProgress: Bool = false
    private(set) var lastBackupAt: Date?
    private(set) var availableRestore: AvailableBackup?
    private(set) var pendingArchiveImportFailure: PendingArchiveImportFailure?
    private(set) var iCloudAvailable: Bool = true
    private(set) var lastError: (any Error)?

    private let environment: AppEnvironment
    private let scheduler: BackupScheduler
    private let restoreManagerFactory: (@MainActor () -> RestoreManager?)?

    init(
        environment: AppEnvironment,
        scheduler: BackupScheduler = .shared,
        restoreManagerFactory: (@MainActor () -> RestoreManager?)? = nil
    ) {
        self.environment = environment
        self.scheduler = scheduler
        self.restoreManagerFactory = restoreManagerFactory
    }

    /// Refreshes every observable field. Called when the view appears
    /// and after any destructive action so the UI stays in sync.
    func refresh() async {
        isBackupInProgress = scheduler.isBackupInProgress
        lastBackupAt = lastSuccessfulBackupAt()
        pendingArchiveImportFailure = PendingArchiveImportFailureStorage.load(environment: environment)
        iCloudAvailable = FileManager.default.ubiquityIdentityToken != nil
            || environment.iCloudContainerIdentifier == nil
        if let factory = restoreManagerFactory, let manager = factory() {
            availableRestore = await manager.findAvailableBackup()
        }
    }

    func backUpNow() async {
        lastError = nil
        do {
            _ = try await scheduler.runManualBackup()
            await refresh()
        } catch {
            lastError = error
        }
    }

    func dismissPartialRestoreWarning() {
        PendingArchiveImportFailureStorage.clear(environment: environment)
        pendingArchiveImportFailure = nil
    }

    // MARK: - Helpers

    private func lastSuccessfulBackupAt() -> Date? {
        let defaults = UserDefaults(suiteName: environment.appGroupIdentifier) ?? .standard
        return defaults.object(forKey: "convos.backup.lastSuccessfulAt") as? Date
    }
}
