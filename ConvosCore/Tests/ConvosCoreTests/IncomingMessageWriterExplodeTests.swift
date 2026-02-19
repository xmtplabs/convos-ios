@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("IncomingMessageWriter ExplodeSettings Tests", .serialized)
struct IncomingMessageWriterExplodeTests {

    @Test("Returns fromSelf when sender is current user")
    func testFromSelfReturnsFromSelf() async throws {
        let fixtures = ExplodeTestFixtures()
        try await fixtures.setupConversation()

        let settings = ExplodeSettings(expiresAt: Date().addingTimeInterval(3600))
        let result = await fixtures.writer.processExplodeSettings(
            settings,
            conversationId: fixtures.conversationId,
            senderInboxId: fixtures.currentInboxId,
            currentInboxId: fixtures.currentInboxId
        )

        guard case .fromSelf = result else {
            Issue.record("Expected .fromSelf, got \(result)")
            return
        }
    }

    @Test("Creator can schedule explosion")
    func testFromCreatorSchedulesExplosion() async throws {
        let fixtures = ExplodeTestFixtures()
        try await fixtures.setupConversation()

        let expiresAt = Date().addingTimeInterval(3600)
        let settings = ExplodeSettings(expiresAt: expiresAt)
        let result = await fixtures.writer.processExplodeSettings(
            settings,
            conversationId: fixtures.conversationId,
            senderInboxId: fixtures.creatorInboxId,
            currentInboxId: fixtures.currentInboxId
        )

        guard case .scheduled(let resultDate) = result else {
            Issue.record("Expected .scheduled, got \(result)")
            return
        }
        #expect(resultDate == expiresAt)
    }

    @Test("Admin can schedule explosion")
    func testFromAdminSchedulesExplosion() async throws {
        let fixtures = ExplodeTestFixtures()
        try await fixtures.setupConversation()

        let adminInboxId = "admin-inbox"
        try await fixtures.addMember(inboxId: adminInboxId, role: .admin)

        let expiresAt = Date().addingTimeInterval(3600)
        let settings = ExplodeSettings(expiresAt: expiresAt)
        let result = await fixtures.writer.processExplodeSettings(
            settings,
            conversationId: fixtures.conversationId,
            senderInboxId: adminInboxId,
            currentInboxId: fixtures.currentInboxId
        )

        guard case .scheduled(let resultDate) = result else {
            Issue.record("Expected .scheduled, got \(result)")
            return
        }
        #expect(resultDate == expiresAt)
    }

    @Test("SuperAdmin can schedule explosion")
    func testFromSuperAdminSchedulesExplosion() async throws {
        let fixtures = ExplodeTestFixtures()
        try await fixtures.setupConversation()

        let superAdminInboxId = "superadmin-inbox"
        try await fixtures.addMember(inboxId: superAdminInboxId, role: .superAdmin)

        let expiresAt = Date().addingTimeInterval(3600)
        let settings = ExplodeSettings(expiresAt: expiresAt)
        let result = await fixtures.writer.processExplodeSettings(
            settings,
            conversationId: fixtures.conversationId,
            senderInboxId: superAdminInboxId,
            currentInboxId: fixtures.currentInboxId
        )

        guard case .scheduled(let resultDate) = result else {
            Issue.record("Expected .scheduled, got \(result)")
            return
        }
        #expect(resultDate == expiresAt)
    }

    @Test("Regular member returns unauthorized")
    func testFromMemberReturnsUnauthorized() async throws {
        let fixtures = ExplodeTestFixtures()
        try await fixtures.setupConversation()

        let memberInboxId = "member-inbox"
        try await fixtures.addMember(inboxId: memberInboxId, role: .member)

        let settings = ExplodeSettings(expiresAt: Date().addingTimeInterval(3600))
        let result = await fixtures.writer.processExplodeSettings(
            settings,
            conversationId: fixtures.conversationId,
            senderInboxId: memberInboxId,
            currentInboxId: fixtures.currentInboxId
        )

        guard case .unauthorized = result else {
            Issue.record("Expected .unauthorized, got \(result)")
            return
        }
    }

    @Test("Non-member returns unauthorized")
    func testNonMemberReturnsUnauthorized() async throws {
        let fixtures = ExplodeTestFixtures()
        try await fixtures.setupConversation()

        let nonMemberInboxId = "non-member-inbox"

        let settings = ExplodeSettings(expiresAt: Date().addingTimeInterval(3600))
        let result = await fixtures.writer.processExplodeSettings(
            settings,
            conversationId: fixtures.conversationId,
            senderInboxId: nonMemberInboxId,
            currentInboxId: fixtures.currentInboxId
        )

        guard case .unauthorized = result else {
            Issue.record("Expected .unauthorized, got \(result)")
            return
        }
    }

    @Test("Conversation not found returns alreadyExpired")
    func testConversationNotFoundReturnsAlreadyExpired() async throws {
        let fixtures = ExplodeTestFixtures()

        let settings = ExplodeSettings(expiresAt: Date().addingTimeInterval(3600))
        let result = await fixtures.writer.processExplodeSettings(
            settings,
            conversationId: "non-existent-conversation",
            senderInboxId: "some-sender",
            currentInboxId: fixtures.currentInboxId
        )

        guard case .alreadyExpired = result else {
            Issue.record("Expected .alreadyExpired, got \(result)")
            return
        }
    }

