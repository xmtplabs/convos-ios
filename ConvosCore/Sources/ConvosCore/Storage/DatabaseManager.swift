import Foundation
import GRDB
import SQLite3

public protocol DatabaseManagerProtocol {
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
public final class DatabaseManager: DatabaseManagerProtocol {
    let environment: AppEnvironment

    public private(set) var dbPool: DatabasePool

    public var dbWriter: DatabaseWriter {
        dbPool as DatabaseWriter
    }

    public var dbReader: DatabaseReader {
        dbPool as DatabaseReader
    }

    init(environment: AppEnvironment) {
        self.environment = environment
        do {
            dbPool = try Self.makeDatabasePool(environment: environment)
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    /// Replaces the current database with a backup copy.
    ///
    /// This is a destructive operation intended for restore scenarios only.
    /// All active database connections are closed during replacement.
    /// If the replacement fails, the original database is restored.
    public func replaceDatabase(with backupPath: URL) throws {
        let dbURL = environment.defaultDatabasesDirectoryURL.appendingPathComponent("convos.sqlite")
        let oldBackupURL = dbURL.appendingPathExtension("pre-restore")
        let walURL = URL(fileURLWithPath: dbURL.path + "-wal")
        let shmURL = URL(fileURLWithPath: dbURL.path + "-shm")
        let fileManager = FileManager.default

        // validate backup opens before touching anything
        let testQueue = try DatabaseQueue(path: backupPath.path)
        try testQueue.close()

        try dbPool.close()

        // move current DB aside as rollback safety net
        if fileManager.fileExists(atPath: dbURL.path) {
            try fileManager.moveItem(at: dbURL, to: oldBackupURL)
        }
        try? fileManager.removeItem(at: walURL)
        try? fileManager.removeItem(at: shmURL)

        do {
            try fileManager.copyItem(at: backupPath, to: dbURL)
            dbPool = try Self.makeDatabasePool(environment: environment)
            try? fileManager.removeItem(at: oldBackupURL)
        } catch {
            // rollback: restore the original DB
            try? fileManager.removeItem(at: dbURL)
            if fileManager.fileExists(atPath: oldBackupURL.path) {
                try? fileManager.moveItem(at: oldBackupURL, to: dbURL)
            }
            dbPool = try Self.makeDatabasePool(environment: environment)
            throw error
        }
    }

    private static func makeDatabasePool(environment: AppEnvironment) throws -> DatabasePool {
        let fileManager = FileManager.default
        // Use the shared App Group container so the main app and NSE share the same DB
        let groupDirURL = environment.defaultDatabasesDirectoryURL
        let dbURL = groupDirURL.appendingPathComponent("convos.sqlite")

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
