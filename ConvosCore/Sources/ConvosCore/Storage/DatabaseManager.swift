import Foundation
import GRDB
import SQLite3

public protocol DatabaseManagerProtocol: Sendable {
    var dbWriter: DatabaseWriter { get }
    var dbReader: DatabaseReader { get }

    /// Replace the live database contents with a GRDB file at `backupPath`.
    ///
    /// Pool-to-pool copy through GRDB's `backup(to:)`; the existing
    /// `DatabasePool` instance is preserved so long-lived readers/
    /// writers held elsewhere in the app remain valid across the swap.
    /// A rollback snapshot is captured before the copy begins — any
    /// failure past the first write triggers a restore of the
    /// pre-restore state. Double-fault (replace fails AND rollback
    /// fails) throws `DatabaseManagerError.rollbackFailed`, which the
    /// UI must treat as fatal.
    ///
    /// Runs under an `NSFileCoordinator` write barrier so a coordinated
    /// reader in another process (the NSE) waits for completion rather
    /// than opening the file mid-write.
    func replaceDatabase(with backupPath: URL) throws
}

public enum DatabaseManagerError: Error, LocalizedError {
    case backupFileMissing(URL)
    case rollbackFailed(original: any Error, rollback: any Error)

    public var errorDescription: String? {
        switch self {
        case let .backupFileMissing(url):
            return "Backup database file not found at \(url.path)"
        case let .rollbackFailed(original, rollback):
            return "Database replacement failed (\(original)) and rollback also failed (\(rollback)). Reinstall required."
        }
    }
}

/// Manages the SQLite database for Convos
///
/// DatabaseManager initializes and configures the GRDB database pool with WAL mode
/// for concurrent access between the main app and notification extension. The database
/// is stored in the shared App Group container to enable multi-process access.
/// Configures connection pooling, busy timeouts, and persistent WAL mode for
/// read-only processes.
public final class DatabaseManager: DatabaseManagerProtocol, @unchecked Sendable {
    let environment: AppEnvironment

    public let dbPool: DatabasePool
    private let dbURL: URL

    public var dbWriter: DatabaseWriter {
        dbPool as DatabaseWriter
    }

    public var dbReader: DatabaseReader {
        dbPool as DatabaseReader
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        // Detect and wipe pre-single-inbox artifacts before opening the database.
        // On upgrade from any prior version the old GRDB file and XMTP db3s are
        // removed so the migration below runs against a clean directory.
        LegacyDataWipe.runIfNeeded(environment: environment)
        do {
            let (pool, url) = try Self.makeDatabasePool(environment: environment)
            dbPool = pool
            dbURL = url
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    public func replaceDatabase(with backupPath: URL) throws {
        guard FileManager.default.fileExists(atPath: backupPath.path) else {
            throw DatabaseManagerError.backupFileMissing(backupPath)
        }

        // Capture a pre-restore snapshot before touching the live pool.
        // If the incoming copy fails partway through, we replay this.
        Log.info("replaceDatabase: capturing rollback snapshot")
        let rollbackQueue = try DatabaseQueue()
        try dbPool.backup(to: rollbackQueue)

        // Checkpoint the WAL into the main DB file before handing off
        // to the coordinator — leaves the on-disk file a consistent
        // self-contained snapshot so any process that coordinates a
        // read after the barrier sees the new contents, not a mixture
        // of new pages + stale WAL tail.
        do {
            try dbPool.writeWithoutTransaction { db in
                try db.checkpoint(.truncate)
            }
        } catch {
            Log.warning("replaceDatabase: WAL checkpoint failed: \(error); continuing")
        }

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var innerError: (any Error)?

        coordinator.coordinate(
            writingItemAt: dbURL,
            options: [.forReplacing],
            error: &coordinationError
        ) { _ in
            do {
                try performReplace(backupPath: backupPath, rollbackQueue: rollbackQueue)
            } catch {
                innerError = error
            }
        }

        if let coordinationError {
            throw coordinationError
        }
        if let innerError {
            throw innerError
        }
    }

    private func performReplace(
        backupPath: URL,
        rollbackQueue: DatabaseQueue
    ) throws {
        let backupQueue = try DatabaseQueue(path: backupPath.path)

        do {
            Log.info("replaceDatabase: copying backup pages into live pool")
            try backupQueue.backup(to: dbPool)
            Log.info("replaceDatabase: running migrations against restored schema")
            try SharedDatabaseMigrator.shared.migrate(database: dbPool)
            Log.info("replaceDatabase: success")
        // swiftlint:disable:next untyped_error_in_catch
        } catch let copyError {
            Log.warning("replaceDatabase failed (\(copyError)), rolling back")
            do {
                try rollbackQueue.backup(to: dbPool)
                try SharedDatabaseMigrator.shared.migrate(database: dbPool)
                Log.info("replaceDatabase: rollback succeeded")
            // swiftlint:disable:next untyped_error_in_catch
            } catch let rollbackError {
                Log.error("replaceDatabase: rollback failed — DB in indeterminate state")
                throw DatabaseManagerError.rollbackFailed(
                    original: copyError,
                    rollback: rollbackError
                )
            }
            throw copyError
        }
    }

    private static func makeDatabasePool(environment: AppEnvironment) throws -> (DatabasePool, URL) {
        let fileManager = FileManager.default
        // Shared App Group container so the main app and NSE share the same DB.
        let groupDirURL = environment.defaultDatabasesDirectoryURL
        let dbURL = groupDirURL.appendingPathComponent("convos-single-inbox.sqlite")

        // Ensure the App Group directory exists
        try fileManager.createDirectory(at: groupDirURL, withIntermediateDirectories: true)

        var config = Configuration()
        // Add process identifier to help with debugging concurrent access issues
        let isNSE = Bundle.main.bundleIdentifier?.contains("NotificationService") ?? false
        config.label = isNSE ? "ConvosDB-NSE" : "ConvosDB-MainApp"
        config.foreignKeysEnabled = true
        // Improve concurrent access handling for multi-process scenarios (NSE + Main App)
        config.maximumReaderCount = 5  // Allow multiple readers
        config.busyMode = .timeout(10.0)  // Wait up to 10 seconds for locks

        config.journalMode = .wal

        config.prepareDatabase { db in
            // Activate the persistent WAL mode so that
            // read-only processes can access the database.
            //
            // See https://www.sqlite.org/walformat.html#operations_that_require_locks_and_which_locks_those_operations_use
            // and https://www.sqlite.org/c3ref/c_fcntl_begin_atomic_write.html#sqlitefcntlpersistwal
            if db.configuration.readonly == false {
                var flag: CInt = 1
                let code = withUnsafeMutablePointer(to: &flag) { flagP in
                    sqlite3_file_control(db.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, flagP)
                }
                guard code == SQLITE_OK else {
                    throw DatabaseError(resultCode: ResultCode(rawValue: code))
                }
            }
#if DEBUG
            db.trace { Log.info("\($0)") }
#endif
        }

        let dbPool = try DatabasePool(path: dbURL.path, configuration: config)
        let migrator = SharedDatabaseMigrator.shared
        try migrator.migrate(database: dbPool)
        return (dbPool, dbURL)
    }
}
