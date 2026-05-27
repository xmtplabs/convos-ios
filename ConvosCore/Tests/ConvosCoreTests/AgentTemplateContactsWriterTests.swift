@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("AgentTemplateContactsWriter Tests", .serialized)
struct AgentTemplateContactsWriterTests {
    /// Inserts a minimal `conversation` row so an agent-template contact can
    /// FK against it. `agentTemplateContact.addedViaConversationId`
    /// references `conversation(id)`; tests that exercise a non-nil
    /// `addedViaConversationId` need the parent row to exist first.
    private static func seedMinimalConversation(_ db: Database, id: String) throws {
        let creatorInboxId = "creator-\(id)"
        try DBMember(inboxId: creatorInboxId).save(db, onConflict: .ignore)
        try DBConversation(
            id: id,
            clientConversationId: id,
            inviteTag: "tag-\(id)",
            creatorId: creatorInboxId,
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
            hasHadVerifiedAgent: false
        ).insert(db)
    }

    @Test("upsert preserves addedAt and addedViaConversationId on subsequent calls")
    func testIdempotentUpsertPreservesIdentityColumns() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = AgentTemplateContactsWriter(databaseWriter: dbManager.dbWriter)

        let templateId = "template-1"
        let originalConversation = "conv-original"
        let later = "conv-later"

        try await dbManager.dbWriter.write { db in
            try Self.seedMinimalConversation(db, id: originalConversation)
            try Self.seedMinimalConversation(db, id: later)
        }

        try await writer.upsert(
            templateId: templateId,
            addedViaConversationId: originalConversation,
            profile: AgentTemplateContactSnapshot(
                displayName: "First",
                profileUpdatedAt: Date(timeIntervalSince1970: 100)
            )
        )

        let firstAddedAt = try await dbManager.dbReader.read { db in
            try DBAgentTemplateContact.fetchOne(db, key: templateId)?.addedAt
        }

        // Sleep briefly so the second call's "now" is meaningfully later if
        // it ever leaked into addedAt.
        try await Task.sleep(nanoseconds: 5_000_000)

        try await writer.upsert(
            templateId: templateId,
            addedViaConversationId: later,
            profile: AgentTemplateContactSnapshot(
                displayName: "Second",
                profileUpdatedAt: Date(timeIntervalSince1970: 200)
            )
        )

        let after = try await dbManager.dbReader.read { db in
            try DBAgentTemplateContact.fetchOne(db, key: templateId)
        }

