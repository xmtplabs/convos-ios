@testable import ConvosCore
import Foundation
import GRDB
import Testing
import UserNotifications

@Suite("ScheduledExplosionManager Tests", .serialized)
struct ScheduledExplosionManagerTests {

    @Test("Schedules reminder notification for future explosion > 1 hour away")
    func testSchedulesReminderNotification() async throws {
        let fixtures = ScheduledExplosionTestFixtures()
        let expiresAt = Date().addingTimeInterval(7200)
        try await fixtures.setupConversation(expiresAt: expiresAt)

        let conversationId = fixtures.conversationId
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

        let reminderIdentifier = "explosion-reminder-\(conversationId)"
        try await waitForCondition(timeout: 2.0) {
            fixtures.notificationCenter.hasRequest(withIdentifier: reminderIdentifier)
        }

        let hasReminder = fixtures.notificationCenter.hasRequest(withIdentifier: reminderIdentifier)
        #expect(hasReminder, "Should schedule reminder notification")
    }

    @Test("Schedules explosion notification at expiresAt")
    func testSchedulesExplosionNotification() async throws {
        let fixtures = ScheduledExplosionTestFixtures()
        let expiresAt = Date().addingTimeInterval(7200)
        try await fixtures.setupConversation(expiresAt: expiresAt)

        let conversationId = fixtures.conversationId
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

        let explosionIdentifier = "explosion-\(conversationId)"
        try await waitForCondition(timeout: 2.0) {
            fixtures.notificationCenter.hasRequest(withIdentifier: explosionIdentifier)
        }

        let hasExplosion = fixtures.notificationCenter.hasRequest(withIdentifier: explosionIdentifier)
        #expect(hasExplosion, "Should schedule explosion notification")
    }

    @Test("Skips reminder when less than 1 hour until explosion")
    func testSkipsReminderWhenLessThanOneHour() async throws {
        let fixtures = ScheduledExplosionTestFixtures()
        let expiresAt = Date().addingTimeInterval(1800)
        try await fixtures.setupConversation(expiresAt: expiresAt)

        let conversationId = fixtures.conversationId
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

        let explosionIdentifier = "explosion-\(conversationId)"
        try await waitForCondition(timeout: 2.0) {
            fixtures.notificationCenter.hasRequest(withIdentifier: explosionIdentifier)
        }

        let hasReminder = fixtures.notificationCenter.hasRequest(
            withIdentifier: "explosion-reminder-\(conversationId)"
        )
        let hasExplosion = fixtures.notificationCenter.hasRequest(withIdentifier: explosionIdentifier)

        #expect(!hasReminder, "Should not schedule reminder when < 1 hour")
        #expect(hasExplosion, "Should still schedule explosion notification")
    }

    @Test("Skips notifications when already expired")
    func testSkipsNotificationsWhenAlreadyExpired() async throws {
        let fixtures = ScheduledExplosionTestFixtures()
        let expiresAt = Date().addingTimeInterval(-60)
        try await fixtures.setupConversation(expiresAt: expiresAt)

        let conversationId = fixtures.conversationId
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

        try await waitForCondition(timeout: 2.0) {
            !fixtures.manager.hasSchedulingTask(for: conversationId)
        }

        let hasReminder = fixtures.notificationCenter.hasRequest(
            withIdentifier: "explosion-reminder-\(conversationId)"
        )
        let hasExplosion = fixtures.notificationCenter.hasRequest(
            withIdentifier: "explosion-\(conversationId)"
        )

        #expect(!hasReminder, "Should not schedule reminder for expired")
        #expect(!hasExplosion, "Should not schedule explosion for expired")
    }

