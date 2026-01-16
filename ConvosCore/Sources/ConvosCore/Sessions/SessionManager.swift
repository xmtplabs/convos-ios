import Combine
import Foundation
import GRDB

public extension Notification.Name {
    static let leftConversationNotification: Notification.Name = Notification.Name("LeftConversationNotification")
    static let activeConversationChanged: Notification.Name = Notification.Name("ActiveConversationChanged")
}

public typealias AnyMessagingService = any MessagingServiceProtocol
public typealias AnyClientProvider = any XMTPClientProvider

enum SessionManagerError: Error {
    case inboxNotFound
}

/// Manages multiple inbox sessions and their lifecycle
///
/// SessionManager coordinates multiple MessagingService instances (one per inbox/identity),
/// handling their creation, lifecycle, and cleanup. It uses InboxLifecycleManager to enforce
/// a maximum number of awake (active) inboxes while supporting unlimited total conversations.
/// The manager also handles inbox deletion, conversation notifications, and manages
/// the UnusedInboxCache for pre-creating inboxes.
public final class SessionManager: SessionManagerProtocol, @unchecked Sendable {
    private var leftConversationObserver: Any?
    private var foregroundObserverTask: Task<Void, Never>?

    private let databaseWriter: any DatabaseWriter
    private let databaseReader: any DatabaseReader
    private let environment: AppEnvironment
    private let identityStore: any KeychainIdentityStoreProtocol
    private var initializationTask: Task<Void, Never>?
    private var unusedInboxPrepTask: Task<Void, Never>?
    private let deviceRegistrationManager: any DeviceRegistrationManagerProtocol
    private let notificationChangeReporter: any NotificationChangeReporterType
    private let platformProviders: PlatformProviders
    private let lifecycleManager: any InboxLifecycleManagerProtocol
    private let sleepingInboxChecker: SleepingInboxMessageChecker

    init(databaseWriter: any DatabaseWriter,
         databaseReader: any DatabaseReader,
         environment: AppEnvironment,
         identityStore: any KeychainIdentityStoreProtocol,
         lifecycleManager: (any InboxLifecycleManagerProtocol)? = nil,
         sleepingInboxChecker: SleepingInboxMessageChecker? = nil,
         platformProviders: PlatformProviders) {
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
        self.environment = environment
        self.identityStore = identityStore
        self.platformProviders = platformProviders
        self.deviceRegistrationManager = DeviceRegistrationManager(
            environment: environment,
            platformProviders: platformProviders
        )
        let resolvedLifecycleManager = lifecycleManager ?? InboxLifecycleManager(
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            identityStore: identityStore,
            environment: environment,
            platformProviders: platformProviders
        )
        self.lifecycleManager = resolvedLifecycleManager
        self.notificationChangeReporter = NotificationChangeReporter(databaseWriter: databaseWriter)

        // Initialize sleeping inbox checker
        let activityRepository = InboxActivityRepository(databaseReader: databaseReader)
        self.sleepingInboxChecker = sleepingInboxChecker ?? SleepingInboxMessageChecker(
            environment: environment,
            activityRepository: activityRepository,
            lifecycleManager: resolvedLifecycleManager,
            appLifecycle: platformProviders.appLifecycle
        )

        observe()

        initializationTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }

            // Register device on app launch
            await self.deviceRegistrationManager.registerDeviceIfNeeded()
            guard !Task.isCancelled else { return }

            // Start observing push token changes for automatic re-registration
            await self.deviceRegistrationManager.startObservingPushTokenChanges()
            guard !Task.isCancelled else { return }

            // Initialize inbox lifecycle manager
            await self.lifecycleManager.initializeOnAppLaunch()

            guard !Task.isCancelled else { return }

            // Start sleeping inbox message checker
            await self.sleepingInboxChecker.startPeriodicChecks()

