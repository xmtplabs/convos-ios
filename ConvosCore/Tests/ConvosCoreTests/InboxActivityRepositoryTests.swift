@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("InboxActivityRepository Tests", .serialized)
struct InboxActivityRepositoryTests {
    // MARK: - Activity Query Tests

    @Test("allInboxActivities returns activities sorted by lastActivity descending")
    func testAllInboxActivitiesSortedByActivity() async throws {
        let fixtures = try await makeTestFixtures()

        // Insert inboxes with different activity times
        let oldDate = Date().addingTimeInterval(-3600)
        let newDate = Date()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBInbox(inboxId: "inbox-2", clientId: "client-2", createdAt: Date()).insert(db)

            // Add conversations
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try makeDBConversation(id: "convo-2", inboxId: "inbox-2", clientId: "client-2").insert(db)

            // Add members (required for message foreign keys)
            try DBMember(inboxId: "inbox-1").insert(db)
            try DBMember(inboxId: "inbox-2").insert(db)
            try DBConversationMember(conversationId: "convo-1", inboxId: "inbox-1", role: .member, consent: .allowed, createdAt: Date()).insert(db)
            try DBConversationMember(conversationId: "convo-2", inboxId: "inbox-2", role: .member, consent: .allowed, createdAt: Date()).insert(db)

            // Add messages with different dates
            try makeDBMessage(id: "msg-1", conversationId: "convo-1", senderId: "inbox-1", date: oldDate).save(db)
            try makeDBMessage(id: "msg-2", conversationId: "convo-2", senderId: "inbox-2", date: newDate).save(db)
        }

        let repo = InboxActivityRepository(databaseReader: fixtures.dbReader)
        let activities = try repo.allInboxActivities()

        #expect(activities.count == 2)
        // Most recent should be first
        #expect(activities[0].clientId == "client-2")
        #expect(activities[1].clientId == "client-1")
    }

    @Test("inboxActivity returns specific inbox activity")
    func testInboxActivityForClientId() async throws {
        let fixtures = try await makeTestFixtures()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
        }

        let repo = InboxActivityRepository(databaseReader: fixtures.dbReader)
        let activity = try repo.inboxActivity(for: "client-1")

        #expect(activity != nil)
        #expect(activity?.clientId == "client-1")
        #expect(activity?.inboxId == "inbox-1")
    }

    @Test("topActiveInboxes returns limited results")
    func testTopActiveInboxesLimit() async throws {
        let fixtures = try await makeTestFixtures()

        try await fixtures.dbWriter.write { db in
            for i in 1...5 {
                try DBInbox(inboxId: "inbox-\(i)", clientId: "client-\(i)", createdAt: Date()).insert(db)
            }
        }

        let repo = InboxActivityRepository(databaseReader: fixtures.dbReader)
        let topTwo = try repo.topActiveInboxes(limit: 2)

        #expect(topTwo.count == 2)
    }

    @Test("leastActiveInbox returns LRU excluding specified IDs")
    func testLeastActiveInboxExcluding() async throws {
        let fixtures = try await makeTestFixtures()

        let oldDate = Date().addingTimeInterval(-7200) // oldest
        let midDate = Date().addingTimeInterval(-3600)
        let newDate = Date()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBInbox(inboxId: "inbox-2", clientId: "client-2", createdAt: Date()).insert(db)
            try DBInbox(inboxId: "inbox-3", clientId: "client-3", createdAt: Date()).insert(db)

            // Conversations
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try makeDBConversation(id: "convo-2", inboxId: "inbox-2", clientId: "client-2").insert(db)
            try makeDBConversation(id: "convo-3", inboxId: "inbox-3", clientId: "client-3").insert(db)

            // Members
            try DBMember(inboxId: "inbox-1").insert(db)
            try DBMember(inboxId: "inbox-2").insert(db)
            try DBMember(inboxId: "inbox-3").insert(db)
            try DBConversationMember(conversationId: "convo-1", inboxId: "inbox-1", role: .member, consent: .allowed, createdAt: Date()).insert(db)
            try DBConversationMember(conversationId: "convo-2", inboxId: "inbox-2", role: .member, consent: .allowed, createdAt: Date()).insert(db)
            try DBConversationMember(conversationId: "convo-3", inboxId: "inbox-3", role: .member, consent: .allowed, createdAt: Date()).insert(db)

            // Messages (client-1 is oldest)
            try makeDBMessage(id: "msg-1", conversationId: "convo-1", senderId: "inbox-1", date: oldDate).save(db)
            try makeDBMessage(id: "msg-2", conversationId: "convo-2", senderId: "inbox-2", date: midDate).save(db)
            try makeDBMessage(id: "msg-3", conversationId: "convo-3", senderId: "inbox-3", date: newDate).save(db)
        }

        let repo = InboxActivityRepository(databaseReader: fixtures.dbReader)

        // Exclude client-1, so LRU should be client-2
        let lru = try repo.leastActiveInbox(excluding: ["client-1"])

        #expect(lru?.clientId == "client-2")
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
        clientId: String
    ) -> DBConversation {
        DBConversation(
            id: id,
            inboxId: inboxId,
            clientId: clientId,
            clientConversationId: id,
            inviteTag: "invite-tag-\(id)",
            creatorId: inboxId,
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
            isLocked: false
        )
    }

    func makeDBMessage(
        id: String,
        conversationId: String,
        senderId: String,
        date: Date
    ) -> DBMessage {
        DBMessage(
            id: id,
            clientMessageId: "client-\(id)",
            conversationId: conversationId,
            senderId: senderId,
            dateNs: Int64(date.timeIntervalSince1970 * 1_000_000_000),
            date: date,
            status: .published,
            messageType: .original,
            contentType: .text,
            text: "Hi",
            emoji: nil,
            invite: nil,
            sourceMessageId: nil,
            attachmentUrls: [],
            update: nil
        )
    }
}