    @Test("Cancels notifications when conversation expires")
    func testCancelsNotificationsOnExpire() async throws {
        let fixtures = ScheduledExplosionTestFixtures()
        let expiresAt = Date().addingTimeInterval(7200)
        try await fixtures.setupConversation(expiresAt: expiresAt)

        let conversationId = fixtures.conversationId
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

        let reminderIdentifier = "explosion-reminder-\(conversationId)"
        try await waitForCondition(timeout: 2.0) {
            fixtures.notificationCenter.hasRequest(withIdentifier: reminderIdentifier)
        }

        let hasReminderBefore = fixtures.notificationCenter.hasRequest(withIdentifier: reminderIdentifier)
        #expect(hasReminderBefore, "Should have reminder before cancel")

        await MainActor.run {
            NotificationCenter.default.post(
                name: .conversationExpired,
                object: nil,
                userInfo: ["conversationId": conversationId]
            )
        }

        try await Task.sleep(for: .milliseconds(100))

        let removedIds = fixtures.notificationCenter.removedIdentifiers
        #expect(removedIds.contains("explosion-reminder-\(conversationId)"))
        #expect(removedIds.contains("explosion-\(conversationId)"))
    }

    @Test("Notification content has correct format")
    func testNotificationContentFormat() async throws {
        let fixtures = ScheduledExplosionTestFixtures()
        let expiresAt = Date().addingTimeInterval(7200)
        try await fixtures.setupConversation(expiresAt: expiresAt)

        let conversationId = fixtures.conversationId
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

        let reminderIdentifier = "explosion-reminder-\(conversationId)"
        try await waitForCondition(timeout: 2.0) {
            fixtures.notificationCenter.hasRequest(withIdentifier: reminderIdentifier)
        }

        let reminderRequest = fixtures.notificationCenter.getRequest(withIdentifier: reminderIdentifier)
        let explosionRequest = fixtures.notificationCenter.getRequest(
            withIdentifier: "explosion-\(conversationId)"
        )

        #expect(reminderRequest != nil)
        #expect(explosionRequest != nil)

        if let reminderContent = reminderRequest?.content {
            #expect(reminderContent.title == "Test Conversation")
            #expect(reminderContent.body == "Will explode in 1h")
            #expect(reminderContent.userInfo["isExplosionReminder"] as? Bool == true)
            #expect(reminderContent.userInfo["conversationId"] as? String == conversationId)
            #expect(reminderContent.threadIdentifier == conversationId)
        }

        if let explosionContent = explosionRequest?.content {
            #expect(explosionContent.title == "Test Conversation")
            #expect(explosionContent.body.contains("Boom!"))
            #expect(explosionContent.userInfo["isExplosion"] as? Bool == true)
            #expect(explosionContent.userInfo["conversationId"] as? String == conversationId)
            #expect(explosionContent.threadIdentifier == conversationId)
        }
    }

    @Test("Reschedules pending explosions on app becoming active")
    func testReschedulesOnAppActive() async throws {
        let fixtures = ScheduledExplosionTestFixtures()
        let expiresAt = Date().addingTimeInterval(7200)
        try await fixtures.setupConversation(expiresAt: expiresAt)

        let conversationId = fixtures.conversationId
        let activeNotification = fixtures.appLifecycle.didBecomeActiveNotification
        await MainActor.run {
            NotificationCenter.default.post(
                name: activeNotification,
                object: nil
            )
        }

        let explosionIdentifier = "explosion-\(conversationId)"
        try await waitForCondition(timeout: 2.0) {
            fixtures.notificationCenter.hasRequest(withIdentifier: explosionIdentifier)
        }

        let hasExplosion = fixtures.notificationCenter.hasRequest(withIdentifier: explosionIdentifier)
        #expect(hasExplosion, "Should schedule explosion on app active")
    }
}

private class ScheduledExplosionTestFixtures {
    let databaseManager: MockDatabaseManager
    let appLifecycle: MockAppLifecycleProvider
    let notificationCenter: MockUserNotificationCenter
    let manager: ScheduledExplosionManager
    let conversationId: String = "explosion-test-\(UUID().uuidString)"
    let inboxId: String = "test-inbox-id"
    let clientId: String = "test-client-id"

    init() {
        self.databaseManager = MockDatabaseManager.makeTestDatabase()
        self.appLifecycle = MockAppLifecycleProvider()
        self.notificationCenter = MockUserNotificationCenter()
        ConvosLog.configure(environment: .tests)

        self.manager = ScheduledExplosionManager(
            databaseReader: databaseManager.dbReader,
            appLifecycle: appLifecycle,
            notificationCenter: notificationCenter
        )
    }

    func setupConversation(expiresAt: Date?) async throws {
        let convId = conversationId
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
                isUnused: false
            )
            try conversation.insert(db)
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
