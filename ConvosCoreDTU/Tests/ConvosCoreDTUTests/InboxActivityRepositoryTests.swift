@testable import ConvosCore
@testable import ConvosCoreDTU
import ConvosMessagingProtocols
import Foundation
import GRDB
import XCTest

/// Phase 2 batch 1: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/InboxActivityRepositoryTests.swift`.
///
/// `InboxActivityRepository` is a pure-DB repository — it never touches
/// a `MessagingClient`. Migrating it onto `DualBackendTestFixtures`
/// proves the repository surface is orthogonal to the messaging
/// backend: both the XMTPiOS (Docker) and DTU (subprocess) lanes
/// execute the same GRDB queries.
///
/// The original version used a file-local `TestFixtures` struct that
/// spun up `MockDatabaseManager` directly and a `Testing`-framework
/// suite. Migrating to XCTest + `DualBackendTestFixtures` gives us
/// the same `databaseManager` but through the shared fixture path
/// the Phase 2 suite standardises on.
///
/// This suite runs `.serialized` in the original because it mutates
/// the shared database; XCTest tests in the same class run serially
/// by default, which preserves that invariant.
final class InboxActivityRepositoryTests: XCTestCase {
    private var fixtures: DualBackendTestFixtures?

    override func tearDown() async throws {
        if let fixtures {
            try? await fixtures.cleanup()
            self.fixtures = nil
        }
        try await super.tearDown()
    }

    override class func tearDown() {
        Task {
            await DualBackendTestFixtures.tearDownSharedDTUIfNeeded()
        }
        super.tearDown()
    }

    /// Boots a dual-backend fixture WITHOUT spinning up a messaging
    /// client — this repository suite only needs the database. That
    /// keeps it fast and decouples the run from Docker / DTU
    /// subprocess availability.
    private func bootDBOnlyFixture() -> DualBackendTestFixtures {
        let fixture = DualBackendTestFixtures(aliasPrefix: "inbox-activity")
        self.fixtures = fixture
        return fixture
    }

    // MARK: - Activity Query Tests

    func testAllInboxActivitiesSortedByActivity() async throws {
        let fixtures = bootDBOnlyFixture()

        let oldDate = Date().addingTimeInterval(-3600)
        let newDate = Date()

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBInbox(inboxId: "inbox-2", clientId: "client-2", createdAt: Date()).insert(db)

            try Self.makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try Self.makeDBConversation(id: "convo-2", inboxId: "inbox-2", clientId: "client-2").insert(db)

            try DBMember(inboxId: "inbox-1").insert(db)
            try DBMember(inboxId: "inbox-2").insert(db)
            try DBConversationMember(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).insert(db)
            try DBConversationMember(
                conversationId: "convo-2",
                inboxId: "inbox-2",
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).insert(db)

            try Self.makeDBMessage(id: "msg-1", conversationId: "convo-1", senderId: "inbox-1", date: oldDate).save(db)
            try Self.makeDBMessage(id: "msg-2", conversationId: "convo-2", senderId: "inbox-2", date: newDate).save(db)
        }

        let repo = InboxActivityRepository(databaseReader: fixtures.databaseManager.dbReader)
        let activities = try repo.allInboxActivities()

        XCTAssertEqual(activities.count, 2)
        XCTAssertEqual(activities[0].clientId, "client-2")
        XCTAssertEqual(activities[1].clientId, "client-1")
    }

    func testInboxActivityForClientId() async throws {
        let fixtures = bootDBOnlyFixture()

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
        }

        let repo = InboxActivityRepository(databaseReader: fixtures.databaseManager.dbReader)
        let activity = try repo.inboxActivity(for: "client-1")

        XCTAssertNotNil(activity)
        XCTAssertEqual(activity?.clientId, "client-1")
        XCTAssertEqual(activity?.inboxId, "inbox-1")
    }

    func testTopActiveInboxesLimit() async throws {
        let fixtures = bootDBOnlyFixture()

        try await fixtures.databaseManager.dbWriter.write { db in
            for i in 1...5 {
                try DBInbox(inboxId: "inbox-\(i)", clientId: "client-\(i)", createdAt: Date()).insert(db)
            }
        }

        let repo = InboxActivityRepository(databaseReader: fixtures.databaseManager.dbReader)
        let topTwo = try repo.topActiveInboxes(limit: 2)

        XCTAssertEqual(topTwo.count, 2)
    }

    func testLeastActiveInboxExcluding() async throws {
        let fixtures = bootDBOnlyFixture()

        let oldDate = Date().addingTimeInterval(-7200) // oldest
        let midDate = Date().addingTimeInterval(-3600)
        let newDate = Date()

        try await fixtures.databaseManager.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBInbox(inboxId: "inbox-2", clientId: "client-2", createdAt: Date()).insert(db)
            try DBInbox(inboxId: "inbox-3", clientId: "client-3", createdAt: Date()).insert(db)

            try Self.makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try Self.makeDBConversation(id: "convo-2", inboxId: "inbox-2", clientId: "client-2").insert(db)
            try Self.makeDBConversation(id: "convo-3", inboxId: "inbox-3", clientId: "client-3").insert(db)

            try DBMember(inboxId: "inbox-1").insert(db)
            try DBMember(inboxId: "inbox-2").insert(db)
            try DBMember(inboxId: "inbox-3").insert(db)
            try DBConversationMember(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).insert(db)
            try DBConversationMember(
                conversationId: "convo-2",
                inboxId: "inbox-2",
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).insert(db)
            try DBConversationMember(
                conversationId: "convo-3",
                inboxId: "inbox-3",
                role: .member,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).insert(db)

            try Self.makeDBMessage(id: "msg-1", conversationId: "convo-1", senderId: "inbox-1", date: oldDate).save(db)
            try Self.makeDBMessage(id: "msg-2", conversationId: "convo-2", senderId: "inbox-2", date: midDate).save(db)
            try Self.makeDBMessage(id: "msg-3", conversationId: "convo-3", senderId: "inbox-3", date: newDate).save(db)
        }

        let repo = InboxActivityRepository(databaseReader: fixtures.databaseManager.dbReader)

        // Exclude client-1, so LRU should be client-2.
        let lru = try repo.leastActiveInbox(excluding: ["client-1"])

        XCTAssertEqual(lru?.clientId, "client-2")
    }

    // MARK: - DB Row Helpers

    static func makeDBConversation(
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
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            imageLastRenewed: nil,
            isUnused: false,
            hasHadVerifiedAssistant: false
        )
    }

    static func makeDBMessage(
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
            sortId: nil,
            status: .published,
            messageType: .original,
            contentType: .text,
            text: "Hi",
            emoji: nil,
            invite: nil,
            linkPreview: nil,
            sourceMessageId: nil,
            attachmentUrls: [],
            update: nil
        )
    }
}
