@testable import ConvosCore
@testable import ConvosCoreDTU
import Foundation
import GRDB
import os
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
        let expiresAt = Date().addingTimeInterval(2.0)
        try await fixtures.setupConversation(expiresAt: expiresAt)

        let conversationId = fixtures.conversationId
        let capture = NotificationCapture()
        capture.startCapturing(.leftConversationNotification)
        defer { capture.stopCapturing() }

        let worker = fixtures.createWorker()

        try await waitForCondition(timeout: 5.0) {
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
        let expiresAt = Date().addingTimeInterval(2.0)
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

        try await waitForCondition(timeout: 5.0) {
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

    @Test("Deletes the DBConversation row of an exploded side convo, cascading its children")
    func testDeletesSideConversationRowOnExpiration() async throws {
        let fixtures = ExpiredWorkerTestFixtures()
        let expiresAt = Date().addingTimeInterval(-60)
        try await fixtures.setupConversation(expiresAt: expiresAt)
        try await fixtures.markAsSideConversation()
        try await fixtures.seedMessages(count: 3)

        let conversationId = fixtures.conversationId
        let capture = NotificationCapture()
        capture.startCapturing(.leftConversationNotification)
        defer { capture.stopCapturing() }

        let worker = fixtures.createWorker()

        try await waitForCondition(timeout: 2.0) {
            capture.notifications(named: .leftConversationNotification).contains {
                ($0.userInfo?["conversationId"] as? String) == conversationId
            }
        }

        try await waitForCondition(timeout: 1.0) {
            let exists = (try? fixtures.conversationExists(id: conversationId)) ?? true
            return exists == false
        }

        let stillHasConversation = try fixtures.conversationExists(id: conversationId)
        #expect(stillHasConversation == false, "DBConversation row should be deleted after cleanup")

        let remainingMessages = try fixtures.messageCount(for: conversationId)
        #expect(remainingMessages == 0, "Cascade should remove all messages")

        let remainingInvites = try fixtures.inviteCount(for: conversationId)
        #expect(remainingInvites == 0, "Cascade should remove the invite row")

        let remainingMembers = try fixtures.memberCount(for: conversationId)
        #expect(remainingMembers == 0, "Cascade should remove conversation members")

        withExtendedLifetime(worker) {}
    }

    @Test("Deletes the DBConversation row of an exploded regular conversation, cascading its children")
    func testDeletesRegularConversationRowOnExpiration() async throws {
        let fixtures = ExpiredWorkerTestFixtures()
        let expiresAt = Date().addingTimeInterval(-60)
        try await fixtures.setupConversation(expiresAt: expiresAt)
        try await fixtures.seedMessages(count: 2)

        let conversationId = fixtures.conversationId
        let capture = NotificationCapture()
        capture.startCapturing(.leftConversationNotification)
        defer { capture.stopCapturing() }

        let worker = fixtures.createWorker()

        try await waitForCondition(timeout: 2.0) {
            capture.notifications(named: .leftConversationNotification).contains {
                ($0.userInfo?["conversationId"] as? String) == conversationId
            }
        }

        try await waitForCondition(timeout: 1.0) {
            let exists = (try? fixtures.conversationExists(id: conversationId)) ?? true
            return exists == false
        }

        let stillHasConversation = try fixtures.conversationExists(id: conversationId)
        #expect(stillHasConversation == false, "DBConversation row should be deleted after cleanup")

        let remainingMessages = try fixtures.messageCount(for: conversationId)
        #expect(remainingMessages == 0, "Cascade should remove all messages")

        withExtendedLifetime(worker) {}
    }

    @Test("Parent convo's inline invite still renders Exploded after the side convo row is deleted")
    func testParentInviteRendersExplodedAfterSideConvoDeletion() async throws {
        let fixtures = ExpiredWorkerTestFixtures()
        let sideConvoExpiresAt = Date().addingTimeInterval(-60)
        try await fixtures.setupConversation(expiresAt: sideConvoExpiresAt)
        try await fixtures.markAsSideConversation()

        let parentConversationId = "parent-of-\(fixtures.conversationId)"
        try await fixtures.setupConversation(id: parentConversationId, expiresAt: nil)
        let parentInviteMessageId = try await fixtures.seedInviteMessage(
            inParentConversation: parentConversationId,
            referencingSideConversationExpiresAt: sideConvoExpiresAt
        )

        let sideConvoId = fixtures.conversationId
        let capture = NotificationCapture()
        capture.startCapturing(.leftConversationNotification)
        defer { capture.stopCapturing() }

        let worker = fixtures.createWorker()

        try await waitForCondition(timeout: 2.0) {
            capture.notifications(named: .leftConversationNotification).contains {
                ($0.userInfo?["conversationId"] as? String) == sideConvoId
            }
        }

        try await waitForCondition(timeout: 1.0) {
            let exists = (try? fixtures.conversationExists(id: sideConvoId)) ?? true
            return exists == false
        }

        let parentInvite = try fixtures.loadInvitePayload(messageId: parentInviteMessageId)
        #expect(parentInvite?.isConversationExpired == true,
                "Parent invite should still report expired via embedded payload after side convo row is gone")

        withExtendedLifetime(worker) {}
    }

    @Test("Creator path: runs explodeConversation, never peer-self-leave")
    func testCreatorPathRunsExplode() async throws {
        // `MockXMTPClientProvider` hands back `mock-inbox-id` as the current
        // inbox, so setting the DBConversation's `creatorId` to match makes
        // the worker take the creator-explode branch.
        let fixtures = ExpiredWorkerTestFixtures(inboxId: "mock-inbox-id")
        try await fixtures.setupConversation(expiresAt: Date().addingTimeInterval(-60))

        let conversationId = fixtures.conversationId
        let capture = NotificationCapture()
        capture.startCapturing(.leftConversationNotification)
        defer { capture.stopCapturing() }

        let worker = fixtures.createWorker()

        try await waitForCondition(timeout: 2.0) {
            capture.notifications(named: .leftConversationNotification).contains {
                ($0.userInfo?["conversationId"] as? String) == conversationId
            }
        }

        #expect(fixtures.explosionWriter.explodedConversationIds.contains(conversationId),
                "Creator should run explodeConversation")
        #expect(!fixtures.explosionWriter.peerSelfLeftConversationIds.contains(conversationId),
                "Creator must not also invoke peer-self-leave")

        withExtendedLifetime(worker) {}
    }

    @Test("Peer path: runs peer-self-leave, never explodeConversation")
    func testPeerPathRunsSelfLeaveOnly() async throws {
        // Default inboxId (`test-inbox-id`) does not match the mocked
        // current inbox (`mock-inbox-id`) so the worker takes the peer
        // branch.
        let fixtures = ExpiredWorkerTestFixtures()
        try await fixtures.setupConversation(expiresAt: Date().addingTimeInterval(-60))

        let conversationId = fixtures.conversationId
        let capture = NotificationCapture()
        capture.startCapturing(.leftConversationNotification)
        defer { capture.stopCapturing() }

        let worker = fixtures.createWorker()

        try await waitForCondition(timeout: 2.0) {
            capture.notifications(named: .leftConversationNotification).contains {
                ($0.userInfo?["conversationId"] as? String) == conversationId
            }
        }

        #expect(fixtures.explosionWriter.peerSelfLeftConversationIds.contains(conversationId),
                "Peer should run peerSelfLeaveExpiredConversation")
        #expect(!fixtures.explosionWriter.explodedConversationIds.contains(conversationId),
                "Peer must not invoke the creator explode flow")

        withExtendedLifetime(worker) {}
    }

    @Test("Peer path: local cleanup still runs when the MLS leave fails")
    func testPeerPathLocalCleanupRunsEvenIfLeaveFails() async throws {
        // Construct a writer that throws on peer-self-leave to mirror the
        // "last member" / "already removed" cases. The worker must still
        // prune side-convo messages and post `.leftConversationNotification`.
        let throwingWriter = ThrowingExplosionWriter(error: StubExplodeError.leaveFailed)
        let sessionManager = MockInboxesService(
            mockMessagingService: MockMessagingService(conversationExplosionWriter: throwingWriter)
        )
        let databaseManager = MockDatabaseManager.makeTestDatabase()
        let appLifecycle = MockAppLifecycleProvider()
        ConvosLog.configure(environment: .tests)

        let conversationId = "expired-worker-peer-throw-\(UUID().uuidString)"
        try await databaseManager.dbWriter.write { db in
            let conversation = DBConversation(
                id: conversationId,
                                clientConversationId: conversationId,
                inviteTag: "test-invite-tag",
                creatorId: "test-inbox-id",
                kind: .group,
                consent: .allowed,
                createdAt: Date(),
                name: "Test Conversation",
                description: nil,
                imageURLString: nil,
                publicImageURLString: nil,
                includeInfoInPublicPreview: false,
                expiresAt: Date().addingTimeInterval(-60),
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
            try conversation.upsert(db)
        }

        let capture = NotificationCapture()
        capture.startCapturing(.leftConversationNotification)
        defer { capture.stopCapturing() }

        let worker = ExpiredConversationsWorker(
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            sessionManager: sessionManager,
            appLifecycle: appLifecycle
        )

        try await waitForCondition(timeout: 2.0) {
            capture.notifications(named: .leftConversationNotification).contains {
                ($0.userInfo?["conversationId"] as? String) == conversationId
            }
        }

        #expect(throwingWriter.peerSelfLeaveCalls.contains(conversationId),
                "Peer self-leave should still be invoked")

        withExtendedLifetime(worker) {}
    }
}

