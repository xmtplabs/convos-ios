import Foundation
import GRDB

public protocol ExpiredConversationsWorkerProtocol {}

/// @unchecked Sendable: Protocol dependencies (SessionManager, DatabaseReader, AppLifecycle)
/// are all Sendable. The `observers` array is marked `nonisolated(unsafe)` and only modified
/// during init (setupObservers) and deinit. NotificationCenter callbacks use weak self
/// and dispatch work to async Tasks.
final class ExpiredConversationsWorker: ExpiredConversationsWorkerProtocol, @unchecked Sendable {
    private let sessionManager: any SessionManagerProtocol
    private let databaseReader: any DatabaseReader
    private let appLifecycle: any AppLifecycleProviding
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(
        databaseReader: any DatabaseReader,
        sessionManager: any SessionManagerProtocol,
        appLifecycle: any AppLifecycleProviding
    ) {
        self.databaseReader = databaseReader
        self.sessionManager = sessionManager
        self.appLifecycle = appLifecycle
        setupObservers()
        checkForExpiredConversations()
    }

    deinit {
        Log.warning("ExpiredConversationsWorker deinit - removing observers")
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func setupObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: appLifecycle.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkForExpiredConversations()
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
                self?.checkForExpiredConversations()
            }
        })

        observers.append(center.addObserver(
            forName: .explosionNotificationTapped,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkForExpiredConversations()
        })
    }

    private func checkForExpiredConversations() {
        Task { [weak self] in
            guard let self else { return }
            await self.queryAndProcessExpiredConversations()
        }
    }

    private func handleExpiredConversation(conversationId: String) {
        Task { [weak self] in
            guard let self else { return }
            await self.processExpiredConversationById(conversationId)
        }
    }

    private func processExpiredConversationById(_ conversationId: String) async {
        do {
            let conversation = try await databaseReader.read { db -> ExpiredConversation? in
                guard let row = try DBConversation.fetchOne(db, key: conversationId) else {
                    Log.warning("Conversation not found for expiration: \(conversationId)")
                    return nil
                }
                return ExpiredConversation(
                    conversationId: row.id,
                    clientId: row.clientId,
                    inboxId: row.inboxId
                )
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
            await processExpiredConversations(expiredConversations)
        } catch {
            Log.error("Failed to query expired conversations: \(error)")
        }
    }

    private func processExpiredConversations(_ conversations: [ExpiredConversation]) async {
        for conversation in conversations {
            await cleanupExpiredConversation(conversation)
        }
    }

    private func cleanupExpiredConversation(_ conversation: ExpiredConversation) async {
        Log.info("Cleaning up expired conversation: \(conversation.conversationId), posting leftConversationNotification")

        await MainActor.run {
            NotificationCenter.default.post(
                name: .leftConversationNotification,
                object: nil,
                userInfo: [
                    "conversationId": conversation.conversationId,
                    "clientId": conversation.clientId,
                    "inboxId": conversation.inboxId
                ]
            )
        }
    }
}

struct ExpiredConversation {
    let conversationId: String
    let clientId: String
    let inboxId: String
}

fileprivate extension Database {
    func fetchExpiredConversations() throws -> [ExpiredConversation] {
        let rows = try DBConversation
            .filter(DBConversation.Columns.expiresAt != nil)
            .filter(DBConversation.Columns.expiresAt <= Date())
            .fetchAll(self)

        return rows.map { row in
            ExpiredConversation(
                conversationId: row.id,
                clientId: row.clientId,
                inboxId: row.inboxId
            )
        }
    }
}
