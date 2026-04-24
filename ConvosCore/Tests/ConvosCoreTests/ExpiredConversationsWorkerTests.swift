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
        #expect(matched, "Should clean up conversation when timer fires")
    }

    @Test("Reschedules timer when new explosion is scheduled")
    func testReschedulesOnNewExplosion() async throws {
        let fixtures = ExpiredWorkerTestFixtures()
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
}

private class ExpiredWorkerTestFixtures {
    let databaseManager: MockDatabaseManager
    let appLifecycle: MockAppLifecycleProvider
    let sessionManager: MockInboxesService
    let conversationId: String = "expired-worker-test-\(UUID().uuidString)"
    let inboxId: String = "test-inbox-id"

    init() {
        self.databaseManager = MockDatabaseManager.makeTestDatabase()
        self.appLifecycle = MockAppLifecycleProvider()
        self.sessionManager = MockInboxesService()
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

private func waitForCondition(timeout: TimeInterval, condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() {
            return
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}