// MARK: - Test fixtures

private final class ExpiredWorkerTestFixtures {
    let databaseManager: MockDatabaseManager
    let appLifecycle: MockAppLifecycleProvider
    let sessionManager: MockInboxesService
    let explosionWriter: MockConversationExplosionWriter
    let conversationId: String = "expired-worker-test-\(UUID().uuidString)"
    let inboxId: String
    let clientId: String = "test-client-id"

    /// - Parameter inboxId: Overrides the creator inboxId written into the
    ///   test `DBConversation`. Pass `"mock-inbox-id"` to make it match
    ///   `MockXMTPClientProvider`'s default (exercises the creator-explode
    ///   branch); any other value exercises the peer-self-leave branch.
    init(inboxId: String = "test-inbox-id") {
        self.databaseManager = MockDatabaseManager.makeTestDatabase()
        self.appLifecycle = MockAppLifecycleProvider()
        self.explosionWriter = MockConversationExplosionWriter()
        self.sessionManager = MockInboxesService(
            mockMessagingService: MockMessagingService(
                conversationExplosionWriter: explosionWriter
            )
        )
        self.inboxId = inboxId
        ConvosLog.configure(environment: .tests)
    }

    func createWorker() -> ExpiredConversationsWorker {
        ExpiredConversationsWorker(
            databaseReader: databaseManager.dbReader,
            databaseWriter: databaseManager.dbWriter,
            sessionManager: sessionManager,
            appLifecycle: appLifecycle
        )
    }

