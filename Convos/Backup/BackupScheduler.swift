import BackgroundTasks
import ConvosCore
import Foundation
import UIKit

/// Coordinates daily background backups via `BGProcessingTask`.
///
/// Lives in the main app target (not ConvosCore) because it uses iOS-only
/// `BGTaskScheduler`. Holds a process-global `isBackupInProgress` flag so
/// that the background handler and the manual "Back up now" path can't
/// run the same backup concurrently across separate BackupManager instances.
@MainActor
final class BackupScheduler {
    static let shared: BackupScheduler = BackupScheduler()

    private static let taskIdentifier: String = "org.convos.backup.daily"
    private static let dailyDelay: TimeInterval = 24 * 60 * 60
    private static let firstBackupDelay: TimeInterval = 15 * 60

    typealias BackupManagerFactory = @MainActor () -> BackupManager?

    private var factory: BackupManagerFactory?
    private var isRegistered: Bool = false
    private(set) var isBackupInProgress: Bool = false

    private init() {}

    /// Registers the background task handler. Must be called from
    /// `ConvosApp.init()` before launch completes, per `BGTaskScheduler`'s
    /// contract. The factory is invoked each time a backup runs so the
    /// caller can return `nil` when the vault isn't ready.
    func register(factory: @escaping BackupManagerFactory) {
        self.factory = factory
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { task in
            Task { @MainActor in
                await BackupScheduler.shared.handleBackgroundTask(task)
            }
        }
        isRegistered = true
        Log.info("[BackupScheduler] registered task \(Self.taskIdentifier)")
    }

    /// Submits a `BGProcessingTaskRequest` to run no earlier than `delay`
    /// seconds from now. Idempotent — submit replaces any existing request
    /// with the same identifier. No-op if `register()` hasn't been called
    /// yet (iOS asserts otherwise).
    func scheduleNextBackup(earliestIn delay: TimeInterval = BackupScheduler.dailyDelay) {
        guard isRegistered else {
            Log.warning("[BackupScheduler] scheduleNextBackup called before register — ignoring")
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: delay)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            Log.info("[BackupScheduler] next backup scheduled earliest in \(Int(delay))s")
        } catch {
            Log.error("[BackupScheduler] submit failed: \(error.localizedDescription)")
            QAEvent.emit(.backup, "schedule_failed", ["error": error.localizedDescription])
        }
    }

    /// Runs a backup from the manual "Back up now" path while holding the
    /// shared guard. Returns the resulting backup URL or nil on skip.
    /// Throws if the backup itself failed.
    @discardableResult
    func runManualBackup() async throws -> URL? {
        guard !isBackupInProgress else {
            Log.info("[BackupScheduler] manual backup skipped — already in progress")
            QAEvent.emit(.backup, "skipped_in_progress", ["source": "manual"])
            return nil
        }
        guard let manager = factory?() else {
            Log.info("[BackupScheduler] manual backup skipped — no vault")
            QAEvent.emit(.backup, "skipped_no_vault", ["source": "manual"])
            return nil
        }
        isBackupInProgress = true
        defer { isBackupInProgress = false }
        let url = try await manager.createBackup()
        QAEvent.emit(.backup, "completed", ["source": "manual"])
        scheduleNextBackup()
        return url
    }

    /// Force-runs the background path now. Intended for debug builds only
    /// so QA can verify the scheduler flow without LLDB.
    func simulateBackgroundRunForDebug() async {
        Log.info("[BackupScheduler] debug-simulated background run")
        await runBackupAndReschedule(source: "debug_simulated")
    }

    private func handleBackgroundTask(_ task: BGTask) async {
        Log.info("[BackupScheduler] background task launched")
        QAEvent.emit(.backup, "bg_task_launched")

        task.expirationHandler = {
            Log.warning("[BackupScheduler] background task expired")
            task.setTaskCompleted(success: false)
        }

        await runBackupAndReschedule(source: "background")
        task.setTaskCompleted(success: true)
    }

    private func runBackupAndReschedule(source: String) async {
        defer { scheduleNextBackup() }

        if isBackupInProgress {
            Log.info("[BackupScheduler] \(source) skipped — already in progress")
            QAEvent.emit(.backup, "skipped_in_progress", ["source": source])
            return
        }
        guard let manager = factory?() else {
            Log.info("[BackupScheduler] \(source) skipped — no vault")
            QAEvent.emit(.backup, "skipped_no_vault", ["source": source])
            return
        }

        isBackupInProgress = true
        defer { isBackupInProgress = false }

        do {
            _ = try await manager.createBackup()
            Log.info("[BackupScheduler] \(source) backup completed")
            QAEvent.emit(.backup, "completed", ["source": source])
        } catch {
            Log.error("[BackupScheduler] \(source) backup failed: \(error.localizedDescription)")
            QAEvent.emit(.backup, "failed", ["source": source, "error": error.localizedDescription])
        }
    }
}
