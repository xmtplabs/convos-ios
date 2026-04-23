import Foundation
import GRDB
import SQLite3

public protocol DatabaseManagerProtocol: Sendable {
    var dbWriter: DatabaseWriter { get }
    var dbReader: DatabaseReader { get }
    func replaceDatabase(with backupPath: URL) throws
}

/// Manages the SQLite database for Convos
///
/// DatabaseManager initializes and configures the GRDB database pool with WAL mode
/// for concurrent access between the main app and notification extension. The database
/// is stored in the shared App Group container to enable multi-process access.
/// Configures connection pooling, busy timeouts, and persistent WAL mode for
/// read-only processes.
public final class DatabaseManager: DatabaseManagerProtocol, @unchecked Sendable {
    static let databaseFilename: String = "convos-single-inbox.sqlite"

    let environment: AppEnvironment

    public let dbPool: DatabasePool

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
            dbPool = try Self.makeDatabasePool(environment: environment)
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    /// Replaces the current database with a backup copy using a pool-to-pool
    /// copy. The existing `DatabasePool` instance is preserved so long-lived
    /// readers and writers held elsewhere in the app remain valid after restore.
    ///
    /// Discipline: take a rollback snapshot first, truncate the WAL so on-disk
    /// state reflects pending writes, then run the copy under an
    /// `NSFileCoordinator` write barrier so other coordinated processes (the
    /// NSE) serialize around the swap. On failure, restore from the snapshot;
    /// on double-fault, surface `DatabaseManagerError.rollbackFailed`.
    public func replaceDatabase(with backupPath: URL) throws {
        guard FileManager.default.fileExists(atPath: backupPath.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        Log.info("DatabaseManager: opening backup at \(backupPath.lastPathComponent)")
        let backupQueue = try DatabaseQueue(path: backupPath.path)

        Log.info("DatabaseManager: creating rollback snapshot")
        let rollbackQueue = try DatabaseQueue()
        try dbPool.backup(to: rollbackQueue)

        // WAL checkpoint + truncate so the sqlite file alone is fully up-to-date
        // before any coordinated reader observes the swap.
        try dbPool.writeWithoutTransaction { db in
            try db.checkpoint(.truncate)
        }

        let dbURL = environment.defaultDatabasesDirectoryURL
            .appendingPathComponent(Self.databaseFilename)

        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var swapError: (any Error)?

        coordinator.coordinate(writingItemAt: dbURL, options: [], error: &coordinationError) { _ in
            do {
                try backupQueue.backup(to: dbPool)
                try SharedDatabaseMigrator.shared.migrate(database: dbPool)
            } catch {
                swapError = error
            }
        }

        if let coordinationError, swapError == nil {
            swapError = coordinationError
        }

        guard let swapError else {
            Log.info("DatabaseManager: database replacement succeeded")
            return
        }

        Log.warning("DatabaseManager: replacement failed (\(swapError)), rolling back")
        do {
            try rollbackQueue.backup(to: dbPool)
            try SharedDatabaseMigrator.shared.migrate(database: dbPool)
            Log.info("DatabaseManager: rollback succeeded")
        } catch let rollbackError as any Error {
            Log.error("DatabaseManager: rollback failed (original: \(swapError)) — \(rollbackError)")
            throw DatabaseManagerError.rollbackFailed(
                original: swapError,
                rollback: rollbackError
            )
        }
        throw swapError
    }

    private static func makeDatabasePool(environment: AppEnvironment) throws -> DatabasePool {
        let fileManager = FileManager.default
        // Shared App Group container so the main app and NSE share the same DB.
        let groupDirURL = environment.defaultDatabasesDirectoryURL
        let dbURL = groupDirURL.appendingPathComponent(databaseFilename)

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
        return dbPool
    }
}

public enum DatabaseManagerError: Error, LocalizedError {
    /// The restore failed AND the rollback also failed. The DB is in a
    /// potentially-inconsistent state — the caller should treat this as
    /// recoverable only via app reinstall or a fresh restore attempt.
    case rollbackFailed(original: any Error, rollback: any Error)

    public var errorDescription: String? {
        switch self {
        case let .rollbackFailed(original, rollback):
            return "Database restore failed and rollback also failed. "
                + "Original error: \(original.localizedDescription). "
                + "Rollback error: \(rollback.localizedDescription)"
        }
    }
}
