@testable import ConvosCore
import Foundation
import GRDB
import Testing

/// Guards `addConversationAddedById` — specifically its *position* in the
/// migrator.
///
/// Migration registration is append-only. A migration inserted ahead of an
/// already-shipped one reorders the registered list relative to databases that
/// already applied the later ones, and the DEBUG `eraseDatabaseOnSchemaChange`
/// replay then treats that as a schema change and erases an upgrading user's
/// database. DEBUG covers the Dev and PR TestFlight configs, so the blast
/// radius is real users, not just local builds.
///
/// A fresh migrate passes either way — which is exactly why this slipped
/// through review once. These tests drive the *upgrade* path: migrate to the
/// migration that shipped immediately before this one, then finish, and check
/// the column arrives in place.
@Suite("addConversationAddedById migration", .serialized)
struct ConversationAddedByIdMigrationTests {
    /// The last migration registered before `addConversationAddedById`.
    private static let previousTailMigration: String = "addConversationIsAgentDm"

    private static func conversationHasAddedById(_ db: Database) throws -> Bool {
        try db.columns(in: "conversation").contains { $0.name == "addedById" }
    }

    @Test("Registered after the previously-shipped tail migration, not ahead of it")
    func testRegisteredAfterPreviousTail() throws {
        let database = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(
            database: database,
            upTo: Self.previousTailMigration
        )

        // If this migration were registered earlier in the list, stopping at
        // the previous tail would already have added the column.
        try database.read { db in
            let hasColumn = try Self.conversationHasAddedById(db)
            #expect(!hasColumn)
        }
    }

    @Test("Applies in place to a database that stopped before it")
    func testAppliesOnUpgrade() throws {
        let database = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(
            database: database,
            upTo: Self.previousTailMigration
        )
        try SharedDatabaseMigrator.shared.migrate(database: database)

        try database.read { db in
            let hasColumn = try Self.conversationHasAddedById(db)
            #expect(hasColumn)
        }
    }

    @Test("A fresh install gets the column too")
    func testAppliesOnFreshInstall() throws {
        let database = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: database)

        try database.read { db in
            let hasColumn = try Self.conversationHasAddedById(db)
            #expect(hasColumn)
        }
    }

    @Test("Rows written before the migration survive it, defaulting to NULL")
    func testPreExistingRowsSurviveWithNullAdder() throws {
        let database = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(
            database: database,
            upTo: Self.previousTailMigration
        )

        // Raw SQL: `DBConversation` encodes today's full column set, which the
        // historical schema doesn't have yet. `debugInfo` is non-optional on
        // the model, so it still has to be supplied for the read-back below.
        let debugInfo = String(decoding: try JSONEncoder().encode(ConversationDebugInfo.empty), as: UTF8.self)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO conversation
                        (id, clientConversationId, inviteTag, creatorId, kind, consent,
                         createdAt, includeInfoInPublicPreview, isLocked, isUnused,
                         hasHadVerifiedAgent, debugInfo)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 0, ?)
                    """,
                arguments: [
                    "convo-legacy", "client-convo-legacy", "tag-convo-legacy", "creator-inbox",
                    ConversationKind.group.rawValue, Consent.allowed.rawValue, Date(), debugInfo
                ]
            )
        }

        try SharedDatabaseMigrator.shared.migrate(database: database)

        let row = try database.read { db in
            try DBConversation.fetchOne(db, key: "convo-legacy")
        }
        #expect(row != nil)
        #expect(row?.addedById == nil)
        // The migration must not disturb the rest of the row.
        #expect(row?.creatorId == "creator-inbox")
        #expect(row?.consent == .allowed)
    }
}
