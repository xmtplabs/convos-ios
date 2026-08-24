import Foundation
import GRDB

/// Migrator for `agent-chat.sqlite`. Separate from `SharedDatabaseMigrator`
/// and never erases on schema change: the transcript is user data.
public enum AgentChatMigrations {
    public static func migrate(_ writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-agent-turn") { db in
            try db.execute(sql: """
            CREATE TABLE agent_turn (
              requestId      TEXT PRIMARY KEY,
              provider       TEXT NOT NULL,
              status         TEXT NOT NULL,
              prompt         TEXT NOT NULL,
              resultMessage  TEXT,
              resultLinks    BLOB,
              errorCode      TEXT,
              createdAt      REAL NOT NULL,
              expiresAt      REAL NOT NULL,
              completedAt    REAL,
              ackedAt        REAL
            )
            """)
            try db.execute(sql: "CREATE INDEX agent_turn_status_created ON agent_turn(status, createdAt)")
        }
        try migrator.migrate(writer)
    }
}
