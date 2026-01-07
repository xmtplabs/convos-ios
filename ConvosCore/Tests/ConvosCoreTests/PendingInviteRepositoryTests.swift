@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("PendingInviteRepository Tests", .serialized)
struct PendingInviteRepositoryTests {

    // MARK: - Pending Invite Detection Tests

    @Test("hasPendingInvites returns true for draft conversations with invite tag")
    func testHasPendingInvitesTrue() async throws {
        let fixtures = try await makeTestFixtures()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)

            // Draft conversation with invite tag (pending invite)
            try makeDBConversation(
                id: "draft-123",
                inboxId: "inbox-1",
                clientId: "client-1",
                inviteTag: "invite-tag-abc"
            ).insert(db)
        }

        let repo = PendingInviteRepository(databaseReader: fixtures.dbReader)
        let hasPending = try repo.hasPendingInvites(clientId: "client-1")

        #expect(hasPending == true)
    }

    @Test("hasPendingInvites returns false for non-draft conversations")
    func testHasPendingInvitesFalseForNonDraft() async throws {
        let fixtures = try await makeTestFixtures()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)

            // Regular conversation (not draft) with invite tag
            try makeDBConversation(
                id: "convo-123", // Not a draft
                inboxId: "inbox-1",
                clientId: "client-1",
                inviteTag: "invite-tag-abc",
                consent: .allowed
            ).insert(db)
        }

        let repo = PendingInviteRepository(databaseReader: fixtures.dbReader)
        let hasPending = try repo.hasPendingInvites(clientId: "client-1")

        #expect(hasPending == false)
    }

    @Test("hasPendingInvites returns false for draft without invite tag")
    func testHasPendingInvitesFalseWithoutInviteTag() async throws {
        let fixtures = try await makeTestFixtures()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)

            // Draft conversation WITHOUT invite tag (not a pending invite)
            try makeDBConversation(
                id: "draft-123",
                inboxId: "inbox-1",
                clientId: "client-1",
                inviteTag: "" // Empty invite tag
            ).insert(db)
        }

        let repo = PendingInviteRepository(databaseReader: fixtures.dbReader)
        let hasPending = try repo.hasPendingInvites(clientId: "client-1")

        #expect(hasPending == false)
    }

    @Test("clientIdsWithPendingInvites returns set of client IDs")
    func testClientIdsWithPendingInvites() async throws {
        let fixtures = try await makeTestFixtures()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBInbox(inboxId: "inbox-2", clientId: "client-2", createdAt: Date()).insert(db)
            try DBInbox(inboxId: "inbox-3", clientId: "client-3", createdAt: Date()).insert(db)

            // client-1 has pending invite
            try makeDBConversation(
                id: "draft-1",
                inboxId: "inbox-1",
                clientId: "client-1",
                inviteTag: "tag-1"
            ).insert(db)

            // client-2 has NO pending invite (regular conversation)
            try makeDBConversation(
                id: "convo-2",
                inboxId: "inbox-2",
                clientId: "client-2",
                inviteTag: "",
                consent: .allowed
            ).insert(db)

            // client-3 has pending invite
            try makeDBConversation(
                id: "draft-3",
                inboxId: "inbox-3",
                clientId: "client-3",
                inviteTag: "tag-3"
            ).insert(db)
        }

        let repo = PendingInviteRepository(databaseReader: fixtures.dbReader)
        let clientIds = try repo.clientIdsWithPendingInvites()

        #expect(clientIds.count == 2)
        #expect(clientIds.contains("client-1"))
        #expect(clientIds.contains("client-3"))
        #expect(!clientIds.contains("client-2"))
    }

    @Test("allPendingInvites returns info for all inboxes")
    func testAllPendingInvites() async throws {
        let fixtures = try await makeTestFixtures()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBInbox(inboxId: "inbox-2", clientId: "client-2", createdAt: Date()).insert(db)

            try makeDBConversation(
                id: "draft-1a",
                inboxId: "inbox-1",
                clientId: "client-1",
                inviteTag: "tag-1a"
            ).insert(db)

            try makeDBConversation(
                id: "draft-1b",
                inboxId: "inbox-1",
                clientId: "client-1",
                inviteTag: "tag-1b"
            ).insert(db)
        }

        let repo = PendingInviteRepository(databaseReader: fixtures.dbReader)
        let infos = try repo.allPendingInvites()

        let client1Info = infos.first { $0.clientId == "client-1" }
        let client2Info = infos.first { $0.clientId == "client-2" }

        #expect(client1Info != nil)
        #expect(client1Info?.hasPendingInvites == true)
        #expect(client1Info?.pendingConversationIds.count == 2)

        #expect(client2Info != nil)
        #expect(client2Info?.hasPendingInvites == false)
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
        inboxId: String,
        clientId: String,
        inviteTag: String,
        consent: Consent = .unknown
    ) -> DBConversation {
        DBConversation(
            id: id,
            inboxId: inboxId,
            clientId: clientId,
            clientConversationId: id,
            inviteTag: inviteTag,
            creatorId: inboxId,
            kind: .group,
            consent: consent,
            createdAt: Date(),
            name: nil,
            description: nil,
            imageURLString: nil,
            expiresAt: nil,
            debugInfo: .empty
        )
    }
}
