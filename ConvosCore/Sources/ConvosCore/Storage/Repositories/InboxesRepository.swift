import Foundation
import GRDB

/// Repository for fetching inbox data from the database
public struct InboxesRepository {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    /// Fetch all inboxes from the database
    public func allInboxes() throws -> [Inbox] {
        try databaseReader.read { db in
            try DBInbox
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    /// Fetch a specific inbox by inboxId
    public func inbox(for inboxId: String) throws -> Inbox? {
        try databaseReader.read { db in
            try DBInbox
                .fetchOne(db, id: inboxId)?
                .toDomain()
        }
    }

    /// Fetch inbox by clientId
    public func inbox(byClientId clientId: String) throws -> Inbox? {
        try databaseReader.read { db in
            try DBInbox
                .filter(DBInbox.Columns.clientId == clientId)
                .fetchOne(db)?
                .toDomain()
        }
    }

    public func vaultInbox() throws -> Inbox? {
        try databaseReader.read { db in
            try DBInbox
                .filter(DBInbox.Columns.isVault == true)
                .fetchOne(db)?
                .toDomain()
        }
    }

    public func nonVaultInboxes() throws -> [Inbox] {
        try databaseReader.read { db in
            try DBInbox
                .filter(DBInbox.Columns.isVault == false)
                .fetchAll(db)
                .map { $0.toDomain() }
        }
    }

    public func nonVaultUsedInboxes() throws -> [Inbox] {
        try databaseReader.read { db in
            let sql = """
                SELECT i.*
                FROM inbox i
                WHERE i.isVault = 0
                    AND EXISTS (
                        SELECT 1
                        FROM conversation c
                        WHERE c.inboxId = i.inboxId
                            AND c.isUnused = 0
                    )
                """
            return try DBInbox.fetchAll(db, sql: sql).map { $0.toDomain() }
        }
    }
}