            guard !Task.isCancelled else { return }
            self.unusedInboxPrepTask = Task(priority: .background) { [weak self] in
                guard let self, !Task.isCancelled else { return }
                await self.lifecycleManager.prepareUnusedInboxIfNeeded()
            }
        }
    }

    deinit {
        initializationTask?.cancel()
        unusedInboxPrepTask?.cancel()
        foregroundObserverTask?.cancel()
        if let leftConversationObserver {
            NotificationCenter.default.removeObserver(leftConversationObserver)
        }
    }

    // MARK: - Private Methods

    private func observe() {
        // Observe foreground notifications to refresh GRDB observers with changes from notification extension
        foregroundObserverTask = Task { [weak self, platformProviders] in
            let foregroundNotifications = NotificationCenter.default.notifications(
                named: platformProviders.appLifecycle.willEnterForegroundNotification
            )
            for await _ in foregroundNotifications {
                guard let self else { return }
                self.notificationChangeReporter.notifyChangesInDatabase()
            }
        }

        // Delete inbox when a conversation is left/exploded
        leftConversationObserver = NotificationCenter.default
            .addObserver(forName: .leftConversationNotification, object: nil, queue: .main) { [weak self] notification in
                guard let self else { return }
                guard let clientId = notification.userInfo?["clientId"] as? String,
                      let inboxId = notification.userInfo?["inboxId"] as? String else {
                    return
                }

                // Delete the inbox (XMTP client and keys)
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await self.deleteInbox(clientId: clientId, inboxId: inboxId)
                        Log.info("Deleted inbox after explosion: \(clientId)")
                    } catch {
                        Log.error("Failed to delete inbox after explosion: \(error.localizedDescription)")
                    }
                }
            }
    }

    // MARK: - Inbox Management

    public func addInbox() async -> AnyMessagingService {
        await lifecycleManager.createNewInbox()
    }

    public func deleteInbox(clientId: String, inboxId: String) async throws {
        // Get or create a service for deletion (creates one if not awake, without tracking it)
        let service = await lifecycleManager.getOrCreateService(clientId: clientId, inboxId: inboxId)
        Log.info("Deleting inbox for clientId: \(clientId)")
        await service.stopAndDelete()

        // Force remove from tracking (don't use sleep() - it may re-add due to pending invites)
        await lifecycleManager.forceRemove(clientId: clientId)

        // Always delete inbox record from database regardless of in-memory service state
        let inboxWriter = InboxWriter(dbWriter: databaseWriter)
        try await inboxWriter.delete(clientId: clientId)
    }

    public func deleteAllInboxes() async throws {
        for try await _ in deleteAllInboxesWithProgress() {}
    }

    public func deleteAllInboxesWithProgress() -> AsyncThrowingStream<InboxDeletionProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                do {
                    // Always clear device registration state, even if deletion fails
                    defer { DeviceRegistrationManager.clearRegistrationState(deviceInfo: self.platformProviders.deviceInfo) }

                    continuation.yield(.clearingDeviceRegistration)

                    // Get all inboxes from database
                    let inboxesRepository = InboxesRepository(databaseReader: self.databaseReader)
                    let allInboxes = try inboxesRepository.allInboxes()

                    let totalInboxes = allInboxes.count
                    var completedInboxes = 0

                    // Delete each inbox with progress reporting
                    await withTaskGroup(of: Void.self) { [lifecycleManager = self.lifecycleManager] group in
                        for inbox in allInboxes {
                            let clientId = inbox.clientId
                            let inboxId = inbox.inboxId
                            group.addTask {
                                let service = await lifecycleManager.getOrCreateService(
                                    clientId: clientId,
                                    inboxId: inboxId
                                )
                                // Start the deletion
                                await service.stopAndDelete()
                                // Wait for the deletion to actually complete
                                await service.waitForDeletionComplete()
                            }
                        }

                        for await _ in group {
                            completedInboxes += 1
                            continuation.yield(.stoppingServices(completed: completedInboxes, total: totalInboxes))
                        }
                    }

                    // Stop all tracking in lifecycle manager
                    await self.lifecycleManager.stopAll()
                    await self.lifecycleManager.clearUnusedInbox()

                    // Delete all from database
                    continuation.yield(.deletingFromDatabase)
                    let inboxWriter = InboxWriter(dbWriter: self.databaseWriter)
                    Log.info("Deleting all inboxes from database")
                    try await inboxWriter.deleteAll()

                    continuation.yield(.completed)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Messaging Services

    public func messagingService(for clientId: String, inboxId: String) async throws -> AnyMessagingService {
        try await lifecycleManager.getOrWake(clientId: clientId, inboxId: inboxId)
    }

    // MARK: - Factory methods for repositories

    public func inviteRepository(for conversationId: String) -> any InviteRepositoryProtocol {
        InviteRepository(
            databaseReader: databaseReader,
            conversationId: conversationId,
            conversationIdPublisher: Just(conversationId).eraseToAnyPublisher()
        )
    }

    public func conversationRepository(for conversationId: String, inboxId: String, clientId: String) async throws -> any ConversationRepositoryProtocol {
        let messagingService = try await messagingService(for: clientId, inboxId: inboxId)
        return ConversationRepository(
            conversationId: conversationId,
            dbReader: databaseReader,
            inboxStateManager: messagingService.inboxStateManager
        )
    }

    public func messagesRepository(for conversationId: String) -> any MessagesRepositoryProtocol {
        MessagesRepository(
            dbReader: databaseReader,
            conversationId: conversationId
        )
    }

    public func photoPreferencesRepository(for conversationId: String) -> any PhotoPreferencesRepositoryProtocol {
        PhotoPreferencesRepository(databaseReader: databaseReader)
    }

    public func photoPreferencesWriter() -> any PhotoPreferencesWriterProtocol {
        PhotoPreferencesWriter(databaseWriter: databaseWriter)
    }

    public func conversationsRepository(for consent: [Consent]) -> any ConversationsRepositoryProtocol {
        ConversationsRepository(dbReader: databaseReader, consent: consent)
    }

    public func conversationsCountRepo(for consent: [Consent], kinds: [ConversationKind]) -> any ConversationsCountRepositoryProtocol {
        ConversationsCountRepository(databaseReader: databaseReader, consent: consent, kinds: kinds)
    }

    public func pinnedConversationsCountRepo() -> any PinnedConversationsCountRepositoryProtocol {
        PinnedConversationsCountRepository(databaseReader: databaseReader)
    }

    // MARK: Notifications

    public func shouldDisplayNotification(for conversationId: String) async -> Bool {
        // Get the currently active client ID (the inbox being viewed)
        let activeClientId = await lifecycleManager.activeClientId

        // If no active client (e.g., on conversations list), show all notifications
        guard let activeClientId else {
            return true
        }

        // Look up the client ID for this conversation
        do {
            let conversationClientId = try await databaseReader.read { db in
                try DBConversation
                    .filter(DBConversation.Columns.id == conversationId)
                    .fetchOne(db)?
                    .clientId
            }

            // Suppress notification if it's for a conversation in the active inbox
            if conversationClientId == activeClientId {
                Log.info("Suppressing notification for conversation in active inbox: \(conversationId)")
                return false
            }
        } catch {
            Log.error("Failed to look up clientId for conversationId \(conversationId): \(error)")
        }

        return true
    }

    public func notifyChangesInDatabase() {
        notificationChangeReporter.notifyChangesInDatabase()
    }

    // MARK: - Lifecycle Management

    public func setActiveClientId(_ clientId: String?) async {
        await lifecycleManager.setActiveClientId(clientId)
        await lifecycleManager.rebalance()
    }

    public func wakeInboxForNotification(clientId: String, inboxId: String) async {
        do {
            // wake() handles eviction automatically when at capacity
            _ = try await lifecycleManager.wake(clientId: clientId, inboxId: inboxId, reason: .pushNotification)
            Log.info("Woke inbox for push notification: \(clientId)")
        } catch {
            Log.error("Failed to wake inbox for notification: \(error)")
        }
    }

    public func wakeInboxForNotification(conversationId: String) async {
        do {
            // Look up clientId and inboxId from the conversation
            guard let (clientId, inboxId) = try await databaseReader.read({ db in
                try DBConversation
                    .filter(DBConversation.Columns.id == conversationId)
                    .fetchOne(db)
                    .map { ($0.clientId, $0.inboxId) }
            }) else {
                Log.warning("Cannot wake inbox for notification: conversation not found for id \(conversationId)")
                return
            }

            // wake() handles eviction automatically when at capacity
            _ = try await lifecycleManager.wake(clientId: clientId, inboxId: inboxId, reason: .pushNotification)
            Log.info("Woke inbox for push notification: clientId=\(clientId), conversationId=\(conversationId)")
        } catch {
            Log.error("Failed to wake inbox for notification (conversationId: \(conversationId)): \(error)")
        }
    }

    public func isInboxAwake(clientId: String) async -> Bool {
        await lifecycleManager.isAwake(clientId: clientId)
    }

    public func isInboxSleeping(clientId: String) async -> Bool {
        await lifecycleManager.isSleeping(clientId: clientId)
    }

    // MARK: Helpers

    public func inboxId(for conversationId: String) async -> String? {
        do {
            return try await databaseReader.read { db in
                try DBConversation
                    .filter(DBConversation.Columns.id == conversationId)
                    .fetchOne(db)?
                    .inboxId
            }
        } catch {
            Log.error("Failed to look up inboxId for conversationId \(conversationId): \(error)")
            return nil
        }
    }
}
