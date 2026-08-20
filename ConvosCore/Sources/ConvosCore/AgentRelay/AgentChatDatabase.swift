import Foundation
import GRDB
import SQLite3

/// Owns the `agent-chat.sqlite` pool in the app group container. Opened by
/// the main app and by the NotificationService extension, so the pool uses
/// WAL with the persist-WAL file control and a busy timeout, mirroring the
/// conversation database without sharing its migrator.
public final class AgentChatDatabase: Sendable {
    public let pool: DatabasePool

    public init(environment: AppEnvironment) throws {
        let directory = environment.defaultDatabasesDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(Constant.fileName)
        pool = try Self.openPool(at: url.path)
    }

    /// A throwaway database for tests: a unique temporary file, because a
    /// `DatabasePool` cannot be opened on an in-memory database.
    public static func inMemoryForTests() throws -> AgentChatDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-chat-\(UUID().uuidString).sqlite")
        return try AgentChatDatabase(pool: openPool(at: url.path))
    }

    private init(pool: DatabasePool) {
        self.pool = pool
    }

    private static func openPool(at path: String) throws -> DatabasePool {
        var config = Configuration()
        let isNSE = Bundle.main.bundleIdentifier?.contains("NotificationService") ?? false
        config.label = isNSE ? "AgentChatDB-NSE" : "AgentChatDB-MainApp"
        config.foreignKeysEnabled = true
        config.maximumReaderCount = 5
        config.busyMode = .timeout(10.0)
        config.journalMode = .wal
        config.prepareDatabase { db in
            // Persistent WAL so a second process (the NSE) can open the file.
            // No statement tracing here: the transcript holds user prompts.
            if db.configuration.readonly == false {
                var flag: CInt = 1
                let code = withUnsafeMutablePointer(to: &flag) { flagP in
                    sqlite3_file_control(db.sqliteConnection, nil, SQLITE_FCNTL_PERSIST_WAL, flagP)
                }
                guard code == SQLITE_OK else {
                    throw DatabaseError(resultCode: ResultCode(rawValue: code))
                }
            }
        }
        let pool = try DatabasePool(path: path, configuration: config)
        try AgentChatMigrations.migrate(pool)
        return pool
    }

    private enum Constant {
        static let fileName: String = "agent-chat.sqlite"
    }
}
