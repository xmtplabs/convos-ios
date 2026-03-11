@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("ExpiredConversationsWorker Tests", .serialized)
struct ExpiredConversationsWorkerTests {

    @Test("Cleans up already-expired conversations on init")
    func testCleansUpExpiredOnInit() async throws {
        let fixtures = ExpiredWorkerTestFixtures()
        let expiresAt = Date().addingTimeInterval(-60)
        try await fixtures.setupConversation(expiresAt: expiresAt)

        let conversationId = fixtures.conversationId
        let capture = NotificationCapture()
        capture.startCapturing(.leftConversationNotification)
        defer { capture.stopCapturing() }

        let worker = fixtures.createWorker()
        withExtendedLifetime(worker) {
            // Worker retained for test duration
        }

        try await waitForCondition(timeout: 2.0) {
            capture.hasNotification(.leftConversationNotification)
        }

        let matched = capture.notifications(named: .leftConversationNotification).contains {
            ($0.userInfo?["conversationId"] as? String) == conversationId
        }
        #expect(matched, "Should clean up expired conversation on init")
    }

    @Test("Schedules timer for next expiring conversation and fires cleanup")
    func testSchedulesTimerForNextExpiration() async throws {
        let fixtures = ExpiredWorkerTestFixtures()
        let expiresAt = Date().addingTimeInterval(1.0)
        try await fixtures.setupConversation(expiresAt: expiresAt)

        let conversationId = fixtures.conversationId
        let capture = NotificationCapture()
        capture.startCapturing(.leftConversationNotification)
        defer { capture.stopCapturing() }

        let worker = fixtures.createWorker()

        try await waitForCondition(timeout: 3.0) {
            capture.notifications(named: .leftConversationNotification).contains {
                ($0.userInfo?["conversationId"] as? String) == conversationId
            }
        }

        withExtendedLifetime(worker) {}

        let matched = capture.notifications(named: .leftConversationNotification).contains {
            ($0.userInfo?["conversationId"] as? String) == conversationId
        }
        #expect(matched, "Should clean up conversation when timer fires")
    }

    @Test("Reschedules timer when new explosion is scheduled")
    func testReschedulesOnNewExplosion() async throws {
        let fixtures = ExpiredWorkerTestFixtures()
        let expiresAt = Date().addingTimeInterval(1.0)
        try await fixtures.setupConversation(expiresAt: expiresAt)

        let conversationId = fixtures.conversationId
        let capture = NotificationCapture()
        capture.startCapturing(.leftConversationNotification)
        defer { capture.stopCapturing() }

        let worker = fixtures.createWorker()

        await MainActor.run {
            NotificationCenter.default.post(
                name: .conversationScheduledExplosion,
                object: nil,
                userInfo: [
                    "conversationId": conversationId,
                    "expiresAt": expiresAt
                ]
            )
        }

        try await waitForCondition(timeout: 3.0) {
            capture.notifications(named: .leftConversationNotification).contains {
                ($0.userInfo?["conversationId"] as? String) == conversationId
            }
        }

        withExtendedLifetime(worker) {}

        let matched = capture.notifications(named: .leftConversationNotification).contains {
            ($0.userInfo?["conversationId"] as? String) == conversationId
        }
        #expect(matched, "Should clean up after rescheduled timer fires")
    }

    @Test("Processes expired conversations on app becoming active")
    func testProcessesOnAppActive() async throws {
        let fixtures = ExpiredWorkerTestFixtures()

        let capture = NotificationCapture()
        capture.startCapturing(.leftConversationNotification)
        defer { capture.stopCapturing() }

        let worker = fixtures.createWorker()

        try await Task.sleep(for: .milliseconds(100))

        try await fixtures.setupConversation(expiresAt: Date().addingTimeInterval(-5))

        let activeNotification = fixtures.appLifecycle.didBecomeActiveNotification
        await MainActor.run {
            NotificationCenter.default.post(name: activeNotification, object: nil)
        }

        let conversationId = fixtures.conversationId
        try await waitForCondition(timeout: 2.0) {
            capture.notifications(named: .leftConversationNotification).contains {
                ($0.userInfo?["conversationId"] as? String) == conversationId
            }
        }

        withExtendedLifetime(worker) {}

        let matched = capture.notifications(named: .leftConversationNotification).contains {
            ($0.userInfo?["conversationId"] as? String) == conversationId
        }
        #expect(matched, "Should process expired conversations on app active")
    }

    @Test("Handles conversationExpired notification for specific conversation")
    func testHandlesConversationExpiredNotification() async throws {
        let fixtures = ExpiredWorkerTestFixtures()
        try await fixtures.setupConversation(expiresAt: Date().addingTimeInterval(-1))

        let conversationId = fixtures.conversationId
        let capture = NotificationCapture()
        capture.startCapturing(.leftConversationNotification)
        defer { capture.stopCapturing() }

        let worker = fixtures.createWorker()

        try await Task.sleep(for: .milliseconds(100))

        await MainActor.run {
            NotificationCenter.default.post(
                name: .conversationExpired,
                object: nil,
                userInfo: ["conversationId": conversationId]
            )
        }

        try await waitForCondition(timeout: 2.0) {
            capture.hasNotification(.leftConversationNotification)
        }

        withExtendedLifetime(worker) {}

        let matched = capture.notifications(named: .leftConversationNotification).contains {
            ($0.userInfo?["conversationId"] as? String) == conversationId
        }
        #expect(matched, "Should clean up conversation when conversationExpired notification received")
    }
}

private class ExpiredWorkerTestFixtures {
    let databaseManager: MockDatabaseManager
    let appLifecycle: MockAppLifecycleProvider
    let sessionManager: MockInboxesService
    let conversationId: String = "expired-worker-test-\(UUID().uuidString)"
    let inboxId: String = "test-inbox-id"
    let clientId: String = "test-client-id"

    init() {
        self.databaseManager = MockDatabaseManager.makeTestDatabase()
        self.appLifecycle = MockAppLifecycleProvider()
        self.sessionManager = MockInboxesService()
        ConvosLog.configure(environment: .tests)
    }

    func createWorker() -> ExpiredConversationsWorker {
        ExpiredConversationsWorker(
            databaseReader: databaseManager.dbReader,
            sessionManager: sessionManager,
            appLifecycle: appLifecycle
        )
    }

    func setupConversation(id: String? = nil, expiresAt: Date?) async throws {
        let convId = id ?? conversationId
        let inbxId = inboxId
        let clId = clientId
        try await databaseManager.dbWriter.write { db in
            let conversation = DBConversation(
                id: convId,
                inboxId: inbxId,
                clientId: clId,
                clientConversationId: convId,
                inviteTag: "test-invite-tag",
                creatorId: inbxId,
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
                imageLastRenewed: nil,
                isUnused: false,
            )
            try conversation.upsert(db)
        }
    }
}

private func waitForCondition(timeout: TimeInterval, condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}
