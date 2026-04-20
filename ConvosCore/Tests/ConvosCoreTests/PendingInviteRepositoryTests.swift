@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("PendingInviteRepository Tests", .serialized)
struct PendingInviteRepositoryTests {
    @Test("allPendingInviteDetails includes draft conversations with invite tag")
    func testIncludesPending() async throws {
        let fixtures = try await makeTestFixtures()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)

            try makeDBConversation(
                id: "draft-123",
                creatorInboxId: "inbox-1",
                inviteTag: "invite-tag-abc"
            ).insert(db)
        }

        let repo = PendingInviteRepository(databaseReader: fixtures.dbReader)
        let details = try repo.allPendingInviteDetails()

        #expect(details.count == 1)
        #expect(details.first?.conversationId == "draft-123")
        #expect(details.first?.inviteTag == "invite-tag-abc")
    }

    @Test("allPendingInviteDetails excludes non-draft conversations even with invite tag")
    func testExcludesNonDraft() async throws {
        let fixtures = try await makeTestFixtures()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)

            try makeDBConversation(
                id: "convo-123",
                creatorInboxId: "inbox-1",
                inviteTag: "invite-tag-abc",
                consent: .allowed
            ).insert(db)
        }

        let repo = PendingInviteRepository(databaseReader: fixtures.dbReader)
        let details = try repo.allPendingInviteDetails()

        #expect(details.isEmpty)
    }

    @Test("allPendingInviteDetails excludes drafts without invite tag")
    func testExcludesUntaggedDrafts() async throws {
        let fixtures = try await makeTestFixtures()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)

            try makeDBConversation(
                id: "draft-123",
                creatorInboxId: "inbox-1",
                inviteTag: ""
            ).insert(db)
        }

        let repo = PendingInviteRepository(databaseReader: fixtures.dbReader)
        let details = try repo.allPendingInviteDetails()

        #expect(details.isEmpty)
    }

    @Test("allPendingInviteDetails returns one row per pending draft")
    func testReturnsAllPendingDrafts() async throws {
        let fixtures = try await makeTestFixtures()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)

            try makeDBConversation(
                id: "draft-1a",
                creatorInboxId: "inbox-1",
                inviteTag: "tag-1a"
            ).insert(db)

            try makeDBConversation(
                id: "draft-1b",
                creatorInboxId: "inbox-1",
                inviteTag: "tag-1b"
            ).insert(db)
        }

        let repo = PendingInviteRepository(databaseReader: fixtures.dbReader)
        let details = try repo.allPendingInviteDetails()

        #expect(details.count == 2)
        let ids = Set(details.map(\.conversationId))
        #expect(ids == ["draft-1a", "draft-1b"])
    }

    // MARK: - Test Helpers

    struct TestFixtures {
        let dbWriter: any DatabaseWriter
        let dbReader: any DatabaseReader
    }

    func makeTestFixtures() async throws -> TestFixtures {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        return TestFixtures(dbWriter: dbManager.dbWriter, dbReader: dbManager.dbReader)
    }

    func makeDBConversation(
        id: String,
        creatorInboxId: String,
        inviteTag: String,
        consent: Consent = .unknown
    ) -> DBConversation {
        DBConversation(
            id: id,
            clientConversationId: id,
            inviteTag: inviteTag,
            creatorId: creatorInboxId,
            kind: .group,
            consent: consent,
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
        )
    }
}
