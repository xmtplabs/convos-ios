@testable import ConvosCore
import ConvosMessagingProtocols
import Foundation
import GRDB
import Testing

/// Phase 2 batch 3: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/IncomingMessageWriterExplodeTests.swift`.
///
/// Exercises `IncomingMessageWriter.processExplodeSettings(_:)` over a
/// `MockDatabaseManager`. No `MessagingClient` / backend is ever
/// instantiated — this is a pure DB-level unit test on the writer's
/// role-gating logic. No `DualBackendTestFixtures` needed; the test is
/// backend-agnostic and passes identically under DTU and xmtpiOS.
///
/// `NotificationCapture` is inlined at the bottom of this file because
/// the batch-3 brief calls out that it "may need inlining or a small
/// promotion." The original helper lives in
/// `ConvosCore/Tests/ConvosCoreTests/TestHelpers.swift`, which isn't
/// visible to this target.

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
        try await fixtures.setupConversation(expiresAt: Date().addingTimeInterval(3600))

        let settings = ExplodeSettings(expiresAt: Date().addingTimeInterval(7200))
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
        let matching = capture.notifications(named: .conversationExpired).filter {
            $0.userInfo?["conversationId"] as? String == fixtures.conversationId
        }
        #expect(matching.count == 1)
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
    let conversationId: String = "explode-test-\(UUID().uuidString)"
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
                conversationEmoji: nil,
                imageLastRenewed: nil,
                isUnused: false,
                hasHadVerifiedAssistant: false
            )
            try conversation.insert(db)

            let creatorMember = DBConversationMember(
                conversationId: convId,
                inboxId: crId,
                role: .superAdmin,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
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
                createdAt: Date(),
                invitedByInboxId: nil
            )
            try member.insert(db)
        }
    }
}

// MARK: - NotificationCapture (inlined from ConvosCoreTests/TestHelpers.swift)

private final class NotificationCapture: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var _postedNotifications: [(name: Notification.Name, userInfo: [AnyHashable: Any]?)] = []
    private var observers: [NSObjectProtocol] = []

    var postedNotifications: [(name: Notification.Name, userInfo: [AnyHashable: Any]?)] {
        lock.lock()
        defer { lock.unlock() }
        return _postedNotifications
    }

    func startCapturing(_ name: Notification.Name) {
        let observer = NotificationCenter.default.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            self.lock.lock()
            self._postedNotifications.append((notification.name, notification.userInfo))
            self.lock.unlock()
        }
        observers.append(observer)
    }

    func stopCapturing() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    func hasNotification(_ name: Notification.Name) -> Bool {
        postedNotifications.contains { $0.name == name }
    }

    func notifications(named name: Notification.Name) -> [(name: Notification.Name, userInfo: [AnyHashable: Any]?)] {
        postedNotifications.filter { $0.name == name }
    }

    func reset() {
        lock.lock()
        _postedNotifications.removeAll()
        lock.unlock()
    }
}
