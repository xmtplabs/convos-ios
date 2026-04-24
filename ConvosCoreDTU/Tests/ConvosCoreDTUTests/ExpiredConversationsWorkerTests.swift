@testable import ConvosCore
@testable import ConvosCoreDTU
import Foundation
import GRDB
import XCTest

/// Stage 6f: migrated from
/// `ConvosCore/Tests/ConvosCoreTests/ExpiredConversationsWorkerTests.swift`.
///
/// Exercises `ExpiredConversationsWorker`'s timer + notification
/// driven cleanup of expired group conversations. The worker itself
/// is XMTP-agnostic — it only reads `DBConversation`, schedules
/// timers, and emits notifications. Migrating onto
/// `DualBackendTestFixtures` reuses the shared database manager and
/// XCTest tearDown conventions; both backends execute the same
/// `ExpiredConversationsWorker` code paths so we don't need a
/// backend guard.
///
/// Also restores buildability by including the `conversationEmoji` /
/// `hasHadVerifiedAssistant` params to the `DBConversation` init —
/// the legacy ConvosCoreTests build has been broken on these for
/// some time (see batch 3+5 reports).
final class ExpiredConversationsWorkerTests: XCTestCase {
    private var fixtures: ExpiredWorkerTestFixtures?

    override func tearDown() async throws {
        fixtures = nil
        try await super.tearDown()
    }

    // MARK: - Tests

    func testCleansUpExpiredOnInit() async throws {
        let fixtures = ExpiredWorkerTestFixtures()
        self.fixtures = fixtures
        let expiresAt = Date().addingTimeInterval(-60)
        try await fixtures.setupConversation(expiresAt: expiresAt)

        let conversationId = fixtures.conversationId
        let capture = NotificationCapture()
        capture.startCapturing(.leftConversationNotification)
        defer { capture.stopCapturing() }

        let worker = fixtures.createWorker()
        withExtendedLifetime(worker) {}

        try await waitForCondition(timeout: 2.0) {
            capture.hasNotification(.leftConversationNotification)
        }

        let matched = capture.notifications(named: .leftConversationNotification).contains {
            ($0.userInfo?["conversationId"] as? String) == conversationId
        }
        XCTAssertTrue(matched, "Should clean up expired conversation on init")
    }

    func testSchedulesTimerForNextExpiration() async throws {
        let fixtures = ExpiredWorkerTestFixtures()
        self.fixtures = fixtures
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
        XCTAssertTrue(matched, "Should clean up conversation when timer fires")
    }

    func testReschedulesOnNewExplosion() async throws {
        let fixtures = ExpiredWorkerTestFixtures()
        self.fixtures = fixtures
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
        XCTAssertTrue(matched, "Should clean up after rescheduled timer fires")
    }

    func testProcessesOnAppActive() async throws {
        let fixtures = ExpiredWorkerTestFixtures()
        self.fixtures = fixtures

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
        XCTAssertTrue(matched, "Should process expired conversations on app active")
    }

    func testHandlesConversationExpiredNotification() async throws {
        let fixtures = ExpiredWorkerTestFixtures()
        self.fixtures = fixtures
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
        XCTAssertTrue(matched, "Should clean up conversation when conversationExpired notification received")
    }
}

// MARK: - Test fixtures

private final class ExpiredWorkerTestFixtures {
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
                conversationEmoji: nil,
                imageLastRenewed: nil,
                isUnused: false,
                hasHadVerifiedAssistant: false
            )
            try conversation.upsert(db)
        }
    }
}

// MARK: - Helpers

private func waitForCondition(timeout: TimeInterval, condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(50))
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
}
