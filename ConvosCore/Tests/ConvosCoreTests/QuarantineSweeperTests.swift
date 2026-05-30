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
            hasHadVerifiedAgent: false,
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

    /// Builds a sweeper with sensible defaults. Tests that care about the
    /// XMTP-consent-bump path pass an explicit closure; tests that do not
    /// get a no-op bumper that always succeeds.
    private static func makeSweeper(
        dbManager: MockDatabaseManager,
        consentBumper: @escaping @Sendable (String) async throws -> Void = { _ in }
    ) -> QuarantineSweeper {
        QuarantineSweeper(
            databaseWriter: dbManager.dbWriter,
            databaseReader: dbManager.dbReader,
            contactsRepository: ContactsRepository(databaseReader: dbManager.dbReader),
            consentBumper: consentBumper
        )
    }

    @Test("Sweep no-ops when there are no quarantined conversations")
    func testNoOpWhenNothingQuarantined() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()

        let sweeper = Self.makeSweeper(dbManager: dbManager)

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

        let sweeper = Self.makeSweeper(dbManager: dbManager)

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

        let sweeper = Self.makeSweeper(dbManager: dbManager)

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

        let sweeper = Self.makeSweeper(dbManager: dbManager)

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

        let sweeper = Self.makeSweeper(dbManager: dbManager)

        try await sweeper.sweep()

        let row = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: convId)
        }
        #expect(row != nil)
        #expect(row?.quarantineReleasedAt == nil)
    }

    @Test("Blocked-then-unblocked: sweeper promotes the held conversation")
    func testBlockedThenUnblockedPromotion() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let creator = "creator-1"
        let convId = "conv-1"
        let quarantinedAt = Date(timeIntervalSinceNow: -60)

        // Setup: contact exists and is currently blocked. Conversation
        // arrived from this creator while blocked → quarantined.
        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db, id: convId, creatorId: creator, quarantinedAt: quarantinedAt)
            try Self.seedContact(db, inboxId: creator, blocked: true)
        }

        // First sweep with sender still blocked: no promotion.
        let firstSweeper = Self.makeSweeper(dbManager: dbManager)
        try await firstSweeper.sweep()

        let stillHeld = try await dbManager.dbReader.read { db in
            try DBContact.fetchOne(db, key: creator)
        }
        let conversationStillHeld = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: convId)
        }
        #expect(stillHeld?.blockedAt != nil)
        #expect(conversationStillHeld?.quarantineReleasedAt == nil)

        // User unblocks the contact.
        try await dbManager.dbWriter.write { db in
            guard let contact = try DBContact.fetchOne(db, key: creator) else { return }
            try contact.with(blockedAt: nil).save(db)
        }

        // Second sweep: now isContact && !isBlocked -> promote.
        let secondSweeper = Self.makeSweeper(dbManager: dbManager)
        try await secondSweeper.sweep()

        let promoted = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: convId)
        }
        #expect(promoted?.quarantineReleasedAt != nil)
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

        let sweeper = Self.makeSweeper(dbManager: dbManager)

        try await sweeper.sweep()

        // The row had an old quarantinedAt but was already released - it
        // should not be deleted.
        let row = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: convId)
        }
        #expect(row != nil)
    }

    @Test("Promotion sets consent = .allowed so the main feed query surfaces the row")
    func testPromotionFlipsConsentToAllowed() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let creator = "creator-1"
        let convId = "conv-1"
        let quarantinedAt = Date(timeIntervalSinceNow: -60)

        // Seed with the consent state a real quarantined inbound row carries:
        // `.unknown`, since `StreamProcessor.decideInboundConversation` only
        // bumps XMTP consent on the `.deliver` branch.
        try await dbManager.dbWriter.write { db in
            try DBMember(inboxId: creator).save(db, onConflict: .ignore)
            try DBConversation(
                id: convId,
                clientConversationId: convId,
                inviteTag: "tag-\(convId)",
                creatorId: creator,
                kind: .group,
                consent: .unknown,
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
                quarantinedAt: quarantinedAt,
                quarantineReleasedAt: nil
            ).insert(db)
            try Self.seedContact(db, inboxId: creator)
        }

        let sweeper = Self.makeSweeper(dbManager: dbManager)
        try await sweeper.sweep()

        let row = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: convId)
        }
        #expect(row?.quarantineReleasedAt != nil)
        #expect(row?.consent == .allowed, "Promotion must flip consent to .allowed so the main feed query surfaces the row")
    }

    @Test("XMTP consent bump failure defers the promotion to the next sweep")
    func testConsentBumpFailureDefersPromotion() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let creator = "creator-1"
        let convId = "conv-1"
        let quarantinedAt = Date(timeIntervalSinceNow: -60)

        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db, id: convId, creatorId: creator, quarantinedAt: quarantinedAt)
            try Self.seedContact(db, inboxId: creator)
        }

        struct StubError: Error {}
        let failingSweeper = Self.makeSweeper(
            dbManager: dbManager,
            consentBumper: { _ in throw StubError() }
        )
        try await failingSweeper.sweep()

        let stillHeld = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: convId)
        }
        #expect(stillHeld?.quarantineReleasedAt == nil, "Failed XMTP bump must leave the row quarantined for next sweep")

        // Next sweep with a working bumper retries successfully.
        let recoveringSweeper = Self.makeSweeper(dbManager: dbManager)
        try await recoveringSweeper.sweep()

        let promoted = try await dbManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: convId)
        }
        #expect(promoted?.quarantineReleasedAt != nil)
        #expect(promoted?.consent == .allowed)
    }

    @Test("Sweeper invokes the consentBumper exactly once per promoted conversation")
    func testConsentBumperInvokedOncePerPromotion() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let quarantinedAt = Date(timeIntervalSinceNow: -60)

        try await dbManager.dbWriter.write { db in
            try Self.seedConversation(db, id: "conv-a", creatorId: "alice", quarantinedAt: quarantinedAt)
            try Self.seedConversation(db, id: "conv-b", creatorId: "bob", quarantinedAt: quarantinedAt)
            try Self.seedContact(db, inboxId: "alice")
            try Self.seedContact(db, inboxId: "bob")
        }

        let recorder = ConversationIdRecorder()
        let sweeper = Self.makeSweeper(
            dbManager: dbManager,
            consentBumper: { conversationId in
                await recorder.record(conversationId)
            }
        )
        try await sweeper.sweep()

        let seen = await recorder.values
        #expect(Set(seen) == Set(["conv-a", "conv-b"]))
        #expect(seen.count == 2, "Bumper must not be called twice per promotion")
    }
}

/// Records the conversationIds passed to a stubbed consentBumper closure
/// in a Sendable-safe way for the assertion at the end of the test.
private actor ConversationIdRecorder {
    private(set) var values: [String] = []
    func record(_ conversationId: String) {
        values.append(conversationId)
    }
}
