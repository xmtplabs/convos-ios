@testable import ConvosCore
import Foundation
import GRDB

/// Shared helpers for the profile store tests: build an in-memory database with
/// the Profile-table schema (plus a minimal `conversation` table the avatar and
/// job foreign keys reference) and seed conversation rows.
enum ProfileStoreTestSupport {
    static func makeSchema(_ db: Database) throws {
        try db.create(table: "conversation") { t in
            t.column("id", .text).notNull().primaryKey()
        }
        try SharedDatabaseMigrator.createProfileTables(db)
    }

    static func seedConversations(_ db: Database, ids: [String]) throws {
        for id in ids {
            try db.execute(sql: "INSERT INTO conversation (id) VALUES (?)", arguments: [id])
        }
    }

    static func makeQueue(conversations: [String] = []) throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try makeSchema(db)
            try seedConversations(db, ids: conversations)
        }
        return queue
    }
}