        #expect(after?.addedAt == firstAddedAt)
        #expect(after?.addedViaConversationId == originalConversation)
        #expect(after?.displayName == "Second")
    }

    @Test("upsert drops older timestamped snapshots and applies newer ones")
    func testUpsertMostRecentWins() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = AgentTemplateContactsWriter(databaseWriter: dbManager.dbWriter)
        let templateId = "template-1"

        try await writer.upsert(
            templateId: templateId,
            addedViaConversationId: nil,
            profile: AgentTemplateContactSnapshot(
                displayName: "Latest",
                profileUpdatedAt: Date(timeIntervalSince1970: 200)
            )
        )

        // Older event - must be dropped.
        try await writer.upsert(
            templateId: templateId,
            addedViaConversationId: nil,
            profile: AgentTemplateContactSnapshot(
                displayName: "Older",
                profileUpdatedAt: Date(timeIntervalSince1970: 100)
            )
        )

        var stored = try await dbManager.dbReader.read { db in
            try DBAgentTemplateContact.fetchOne(db, key: templateId)
        }
        #expect(stored?.displayName == "Latest")

        // Newer event - must be applied.
        try await writer.upsert(
            templateId: templateId,
            addedViaConversationId: nil,
            profile: AgentTemplateContactSnapshot(
                displayName: "Newest",
                profileUpdatedAt: Date(timeIntervalSince1970: 300)
            )
        )

        stored = try await dbManager.dbReader.read { db in
            try DBAgentTemplateContact.fetchOne(db, key: templateId)
        }
        #expect(stored?.displayName == "Newest")
    }

    @Test("An untimestamped upsert leaves an existing row untouched")
    func testUntimestampedUpsertNoOpsOnExistingRow() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = AgentTemplateContactsWriter(databaseWriter: dbManager.dbWriter)
        let templateId = "template-1"

        try await writer.upsert(
            templateId: templateId,
            addedViaConversationId: nil,
            profile: AgentTemplateContactSnapshot(
                displayName: "Original",
                profileUpdatedAt: Date(timeIntervalSince1970: 100)
            )
        )

        try await writer.upsert(
            templateId: templateId,
            addedViaConversationId: nil,
            profile: AgentTemplateContactSnapshot(
                displayName: "FromAnotherConvo",
                emoji: "🚴",
                profileUpdatedAt: nil
            )
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBAgentTemplateContact.fetchOne(db, key: templateId)
        }
        #expect(stored?.displayName == "Original")
        #expect(stored?.emoji == nil)
        #expect(stored?.profileUpdatedAt == Date(timeIntervalSince1970: 100))
    }

    @Test("A newer snapshot wholesale-replaces every profile field")
    func testNewerSnapshotWholesaleReplacesFields() async throws {
        // The snapshot is one authoritative unit: a newer event carrying
        // only a name clears the stored emoji, mirroring ContactsWriter.
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = AgentTemplateContactsWriter(databaseWriter: dbManager.dbWriter)
        let templateId = "template-1"

        try await writer.upsert(
            templateId: templateId,
            addedViaConversationId: nil,
            profile: AgentTemplateContactSnapshot(
                displayName: "Original",
                emoji: "🚴",
                publishedURL: "https://agents-dev.convos.org/tifoso.pnw1o",
                profileUpdatedAt: Date(timeIntervalSince1970: 100)
            )
        )

        try await writer.upsert(
            templateId: templateId,
            addedViaConversationId: nil,
            profile: AgentTemplateContactSnapshot(
                displayName: "Renamed",
                profileUpdatedAt: Date(timeIntervalSince1970: 200)
            )
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBAgentTemplateContact.fetchOne(db, key: templateId)
        }
        #expect(stored?.displayName == "Renamed")
        #expect(stored?.emoji == nil)
        #expect(stored?.publishedURL == nil)
    }

    @Test("upsert inserts a new row with the snapshot fields")
    func testUpsertInsertsNewRow() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = AgentTemplateContactsWriter(databaseWriter: dbManager.dbWriter)
        let templateId = "200e27dc-badc-429f-a431-b01b0281ec95"

        try await writer.upsert(
            templateId: templateId,
            addedViaConversationId: nil,
            profile: AgentTemplateContactSnapshot(
                displayName: "Tifoso",
                emoji: "🚴",
                descriptionText: "Pro cycling expert",
                publishedURL: "https://agents-dev.convos.org/tifoso.pnw1o",
                agentVerification: .verified(.convos),
                profileUpdatedAt: Date(timeIntervalSince1970: 100)
            )
        )

        let stored = try await dbManager.dbReader.read { db in
            try DBAgentTemplateContact.fetchOne(db, key: templateId)
        }
        #expect(stored?.templateId == templateId)
        #expect(stored?.displayName == "Tifoso")
        #expect(stored?.emoji == "🚴")
        #expect(stored?.descriptionText == "Pro cycling expert")
        #expect(stored?.publishedURL == "https://agents-dev.convos.org/tifoso.pnw1o")
        #expect(stored?.agentVerification == .verified(.convos))
    }

    @Test("remove deletes the agent-template contact row")
    func testRemoveDeletesRow() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = AgentTemplateContactsWriter(databaseWriter: dbManager.dbWriter)
        let templateId = "template-1"

        try await writer.upsert(
            templateId: templateId,
            addedViaConversationId: nil,
            profile: AgentTemplateContactSnapshot(displayName: "Tifoso")
        )

        try await writer.remove(templateId: templateId)

        let count = try await dbManager.dbReader.read { db in
            try DBAgentTemplateContact.fetchCount(db)
        }
        #expect(count == 0)
    }

    @Test("remove no-ops when the templateId has no row")
    func testRemoveUnknownTemplateNoOps() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let writer = AgentTemplateContactsWriter(databaseWriter: dbManager.dbWriter)

        try await writer.remove(templateId: "ghost")

        let count = try await dbManager.dbReader.read { db in
            try DBAgentTemplateContact.fetchCount(db)
        }
        #expect(count == 0)
    }
}
