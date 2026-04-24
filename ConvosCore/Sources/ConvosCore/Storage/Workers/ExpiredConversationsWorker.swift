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
    private let databaseWriter: any DatabaseWriter
    private let appLifecycle: any AppLifecycleProviding
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private let taskLock: NSLock = NSLock()
    private var nextExpirationTask: Task<Void, Never>?

    init(
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        sessionManager: any SessionManagerProtocol,
        appLifecycle: any AppLifecycleProviding
    ) {
        self.databaseReader = databaseReader
        self.databaseWriter = databaseWriter
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
                let members = try DBConversationMember
                    .filter(DBConversationMember.Columns.conversationId == row.id)
                    .fetchAll(db)
                    .map(\.inboxId)
                return ExpiredConversation(
                    conversationId: row.id,
                    ownershipContext: .init(
                        creatorInboxId: row.creatorId,
                        memberInboxIds: members
                    )
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

        // Scheduled-explode parity: when the timer fires on the creator's
        // device, the MLS teardown (removeMembers + leaveGroup) has to
        // actually run. Pre-fix, the worker only posted
        // `.leftConversationNotification` — the creator stayed in the
        // group on the network indefinitely until they manually exploded
        // again from the UI. A scheduled explode was strictly weaker than
        // an immediate one.
        //
        // We fetch the member list + creator inboxId, check whether the
        // current inbox is the creator, and if so invoke the writer. The
        // writer's own `runBoundedMLSOp` helper absorbs any MLS flakes
        // without rethrowing, so this is fire-and-observe — failures log
        // and the notification still posts below.
        if let context = conversation.ownershipContext {
            await executeExplodeIfCreator(conversation: conversation, context: context)
        }

        await pruneExpiredSideConversationStorage(conversationId: conversation.conversationId)

        await MainActor.run {
            NotificationCenter.default.post(
                name: .leftConversationNotification,
                object: nil,
                userInfo: ["conversationId": conversation.conversationId]
            )
        }
    }

    /// Deletes the cached messages of an exploded side convo to free storage.
    /// The `DBConversation` shell is intentionally left behind so the parent
    /// convo's inline invite row can still render as "Exploded" via the
    /// `DBInvite → DBConversation.expiresAt` join at fetch time.
    private func pruneExpiredSideConversationStorage(conversationId: String) async {
        do {
            let deletedCount = try await databaseWriter.write { db -> Int in
                let isSideConvo = try DBInvite
                    .filter(DBInvite.Columns.conversationId == conversationId)
                    .fetchCount(db) > 0
                guard isSideConvo else { return 0 }
                return try DBMessage
                    .filter(DBMessage.Columns.conversationId == conversationId)
                    .deleteAll(db)
            }
            if deletedCount > 0 {
                Log.info("Pruned \(deletedCount) message(s) from expired side convo \(conversationId)")
            }
        } catch {
            Log.error("Failed to prune messages for expired side convo \(conversationId): \(error)")
        }
    }

    private func executeExplodeIfCreator(
        conversation: ExpiredConversation,
        context: ExpiredConversation.OwnershipContext
    ) async {
        let service = sessionManager.messagingService()
        let currentInboxId: String
        do {
            // Don't read `currentState.inboxId` directly — it's nil during
            // `.registering` and `.error`, which would silently skip the
            // creator-side teardown when the timer fires against an inbox
            // that's still bootstrapping.
            let inboxReady = try await service.sessionStateManager.waitForInboxReadyResult()
            currentInboxId = inboxReady.client.inboxId
        } catch {
            Log.error("Scheduled explode for \(conversation.conversationId) skipped: inbox never became ready (\(error))")
            return
        }
        guard currentInboxId == context.creatorInboxId else {
            return
        }
        let writer = service.conversationExplosionWriter()
        do {
            try await writer.explodeConversation(
                conversationId: conversation.conversationId,
                memberInboxIds: context.memberInboxIds
            )
        } catch {
            Log.error("Scheduled explode for \(conversation.conversationId) threw: \(error)")
        }
    }
}

struct ExpiredConversation {
    let conversationId: String
    /// Populated when the row has the creator + member data needed to
    /// invoke the explosion writer. `nil` for the legacy notification-only
    /// cleanup path (rows created pre-scheduled-explode-parity).
    let ownershipContext: OwnershipContext?

    struct OwnershipContext {
        let creatorInboxId: String
        let memberInboxIds: [String]
    }

    init(conversationId: String, ownershipContext: OwnershipContext? = nil) {
        self.conversationId = conversationId
        self.ownershipContext = ownershipContext
    }
}

private extension Database {
    func fetchExpiredConversations() throws -> [ExpiredConversation] {
        let rows = try DBConversation
            .filter(DBConversation.Columns.expiresAt != nil)
            .filter(DBConversation.Columns.expiresAt <= Date())
            .fetchAll(self)

        return try rows.map { row in
            let members = try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == row.id)
                .fetchAll(self)
                .map(\.inboxId)
            return ExpiredConversation(
                conversationId: row.id,
                ownershipContext: .init(
                    creatorInboxId: row.creatorId,
                    memberInboxIds: members
                )
            )
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
