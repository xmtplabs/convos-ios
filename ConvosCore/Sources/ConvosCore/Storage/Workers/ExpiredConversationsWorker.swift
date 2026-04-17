import Foundation
import GRDB

public protocol ExpiredConversationsWorkerProtocol {}

/// Monitors conversations with scheduled explosions and triggers cleanup when they expire.
///
/// Uses a single timer targeting the next expiring conversation rather than per-conversation
/// timers. After processing expired conversations, queries the database for the soonest
/// future expiresAt and schedules one task to wake at that time.
///
/// @unchecked Sendable: Protocol dependencies (SessionManager, DatabaseReader, AppLifecycle)
/// are all Sendable. The `observers` array is only modified during init and deinit.
/// The `nextExpirationTask` is protected by `taskLock`.
final class ExpiredConversationsWorker: ExpiredConversationsWorkerProtocol, @unchecked Sendable {
    private let sessionManager: any SessionManagerProtocol
    private let databaseReader: any DatabaseReader
    private let appLifecycle: any AppLifecycleProviding
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private let taskLock: NSLock = NSLock()
    private var nextExpirationTask: Task<Void, Never>?

    init(
        databaseReader: any DatabaseReader,
        sessionManager: any SessionManagerProtocol,
        appLifecycle: any AppLifecycleProviding
    ) {
        self.databaseReader = databaseReader
        self.sessionManager = sessionManager
        self.appLifecycle = appLifecycle
        setupObservers()
        checkAndReschedule()
    }

    deinit {
        Log.warning("ExpiredConversationsWorker deinit - removing observers")
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        cancelNextExpirationTask()
    }

    private func setupObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: appLifecycle.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkAndReschedule()
        })

        observers.append(center.addObserver(
            forName: .conversationExpired,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Log.info("ExpiredConversationsWorker received .conversationExpired notification")
            if let conversationId = notification.userInfo?["conversationId"] as? String {
                self?.handleExpiredConversation(conversationId: conversationId)
            } else {
                self?.checkAndReschedule()
            }
        })

        observers.append(center.addObserver(
            forName: .conversationScheduledExplosion,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkAndReschedule()
        })

        observers.append(center.addObserver(
            forName: .explosionNotificationTapped,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkAndReschedule()
        })
    }

    private func handleExpiredConversation(conversationId: String) {
        Task { [weak self] in
            guard let self else { return }
            await self.processExpiredConversationById(conversationId)
            await self.scheduleNextExpirationCheck()
        }
    }

    private func checkAndReschedule() {
        Task { [weak self] in
            guard let self else { return }
            await self.queryAndProcessExpiredConversations()
            await self.scheduleNextExpirationCheck()
        }
    }

    private func scheduleNextExpirationCheck() async {
        cancelNextExpirationTask()

        do {
            let nextExpiresAt = try await databaseReader.read { db -> Date? in
                try db.fetchNextExpiration()
            }

            guard let nextExpiresAt else { return }

            let interval = nextExpiresAt.timeIntervalSinceNow
            guard interval > 0 else {
                await queryAndProcessExpiredConversations()
                await scheduleNextExpirationCheck()
                return
            }

            let bufferedInterval: Double = interval + Constant.expirationBuffer
            Log.info("ExpiredConversationsWorker: next expiration in \(Int(interval))s (sleeping \(bufferedInterval)s)")

            let task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(bufferedInterval))
                guard !Task.isCancelled else { return }
                self?.checkAndReschedule()
            }

            replaceNextExpirationTask(task)
        } catch {
            Log.error("Failed to query next expiration: \(error)")
        }
    }

    private nonisolated func cancelNextExpirationTask() {
        taskLock.lock()
        nextExpirationTask?.cancel()
        nextExpirationTask = nil
        taskLock.unlock()
    }

    private nonisolated func replaceNextExpirationTask(_ task: Task<Void, Never>) {
        taskLock.lock()
        nextExpirationTask?.cancel()
        nextExpirationTask = task
        taskLock.unlock()
    }

    private func processExpiredConversationById(_ conversationId: String) async {
        do {
            let conversation = try await databaseReader.read { db -> ExpiredConversation? in
                guard let row = try DBConversation.fetchOne(db, key: conversationId),
                      let expiresAt = row.expiresAt,
                      expiresAt <= Date() else {
                    return nil
                }
                return ExpiredConversation(conversationId: row.id)
            }
            if let conversation {
                await cleanupExpiredConversation(conversation)
            }
        } catch {
            Log.error("Failed to fetch expired conversation \(conversationId): \(error)")
        }
    }

    private func queryAndProcessExpiredConversations() async {
        do {
            let expiredConversations = try await databaseReader.read { db in
                try db.fetchExpiredConversations()
            }
            guard !expiredConversations.isEmpty else { return }
            for conversation in expiredConversations {
                await cleanupExpiredConversation(conversation)
            }
        } catch {
            Log.error("Failed to query expired conversations: \(error)")
        }
    }

    private enum Constant {
        static let expirationBuffer: TimeInterval = 0.5
    }

    private func cleanupExpiredConversation(_ conversation: ExpiredConversation) async {
        Log.info("Cleaning up expired conversation: \(conversation.conversationId), posting leftConversationNotification")

        await MainActor.run {
            NotificationCenter.default.post(
                name: .leftConversationNotification,
                object: nil,
                userInfo: ["conversationId": conversation.conversationId]
            )
        }
    }
}

struct ExpiredConversation {
    let conversationId: String
}

private extension Database {
    func fetchExpiredConversations() throws -> [ExpiredConversation] {
        let rows = try DBConversation
            .filter(DBConversation.Columns.expiresAt != nil)
            .filter(DBConversation.Columns.expiresAt <= Date())
            .fetchAll(self)

        return rows.map { row in
            ExpiredConversation(conversationId: row.id)
        }
    }

    func fetchNextExpiration() throws -> Date? {
        try DBConversation
            .filter(DBConversation.Columns.expiresAt != nil)
            .filter(DBConversation.Columns.expiresAt > Date())
            .order(DBConversation.Columns.expiresAt.asc)
            .fetchOne(self)?
            .expiresAt
    }
}
