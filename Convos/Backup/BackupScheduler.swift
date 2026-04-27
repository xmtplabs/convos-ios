import BackgroundTasks
import ConvosCore
import Foundation
import UIKit

/// Coordinates daily backups via `BGProcessingTask`, plus a foreground
/// catch-up path that fires on launch/foreground when the last
/// successful backup is older than 24 hours.
///
/// Lives in the main app target because `BGTaskScheduler` is iOS-only.
/// Holds a process-global `isBackupInProgress` flag so the background
/// handler, the manual "Back up now" path, and the foreground catch-up
/// can't run the same backup concurrently.
///
/// Honors `RestoreInProgressFlag` — if a restore transaction is active,
/// every backup path skips immediately and reschedules. Reads
/// `lastSuccessfulBackupAt` from the shared app-group defaults so a
/// prior launch's successful run persists across process restarts.
@MainActor
final class BackupScheduler {
    static let shared: BackupScheduler = BackupScheduler()

    static let taskIdentifier: String = "org.convos.backup.daily"
    private static let dailyDelay: TimeInterval = 24 * 60 * 60
    private static let firstBackupDelay: TimeInterval = 15 * 60
    private static let foregroundCatchUpThreshold: TimeInterval = 24 * 60 * 60
    private static let lastBackupAtKey: String = "convos.backup.lastSuccessfulAt"

    typealias BackupManagerFactory = @MainActor () -> BackupManager?
    typealias EnvironmentResolver = @MainActor () -> AppEnvironment?

    private var factory: BackupManagerFactory?
    private var environmentResolver: EnvironmentResolver?
    private var isRegistered: Bool = false

    /// Process-global mutex across manual, background, and catch-up
    /// backup paths. Safe to read+write without extra locking — class
    /// is @MainActor-isolated and every entry point checks+sets this
    /// flag in a synchronous block before any `await`.
    private(set) var isBackupInProgress: Bool = false

    private init() {}

    // MARK: - Registration

    /// Registers the background task handler. Must be called from
    /// `ConvosApp.init()` before launch completes.
    /// `factory` returns nil when no identity is available yet.
    func register(
        environment: @escaping EnvironmentResolver,
        factory: @escaping BackupManagerFactory
    ) {
        guard !isRegistered else {
            Log.warning("[BackupScheduler] register called more than once — ignoring")
            return
        }
        self.environmentResolver = environment
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

    /// Submits a `BGProcessingTaskRequest` to run no earlier than
    /// `delay` seconds from now. Idempotent — submit replaces any
    /// existing request with the same identifier.
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

    // MARK: - Entry points

    /// Manual "Back up now" from the settings view. Returns the bundle
    /// URL on success or nil on skip (restore in progress, already
    /// running, no identity). Throws on an actual backup failure.
    @discardableResult
    func runManualBackup() async throws -> URL? {
        try await runIfAllowed(source: "manual", shouldRethrow: true)
    }

    /// Runs the backup if the last successful timestamp is older than
    /// the threshold. Non-throwing — a catch-up failure logs telemetry
    /// and moves on. Safe to call repeatedly on launch + foreground.
    func runForegroundCatchUpIfNeeded() async {
        guard isRegistered else { return }
        let last = lastSuccessfulBackupAt()
        if let last, Date().timeIntervalSince(last) < Self.foregroundCatchUpThreshold {
            return
        }
        Log.info("[BackupScheduler] foreground catch-up triggered (lastBackup=\(last?.description ?? "never"))")
        QAEvent.emit(.backup, "catch_up_triggered")
        _ = try? await runIfAllowed(source: "catch_up", shouldRethrow: false)
    }

    /// Debug-only entry so QA can exercise the BG task flow without
    /// hooking LLDB.
    func simulateBackgroundRunForDebug() async {
        Log.info("[BackupScheduler] debug-simulated background run")
        await runBackupAndReschedule(source: "debug_simulated")
    }

    // MARK: - BGTask handler

    private func handleBackgroundTask(_ task: BGTask) async {
        Log.info("[BackupScheduler] background task launched")
        QAEvent.emit(.backup, "bg_task_launched")

        // `setTaskCompleted` twice is undefined. Expiration can fire on
        // any queue, so share a lock-protected flag.
        let state = BGTaskCompletionState()
        task.expirationHandler = {
            guard state.markCompletedOnce() else { return }
            Log.warning("[BackupScheduler] background task expired")
            task.setTaskCompleted(success: false)
        }

        await runBackupAndReschedule(source: "background")

        guard state.markCompletedOnce() else { return }
        task.setTaskCompleted(success: true)
    }

    private final class BGTaskCompletionState: @unchecked Sendable {
        private let lock: NSLock = NSLock()
        private var completed: Bool = false

        func markCompletedOnce() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if completed { return false }
            completed = true
            return true
        }
    }

    // MARK: - Shared backup runner

    private func runBackupAndReschedule(source: String) async {
        defer { scheduleNextBackup() }
        _ = try? await runIfAllowed(source: source, shouldRethrow: false)
    }

    private func runIfAllowed(source: String, shouldRethrow: Bool) async throws -> URL? {
        if isBackupInProgress {
            Log.info("[BackupScheduler] \(source) skipped — already in progress")
            QAEvent.emit(.backup, "skipped_in_progress", ["source": source])
            return nil
        }

        if let environment = environmentResolver?(),
           RestoreInProgressFlag.isSet(environment: environment) {
            Log.info("[BackupScheduler] \(source) skipped — restore in progress")
            QAEvent.emit(.backup, "skipped_restore_in_progress", ["source": source])
            return nil
        }

        guard let manager = factory?() else {
            Log.info("[BackupScheduler] \(source) skipped — no identity")
            QAEvent.emit(.backup, "skipped_no_identity", ["source": source])
            return nil
        }

        isBackupInProgress = true
        defer { isBackupInProgress = false }

        do {
            let url = try await manager.createBackup()
            recordSuccessfulBackup()
            Log.info("[BackupScheduler] \(source) backup completed")
            QAEvent.emit(.backup, "completed", ["source": source])
            return url
        } catch BackupError.noConversationsToBackUp {
            Log.info("[BackupScheduler] \(source) skipped — no conversations yet")
            QAEvent.emit(.backup, "skipped_no_conversations", ["source": source])
            return nil
        } catch BackupError.currentInstallationRevoked {
            Log.info("[BackupScheduler] \(source) skipped — installation revoked")
            QAEvent.emit(.backup, "skipped_installation_revoked", ["source": source])
            return nil
        } catch {
            Log.error("[BackupScheduler] \(source) backup failed: \(error.localizedDescription)")
            QAEvent.emit(.backup, "failed", ["source": source, "error": error.localizedDescription])
            if shouldRethrow {
                throw error
            }
            return nil
        }
    }

    // MARK: - Last-success timestamp

    private func lastSuccessfulBackupAt() -> Date? {
        guard let environment = environmentResolver?() else { return nil }
        let defaults = UserDefaults(suiteName: environment.appGroupIdentifier) ?? .standard
        return defaults.object(forKey: Self.lastBackupAtKey) as? Date
    }

    private func recordSuccessfulBackup() {
        guard let environment = environmentResolver?() else { return }
        let defaults = UserDefaults(suiteName: environment.appGroupIdentifier) ?? .standard
        defaults.set(Date(), forKey: Self.lastBackupAtKey)
    }
}
