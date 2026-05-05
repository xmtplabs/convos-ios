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

    func replaceDatabase(with backupPath: URL) throws {
        // `DatabaseQueue(path:)` silently creates an empty file at a
        // non-existent path, which would mask a missing-source bug by
        // wiping the mock instead of throwing. Mirror what the real
        // implementation does in spirit and refuse to "restore from
        // nothing".
        guard FileManager.default.fileExists(atPath: backupPath.path) else {
            throw MockDatabaseManagerError.backupSourceMissing(backupPath.path)
        }
        let backupQueue = try DatabaseQueue(path: backupPath.path)
        try backupQueue.backup(to: dbPool)
        try SharedDatabaseMigrator.shared.migrate(database: dbPool)
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

enum MockDatabaseManagerError: Error, CustomStringConvertible {
    case backupSourceMissing(String)

    var description: String {
        switch self {
        case .backupSourceMissing(let path):
            return "MockDatabaseManager.replaceDatabase: backup source does not exist at \(path)"
        }
    }
}
