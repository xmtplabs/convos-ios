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

    @Test("Rows written before the migration survive it, defaulting to notRecorded")
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
        // Legacy rows adjudicate on the creator alone, as they did before the
        // column existed - not fail-closed, which would freeze them out of
        // promotion until something rewrote them.
        #expect(row?.adderStatus == .notRecorded)
        #expect(row?.adder == .notRecorded)
        // The migration must not disturb the rest of the row.
        #expect(row?.creatorId == "creator-inbox")
        #expect(row?.consent == .allowed)
    }

    @Test("The CHECK rejects a status that disagrees with addedById")
    func testCheckConstraintRejectsInconsistentPair() throws {
        let database = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: database)

        let debugInfo = String(decoding: try JSONEncoder().encode(ConversationDebugInfo.empty), as: UTF8.self)
        let insertInconsistent: (Database, String, String?, String) throws -> Void = { db, id, addedById, status in
            try db.execute(
                sql: """
                    INSERT INTO conversation
                        (id, clientConversationId, inviteTag, creatorId, kind, consent,
                         createdAt, includeInfoInPublicPreview, isLocked, isUnused,
                         hasHadVerifiedAgent, debugInfo, addedById, adderStatus)
                    VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, 0, 0, ?, ?, ?)
                    """,
                arguments: [
                    id, "client-\(id)", "tag-\(id)", "creator-inbox",
                    ConversationKind.group.rawValue, Consent.allowed.rawValue, Date(), debugInfo,
                    addedById, status
                ]
            )
        }

        // resolved without an id, and an id without resolved.
        #expect(throws: DatabaseError.self) {
            try database.write { db in try insertInconsistent(db, "bad-1", nil, AdderStatus.resolved.rawValue) }
        }
        #expect(throws: DatabaseError.self) {
            try database.write { db in try insertInconsistent(db, "bad-2", "adder-inbox", AdderStatus.unresolved.rawValue) }
        }
        try database.write { db in
            try insertInconsistent(db, "good", "adder-inbox", AdderStatus.resolved.rawValue)
        }
    }

    @Test("Every AdderResolution case round-trips through the row")
    func testAdderRoundTrips() throws {
        let database = try DatabaseQueue()
        try SharedDatabaseMigrator.shared.migrate(database: database)

        let cases: [AdderResolution] = [.known("adder-inbox"), .none, .unresolved, .notRecorded]
        for (index, adder) in cases.enumerated() {
            let id = "convo-\(index)"
            try database.write { db in
                try DBMember(inboxId: "creator-inbox").save(db, onConflict: .ignore)
                try Self.makeConversation(id: id, adder: adder).insert(db)
            }
            let row = try database.read { db in try DBConversation.fetchOne(db, key: id) }
            #expect(row?.adder == adder)
        }
    }

    private static func makeConversation(id: String, adder: AdderResolution) -> DBConversation {
        DBConversation(
            id: id,
            clientConversationId: "client-\(id)",
            inviteTag: "tag-\(id)",
            creatorId: "creator-inbox",
            kind: .group,
            consent: .allowed,
            createdAt: Date(),
            name: nil,
            description: nil,
            imageURLString: nil,
            publicImageURLString: nil,
            includeInfoInPublicPreview: false,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            imageLastRenewed: nil,
            isUnused: false,
            hasHadVerifiedAgent: false,
            adder: adder
        )
    }
}
