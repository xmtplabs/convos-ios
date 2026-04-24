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
        // device, the MLS teardown (`removeMembers` + `denyConsent`) has
        // to actually run, otherwise the creator stays in the group on
        // the network indefinitely until they manually explode again
        // from the UI.
        //
        // On non-creator devices the peer walks out of the MLS group on
        // their own (`leaveGroup` + `denyConsent`) — if the creator is
        // offline past T the group would otherwise persist on the XMTP
        // network with every peer still subscribed, and any message sent
        // during that window syncs back onto phantom convo rows.
        //
        // Both branches fire-and-observe: the writer absorbs MLS flakes
        // and the local cleanup below always runs.
        if let context = conversation.ownershipContext {
            await executeExpirationMLSAction(conversation: conversation, context: context)
        }

        await MainActor.run {
            NotificationCenter.default.post(
                name: .leftConversationNotification,
                object: nil,
                userInfo: ["conversationId": conversation.conversationId]
            )
        }

        await deleteExpiredConversationRow(conversationId: conversation.conversationId)
    }

    /// Deletes the expired conversation's row so the worker stops re-processing it.
    /// Foreign-key cascade removes every child table (messages, invites, members,
    /// local state, photo prefs, attachments). The parent convo's inline invite
    /// row still renders as "Exploded" because that check reads
    /// `conversationExpiresAt` from the embedded `SignedInvite` payload on
    /// `DBMessage.invite`, not from this row.
    private func deleteExpiredConversationRow(conversationId: String) async {
        do {
            try await databaseWriter.write { db in
                _ = try DBConversation.deleteOne(db, key: conversationId)
            }
        } catch {
            Log.error("Failed to delete expired DBConversation row \(conversationId): \(error)")
        }
    }

    private func executeExpirationMLSAction(
        conversation: ExpiredConversation,
        context: ExpiredConversation.OwnershipContext
    ) async {
        let service = sessionManager.messagingService()
        let currentInboxId: String
        do {
            // Don't read `currentState.inboxId` directly — it's nil during
            // `.registering` and `.error`, which would silently skip the
            // teardown when the timer fires against an inbox that's still
            // bootstrapping.
            let inboxReady = try await service.sessionStateManager.waitForInboxReadyResult()
            currentInboxId = inboxReady.client.inboxId
        } catch {
            Log.error("Scheduled expiration for \(conversation.conversationId) skipped: inbox never became ready (\(error))")
            return
        }
        if currentInboxId == context.creatorInboxId {
            await executeCreatorExplode(conversation: conversation, context: context, service: service)
        } else {
            await executePeerSelfLeave(conversation: conversation, service: service)
        }
    }

    private func executeCreatorExplode(
        conversation: ExpiredConversation,
        context: ExpiredConversation.OwnershipContext,
        service: AnyMessagingService
    ) async {
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

    /// Each peer walks out of the MLS group on their own rather than
    /// waiting for the creator to kick them — if the creator is offline
    /// past T the group would otherwise persist on the server with every
    /// peer still subscribed, letting any in-flight peer/bot message sync
    /// onto phantom convo rows across all peers.
    ///
    /// The writer swallows the known benign failures (last-member
    /// `LeaveCantProcessed`, already-removed `NotFound::MlsGroup`) and
    /// always follows up with `denyConsent` as belt-and-suspenders, so this
    /// is fire-and-observe; the local cleanup above runs either way.
    private func executePeerSelfLeave(
        conversation: ExpiredConversation,
        service: AnyMessagingService
    ) async {
        let writer = service.conversationExplosionWriter()
        await writer.peerSelfLeaveExpiredConversation(
            conversationId: conversation.conversationId
        )
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
