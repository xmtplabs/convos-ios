import Foundation
import GRDB
import UserNotifications

public protocol ScheduledExplosionManagerProtocol {}

/// @unchecked Sendable: Protocol dependencies (DatabaseReader, AppLifecycle)
/// are all Sendable. The `observers` array is only modified during init and deinit.
/// The `schedulingTasks` dictionary is protected by `taskLock` to prevent data races
/// from concurrent notification callbacks.
final class ScheduledExplosionManager: ScheduledExplosionManagerProtocol, @unchecked Sendable {
    private let databaseReader: any DatabaseReader
    private let appLifecycle: any AppLifecycleProviding
    private let notificationCenter: any UserNotificationCenterProtocol
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private let taskLock: NSLock = NSLock()
    private var _schedulingTasks: [String: Task<Void, Never>] = [:]

    private enum Constant {
        static let reminderIdentifierPrefix: String = "explosion-reminder-"
        static let explosionIdentifierPrefix: String = "explosion-"
        static let oneHourInSeconds: TimeInterval = 3600
    }

    init(
        databaseReader: any DatabaseReader,
        appLifecycle: any AppLifecycleProviding,
        notificationCenter: any UserNotificationCenterProtocol = UNUserNotificationCenter.current()
    ) {
        self.databaseReader = databaseReader
        self.appLifecycle = appLifecycle
        self.notificationCenter = notificationCenter
        setupObservers()
        scheduleRemindersForPendingExplosions()
    }