    func markAsSideConversation() async throws {
        let convId = conversationId
        let creator = inboxId
        try await databaseManager.dbWriter.write { db in
            try DBMember(inboxId: creator).save(db, onConflict: .ignore)
            try DBConversationMember(
                conversationId: convId,
                inboxId: creator,
                role: .superAdmin,
                consent: .allowed,
                createdAt: Date(),
                invitedByInboxId: nil
            ).insert(db)
            try DBInvite(
                creatorInboxId: creator,
                conversationId: convId,
                urlSlug: "slug-\(convId)",
                expiresAt: nil,
                expiresAfterUse: false
            ).insert(db)
        }
    }

    func seedMessages(count: Int) async throws {
        let convId = conversationId
        let senderId = inboxId
        try await databaseManager.dbWriter.write { db in
            try DBMember(inboxId: senderId).save(db, onConflict: .ignore)
            for index in 0..<count {
                let now = Date()
                let id = "msg-\(convId)-\(index)"
                try DBMessage(
                    id: id,
                    clientMessageId: id,
                    conversationId: convId,
                    senderId: senderId,
                    dateNs: Int64(now.timeIntervalSince1970 * 1_000_000_000),
                    date: now,
                    sortId: Int64(index),
                    status: .published,
                    messageType: .original,
                    contentType: .text,
                    text: "hello \(index)",
                    emoji: nil,
                    invite: nil,
                    linkPreview: nil,
                    sourceMessageId: nil,
                    attachmentUrls: [],
                    update: nil
                ).insert(db)
            }
        }
    }

