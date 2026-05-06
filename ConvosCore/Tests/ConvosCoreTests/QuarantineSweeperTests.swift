@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("QuarantineSweeper Tests", .serialized)
struct QuarantineSweeperTests {
    private static func seedConversation(
        _ db: Database,
        id: String,
        creatorId: String,
        quarantinedAt: Date?,
        quarantineReleasedAt: Date? = nil
    ) throws {
        try DBMember(inboxId: creatorId).save(db, onConflict: .ignore)
        let conversation = DBConversation(
            id: id,
            clientConversationId: id,
            inviteTag: "tag-\(id)",
            creatorId: creatorId,
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
            hasHadVerifiedAssistant: false,
            quarantinedAt: quarantinedAt,
            quarantineReleasedAt: quarantineReleasedAt
        )
        try conversation.insert(db)
    }

    private static func seedContact(_ db: Database, inboxId: String, blocked: Bool = false) throws {
        try DBContact(
            inboxId: inboxId,
            addedAt: Date(),
            addedViaConversationId: nil,
            displayName: "Test",
            blockedAt: blocked ? Date() : nil
        ).save(db)
    }

    @Test("Sweep no-ops when there are no quarantined conversations")
    func testNoOpWhenNothingQuarantined() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        let sweeper = QuarantineSweeper(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader,
            contactsRepository: ContactsRepository(databaseReader: dbManager.dbReader)
        )

        try await sweeper.sweep()

        let count = try await dbManager.dbReader.read { db in
            try DBConversation.fetchCount(db)
        }
        #expect(count == 0)
    }

    @Test("Promotes a quarantined conversation when its sender becomes a contact")
    func testPromotesWhenSenderBecomesContact() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let creator = "creator-1"
        let convId = "conv-1"
        let quarantinedAt = Date(timeIntervalSinceNow: -60)

        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db, id: convId, creatorId: creator, quarantinedAt: quarantinedAt)
            try Self.seedContact(db, inboxId: creator)
        }

        let sweeper = QuarantineSweeper(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader,
            contactsRepository: ContactsRepository(databaseReader: dbManager.dbReader)
        )

        try await sweeper.sweep()

        let row = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: convId)
        }
        #expect(row?.quarantineReleasedAt != nil)
        #expect(row?.quarantinedAt != nil)
    }

    @Test("Does not promote when the sender is a blocked contact")
    func testDoesNotPromoteBlockedContact() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let creator = "creator-1"
        let convId = "conv-1"
        let quarantinedAt = Date(timeIntervalSinceNow: -60)

        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db, id: convId, creatorId: creator, quarantinedAt: quarantinedAt)
            try Self.seedContact(db, inboxId: creator, blocked: true)
        }

        let sweeper = QuarantineSweeper(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader,
            contactsRepository: ContactsRepository(databaseReader: dbManager.dbReader)
        )

        try await sweeper.sweep()

        let row = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: convId)
        }
        #expect(row?.quarantineReleasedAt == nil)
    }

    @Test("Deletes a quarantined conversation past the TTL when sender is still a stranger")
    func testDeletesPastTTL() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let creator = "creator-1"
        let convId = "conv-1"
        let stale = Date(timeIntervalSinceNow: -(QuarantineSweeper.Constant.ttl + 60))

        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db, id: convId, creatorId: creator, quarantinedAt: stale)
        }

        let sweeper = QuarantineSweeper(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader,
            contactsRepository: ContactsRepository(databaseReader: dbManager.dbReader)
        )

        try await sweeper.sweep()

        let count = try await dbManager.dbReader.read { db in
            try DBConversation.fetchCount(db)
        }
        #expect(count == 0)
    }

    @Test("Does not delete when within TTL and sender is still a stranger")
    func testDoesNotDeleteWithinTTL() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let creator = "creator-1"
        let convId = "conv-1"
        let recent = Date(timeIntervalSinceNow: -60)

        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db, id: convId, creatorId: creator, quarantinedAt: recent)
        }

        let sweeper = QuarantineSweeper(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader,
            contactsRepository: ContactsRepository(databaseReader: dbManager.dbReader)
        )

        try await sweeper.sweep()

        let row = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: convId)
        }
        #expect(row != nil)
        #expect(row?.quarantineReleasedAt == nil)
    }

    @Test("Already-released rows are ignored by the sweeper")
    func testReleasedRowsIgnored() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let creator = "creator-1"
        let convId = "conv-1"
        let quarantinedAt = Date(timeIntervalSinceNow: -(QuarantineSweeper.Constant.ttl + 60))

        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(
                db,
                id: convId,
                creatorId: creator,
                quarantinedAt: quarantinedAt,
                quarantineReleasedAt: Date()
            )
        }

        let sweeper = QuarantineSweeper(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader,
            contactsRepository: ContactsRepository(databaseReader: dbManager.dbReader)
        )

        try await sweeper.sweep()

        // The row had an old quarantinedAt but was already released — it
        // should not be deleted.
        let row = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: convId)
        }
        #expect(row != nil)
    }
}
