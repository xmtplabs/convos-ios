@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("PendingInviteRepository Tests", .serialized)
struct PendingInviteRepositoryTests {
    @Test("allPendingInvites includes draft conversations with invite tag")
    func testAllPendingInvitesIncludesPending() async throws {
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
        let infos = try repo.allPendingInvites()

        #expect(infos.count == 1)
        #expect(infos.first?.hasPendingInvites == true)
        #expect(infos.first?.pendingConversationIds == ["draft-123"])
    }

    @Test("allPendingInvites excludes non-draft conversations even with invite tag")
    func testAllPendingInvitesExcludesNonDraft() async throws {
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
        let infos = try repo.allPendingInvites()

        #expect(infos.count == 1)
        #expect(infos.first?.hasPendingInvites == false)
        #expect(infos.first?.pendingConversationIds.isEmpty == true)
    }

    @Test("allPendingInvites excludes drafts without invite tag")
    func testAllPendingInvitesExcludesUntaggedDrafts() async throws {
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
        let infos = try repo.allPendingInvites()

        #expect(infos.count == 1)
        #expect(infos.first?.hasPendingInvites == false)
    }

    @Test("allPendingInvites returns the inbox row with all pending drafts")
    func testAllPendingInvitesReturnsInbox() async throws {
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
        let infos = try repo.allPendingInvites()

        #expect(infos.count == 1)
        let info = infos.first
        #expect(info?.clientId == "client-1")
        #expect(info?.hasPendingInvites == true)
        #expect(info?.pendingConversationIds.count == 2)
    }

    @Test("allPendingInviteDetails returns a row per pending draft conversation")
    func testAllPendingInviteDetails() async throws {
        let fixtures = try await makeTestFixtures()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)

            try makeDBConversation(
                id: "draft-123",
                creatorInboxId: "inbox-1",
                inviteTag: "invite-tag-abc"
            ).insert(db)

            try makeDBConversation(
                id: "convo-456",
                creatorInboxId: "inbox-1",
                inviteTag: "",
                consent: .allowed
            ).insert(db)
        }

        let repo = PendingInviteRepository(databaseReader: fixtures.dbReader)
        let details = try repo.allPendingInviteDetails()

        #expect(details.count == 1)
        #expect(details.first?.conversationId == "draft-123")
        #expect(details.first?.inviteTag == "invite-tag-abc")
        // The other (non-draft) conversation surfaces as an "other conversation"
        // for the same inbox — useful in the debug surface.
        #expect(details.first?.otherConversations.first?.conversationId == "convo-456")
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
