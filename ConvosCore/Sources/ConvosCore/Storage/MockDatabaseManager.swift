import Foundation
import GRDB

final class MockDatabaseManager: DatabaseManagerProtocol, @unchecked Sendable {
    static let shared: MockDatabaseManager = MockDatabaseManager()
    static let previews: MockDatabaseManager = MockDatabaseManager(migrate: false)

    let dbPool: DatabaseQueue

    var dbWriter: DatabaseWriter {
        dbPool as DatabaseWriter
    }

    var dbReader: DatabaseReader {
        dbPool as DatabaseReader
    }

    func erase() throws {
        try dbPool.erase()
        try SharedDatabaseMigrator.shared.migrate(database: dbPool)
    }

    /// Mirror of `DatabaseManager.replaceDatabase` for test fixtures.
    /// Skips `NSFileCoordinator` (single-process) and the WAL checkpoint
    /// (in-memory queues don't use WAL), but preserves the same
    /// rollback-snapshot + migration semantics so tests exercise the
    /// contract rather than the transport.
    func replaceDatabase(with backupPath: URL) throws {
        guard FileManager.default.fileExists(atPath: backupPath.path) else {
            throw DatabaseManagerError.backupFileMissing(backupPath)
        }
        let rollbackQueue = try DatabaseQueue()
        try dbPool.backup(to: rollbackQueue)

        let backupQueue = try DatabaseQueue(path: backupPath.path)
        do {
            try backupQueue.backup(to: dbPool)
            try SharedDatabaseMigrator.shared.migrate(database: dbPool)
        // swiftlint:disable:next untyped_error_in_catch
        } catch let copyError {
            do {
                try rollbackQueue.backup(to: dbPool)
                try SharedDatabaseMigrator.shared.migrate(database: dbPool)
            // swiftlint:disable:next untyped_error_in_catch
            } catch let rollbackError {
                throw DatabaseManagerError.rollbackFailed(
                    original: copyError,
                    rollback: rollbackError
                )
            }
            throw copyError
        }
    }

    private init(migrate: Bool = true) {
        do {
            dbPool = try DatabaseQueue(named: "MockDatabase")
            if migrate {
                try SharedDatabaseMigrator.shared.migrate(database: dbPool)
            }
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    /// Create a fresh test database with a unique name for test isolation
    static func makeTestDatabase() -> MockDatabaseManager {
        // Create unique instance with in-memory database for test isolation
        do {
            let instance = try DatabaseQueue()
            try SharedDatabaseMigrator.shared.migrate(database: instance)
            return MockDatabaseManager(dbPool: instance)
        } catch {
            fatalError("Failed to create test database: \(error)")
        }
    }

    /// Private init for creating test instances with custom database
    private init(dbPool: DatabaseQueue) {
        self.dbPool = dbPool
    }
}