    @Test("Already has expiresAt returns alreadyExpired (idempotency)")
    func testAlreadyHasExpiresAtReturnsAlreadyExpired() async throws {
        let fixtures = ExplodeTestFixtures()
        try await fixtures.setupConversation(expiresAt: Date().addingTimeInterval(7200))

        let settings = ExplodeSettings(expiresAt: Date().addingTimeInterval(3600))
        let result = await fixtures.writer.processExplodeSettings(
            settings,
            conversationId: fixtures.conversationId,
            senderInboxId: fixtures.creatorInboxId,
            currentInboxId: fixtures.currentInboxId
        )

        guard case .alreadyExpired = result else {
            Issue.record("Expected .alreadyExpired, got \(result)")
            return
        }
    }

    @Test("Future date posts conversationScheduledExplosion notification")
    func testFutureDatePostsScheduledNotification() async throws {
        let fixtures = ExplodeTestFixtures()
        try await fixtures.setupConversation()

        let capture = NotificationCapture()
        capture.startCapturing(.conversationScheduledExplosion)
        defer { capture.stopCapturing() }

        let expiresAt = Date().addingTimeInterval(3600)
        let settings = ExplodeSettings(expiresAt: expiresAt)
        _ = await fixtures.writer.processExplodeSettings(
            settings,
            conversationId: fixtures.conversationId,
            senderInboxId: fixtures.creatorInboxId,
            currentInboxId: fixtures.currentInboxId
        )

        try await Task.sleep(for: .milliseconds(100))

        #expect(capture.hasNotification(.conversationScheduledExplosion))
        let notifications = capture.notifications(named: .conversationScheduledExplosion)
        #expect(notifications.count >= 1, "Should post at least one notification")
        let matchingNotification = notifications.first {
            $0.userInfo?["conversationId"] as? String == fixtures.conversationId &&
            $0.userInfo?["expiresAt"] as? Date == expiresAt
        }
        #expect(matchingNotification != nil, "Should have notification with correct data")
    }

    @Test("Past date posts conversationExpired notification")
    func testPastDatePostsExpiredNotification() async throws {
        let fixtures = ExplodeTestFixtures()
        try await fixtures.setupConversation()

        let capture = NotificationCapture()
        capture.startCapturing(.conversationExpired)
        defer { capture.stopCapturing() }

        let expiresAt = Date().addingTimeInterval(-60)
        let settings = ExplodeSettings(expiresAt: expiresAt)
        let result = await fixtures.writer.processExplodeSettings(
            settings,
            conversationId: fixtures.conversationId,
            senderInboxId: fixtures.creatorInboxId,
            currentInboxId: fixtures.currentInboxId
        )

        guard case .applied = result else {
            Issue.record("Expected .applied, got \(result)")
            return
        }

        try await Task.sleep(for: .milliseconds(100))

        #expect(capture.hasNotification(.conversationExpired))
        let notifications = capture.notifications(named: .conversationExpired)
        #expect(notifications.count == 1)
        let userInfo = notifications.first?.userInfo
        #expect(userInfo?["conversationId"] as? String == fixtures.conversationId)
    }

    @Test("Writes expiresAt to database")
    func testWritesExpiresAtToDatabase() async throws {
        let fixtures = ExplodeTestFixtures()
        try await fixtures.setupConversation()

        let expiresAt = Date().addingTimeInterval(3600)
        let settings = ExplodeSettings(expiresAt: expiresAt)
        _ = await fixtures.writer.processExplodeSettings(
            settings,
            conversationId: fixtures.conversationId,
            senderInboxId: fixtures.creatorInboxId,
            currentInboxId: fixtures.currentInboxId
        )

        let convId = fixtures.conversationId
        let conversation = try await fixtures.databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: convId)
        }

        #expect(conversation?.expiresAt != nil)
        if let savedExpiresAt = conversation?.expiresAt {
            let tolerance = abs(savedExpiresAt.timeIntervalSince(expiresAt))
            #expect(tolerance < 1, "Dates should be within 1 second of each other")
        }
    }
}

private class ExplodeTestFixtures {
    let databaseManager: MockDatabaseManager
    let writer: IncomingMessageWriter
    let conversationId: String = "test-conversation-id"
    let creatorInboxId: String = "creator-inbox-id"
    let currentInboxId: String = "current-inbox-id"
    let clientId: String = "test-client-id"

    init() {
        self.databaseManager = MockDatabaseManager.makeTestDatabase()
        self.writer = IncomingMessageWriter(databaseWriter: databaseManager.dbWriter)
        ConvosLog.configure(environment: .tests)
    }

    func setupConversation(expiresAt: Date? = nil) async throws {
        let convId = conversationId
        let currInboxId = currentInboxId
        let clId = clientId
        let crId = creatorInboxId
        try await databaseManager.dbWriter.write { db in
            try DBMember(inboxId: crId).save(db)

            let conversation = DBConversation(
                id: convId,
                inboxId: currInboxId,
                clientId: clId,
                clientConversationId: convId,
                inviteTag: "test-invite-tag",
                creatorId: crId,
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: "Test Conversation",
                description: nil,
                imageURLString: nil,
                publicImageURLString: nil,
                includeInfoInPublicPreview: false,
                expiresAt: expiresAt,
                debugInfo: .empty,
                isLocked: false,
                imageSalt: nil,
                imageNonce: nil,
                imageEncryptionKey: nil,
                isUnused: false
            )
            try conversation.insert(db)

            let creatorMember = DBConversationMember(
                conversationId: convId,
                inboxId: crId,
                role: .superAdmin,
                consent: .allowed,
                createdAt: Date()
            )
            try creatorMember.insert(db)
        }
    }

    func addMember(inboxId: String, role: MemberRole) async throws {
        let convId = conversationId
        try await databaseManager.dbWriter.write { db in
            try DBMember(inboxId: inboxId).save(db)
            let member = DBConversationMember(
                conversationId: convId,
                inboxId: inboxId,
                role: role,
                consent: .allowed,
                createdAt: Date()
            )
            try member.insert(db)
        }
    }
}