    deinit {
        Log.warning("ScheduledExplosionManager deinit - removing observers")
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func setupObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: appLifecycle.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRemindersForPendingExplosions()
        })

        observers.append(center.addObserver(
            forName: .conversationScheduledExplosion,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let conversationId = notification.userInfo?["conversationId"] as? String,
                  let expiresAt = notification.userInfo?["expiresAt"] as? Date else {
                return
            }
            self?.handleScheduledExplosion(conversationId: conversationId, expiresAt: expiresAt)
        })

        observers.append(center.addObserver(
            forName: .conversationExpired,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            if let conversationId = notification.userInfo?["conversationId"] as? String {
                self?.cancelNotifications(for: conversationId)
            }
        })
    }

    private func handleScheduledExplosion(conversationId: String, expiresAt: Date) {
        taskLock.lock()
        _schedulingTasks[conversationId]?.cancel()
        _schedulingTasks[conversationId] = Task { [weak self] in
            guard let self else { return }
            await self.scheduleNotifications(conversationId: conversationId, expiresAt: expiresAt)
            guard !Task.isCancelled else { return }
            self.removeSchedulingTask(for: conversationId)
        }
        taskLock.unlock()
    }

    private nonisolated func removeSchedulingTask(for conversationId: String) {
        taskLock.lock()
        _schedulingTasks[conversationId] = nil
        taskLock.unlock()
    }

    func hasSchedulingTask(for conversationId: String) -> Bool {
        taskLock.lock()
        defer { taskLock.unlock() }
        return _schedulingTasks[conversationId] != nil
    }

    private func scheduleNotifications(
        conversationId: String,
        expiresAt: Date,
        conversationName: String? = nil
    ) async {
        let name: String
        if let conversationName, !conversationName.isEmpty {
            name = conversationName
        } else {
            name = await fetchConversationName(conversationId: conversationId)
        }

        await scheduleReminderNotification(
            conversationId: conversationId,
            expiresAt: expiresAt,
            conversationName: name
        )
        await scheduleExplosionNotification(
            conversationId: conversationId,
            expiresAt: expiresAt,
            conversationName: name
        )
    }

    private func scheduleRemindersForPendingExplosions() {
        Task { [weak self] in
            guard let self else { return }
            await self.queryAndScheduleReminders()
        }
    }

    private func queryAndScheduleReminders() async {
        do {
            let scheduledConversations = try await databaseReader.read { db in
                try db.fetchScheduledExplosions()
            }
            guard !scheduledConversations.isEmpty else { return }
            Log.info("ScheduledExplosionManager: Found \(scheduledConversations.count) scheduled explosions")
            for conversation in scheduledConversations {
                await scheduleNotifications(
                    conversationId: conversation.conversationId,
                    expiresAt: conversation.expiresAt,
                    conversationName: conversation.name
                )
            }
        } catch {
            Log.error("Failed to query scheduled explosions: \(error)")
        }
    }

    private func scheduleReminderNotification(
        conversationId: String,
        expiresAt: Date,
        conversationName: String? = nil
    ) async {
        let reminderDate = expiresAt.addingTimeInterval(-Constant.oneHourInSeconds)

        // Capture interval BEFORE any async operations to avoid time drift
        let reminderInterval = reminderDate.timeIntervalSinceNow
        guard reminderInterval > 0 else {
            Log.info("ScheduledExplosionManager: Skipping reminder for \(conversationId), less than 1 hour away")
            return
        }

        let name: String
        if let conversationName, !conversationName.isEmpty {
            name = conversationName
        } else {
            name = await fetchConversationName(conversationId: conversationId)
        }

        let content = UNMutableNotificationContent()
        content.title = name
        content.body = "Will explode in 1h"
        content.sound = .default
        content.userInfo = ["isExplosionReminder": true, "conversationId": conversationId]
        content.threadIdentifier = conversationId

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: reminderInterval,
            repeats: false
        )

        let identifier = "\(Constant.reminderIdentifierPrefix)\(conversationId)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        do {
            try await notificationCenter.add(request)
            Log.info("ScheduledExplosionManager: Scheduled 1-hour reminder for \(conversationId) at \(reminderDate)")
        } catch {
            Log.error("Failed to schedule explosion reminder: \(error.localizedDescription)")
        }
    }

    private func scheduleExplosionNotification(
        conversationId: String,
        expiresAt: Date,
        conversationName: String
    ) async {
        let timeInterval = expiresAt.timeIntervalSinceNow
        guard timeInterval > 0 else {
            Log.info("ScheduledExplosionManager: Skipping explosion notification for \(conversationId), already expired")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = conversationName
        content.body = "💥 Boom! This convo exploded. Its messages and members are gone forever"
        content.sound = .default
        content.userInfo = ["isExplosion": true, "conversationId": conversationId]
        content.threadIdentifier = conversationId

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: timeInterval,
            repeats: false
        )

        let identifier = "\(Constant.explosionIdentifierPrefix)\(conversationId)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )

        do {
            try await notificationCenter.add(request)
            Log.info("ScheduledExplosionManager: Scheduled explosion notification for \(conversationId) at \(expiresAt)")
        } catch {
            Log.error("Failed to schedule explosion notification: \(error.localizedDescription)")
        }
    }

    private func fetchConversationName(conversationId: String) async -> String {
        do {
            let name = try await databaseReader.read { db -> String? in
                try DBConversation.fetchOne(db, key: conversationId)?.name
            }
            if let name, !name.isEmpty {
                return name
            }
        } catch {
            Log.error("Failed to fetch conversation name: \(error)")
        }
        return "Untitled"
    }

    private func cancelNotifications(for conversationId: String) {
        taskLock.lock()
        _schedulingTasks[conversationId]?.cancel()
        _schedulingTasks[conversationId] = nil
        taskLock.unlock()
        let reminderIdentifier = "\(Constant.reminderIdentifierPrefix)\(conversationId)"
        let explosionIdentifier = "\(Constant.explosionIdentifierPrefix)\(conversationId)"
        notificationCenter.removePendingNotificationRequests(
            withIdentifiers: [reminderIdentifier, explosionIdentifier]
        )
        Log.info("ScheduledExplosionManager: Cancelled notifications for \(conversationId)")
    }
}

private struct ScheduledConversation {
    let conversationId: String
    let expiresAt: Date
    let name: String?
}

private extension Database {
    func fetchScheduledExplosions() throws -> [ScheduledConversation] {
        let rows = try DBConversation
            .filter(DBConversation.Columns.expiresAt != nil)
            .filter(DBConversation.Columns.expiresAt > Date())
            .fetchAll(self)

        return rows.compactMap { row in
            guard let expiresAt = row.expiresAt else { return nil }
            return ScheduledConversation(
                conversationId: row.id,
                expiresAt: expiresAt,
                name: row.name
            )
        }
    }
}