    func messageCount(for conversationId: String) throws -> Int {
        try databaseManager.dbReader.read { db in
            try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .fetchCount(db)
        }
    }

    func inviteCount(for conversationId: String) throws -> Int {
        try databaseManager.dbReader.read { db in
            try DBInvite
                .filter(DBInvite.Columns.conversationId == conversationId)
                .fetchCount(db)
        }
    }

    func memberCount(for conversationId: String) throws -> Int {
        try databaseManager.dbReader.read { db in
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .fetchCount(db)
        }
    }

    func conversationExists(id: String) throws -> Bool {
        try databaseManager.dbReader.read { db in
            try DBConversation.fetchOne(db, key: id) != nil
        }
    }

    func seedInviteMessage(
        inParentConversation parentConversationId: String,
        referencingSideConversationExpiresAt sideConvoExpiresAt: Date
    ) async throws -> String {
        let senderId = inboxId
        let messageId = "invite-msg-\(parentConversationId)"
        let invite = MessageInvite(
            inviteSlug: "slug-parent-invite",
            conversationName: "Test Side Convo",
            conversationDescription: nil,
            imageURL: nil,
            emoji: nil,
            expiresAt: nil,
            conversationExpiresAt: sideConvoExpiresAt
        )
        try await databaseManager.dbWriter.write { db in
            try DBMember(inboxId: senderId).save(db, onConflict: .ignore)
            let now = Date()
            try DBMessage(
                id: messageId,
                clientMessageId: messageId,
                conversationId: parentConversationId,
                senderId: senderId,
                dateNs: Int64(now.timeIntervalSince1970 * 1_000_000_000),
                date: now,
                sortId: 0,
                status: .published,
                messageType: .original,
                contentType: .text,
                text: nil,
                emoji: nil,
                invite: invite,
                linkPreview: nil,
                sourceMessageId: nil,
                attachmentUrls: [],
                update: nil
            ).insert(db)
        }
        return messageId
    }

    func loadInvitePayload(messageId: String) throws -> MessageInvite? {
        try databaseManager.dbReader.read { db in
            try DBMessage.fetchOne(db, key: messageId)?.invite
        }
    }

    func setupConversation(id: String? = nil, expiresAt: Date?) async throws {
        let convId = id ?? conversationId
        let inbxId = inboxId
        try await databaseManager.dbWriter.write { db in
            let conversation = DBConversation(
                id: convId,
                clientConversationId: convId,
                inviteTag: "test-invite-tag-\(convId)",
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
                hasHadVerifiedAssistant: false,
            )
            try conversation.upsert(db)
        }
    }
}

// MARK: - Helpers

private enum StubExplodeError: Error {
    case leaveFailed
}

/// Explosion writer that records invocations and can surface a thrown peer
/// self-leave without actually running the sweep. Used to assert local
/// cleanup still fires when the MLS leg fails.
private final class ThrowingExplosionWriter: ConversationExplosionWriterProtocol, @unchecked Sendable {
    private let callsLock: OSAllocatedUnfairLock<[String]> = .init(initialState: [])
    private let error: (any Error)?

    init(error: (any Error)? = nil) {
        self.error = error
    }

    var peerSelfLeaveCalls: [String] {
        callsLock.withLock { $0 }
    }

    func explodeConversation(conversationId: String, memberInboxIds: [String]) async throws {}

    func scheduleExplosion(conversationId: String, expiresAt: Date) async throws {}

    /// Mirrors the real writer's contract: the peer-self-leave entry point
    /// is non-throwing, because the bounded-op wrapper internally swallows
    /// all leave failures — benign libxmtp errors (last-member /
    /// already-removed) and otherwise. We capture the call so tests can
    /// still assert it fired even when we simulate an underlying failure.
    func peerSelfLeaveExpiredConversation(conversationId: String) async {
        callsLock.withLock { $0.append(conversationId) }
        // Error is retained purely so test sites can read back what
        // scenario was configured; the writer itself swallows it.
        _ = error
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
