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
public final class SessionManager: SessionManagerProtocol {
    private var leftConversationObserver: Any?
    private var activeConversationObserver: Any?
    private var foregroundObserverTask: Task<Void, Never>?

    private var activeConversationId: String?
    private let activeConversationQueue: DispatchQueue = DispatchQueue(label: "com.convos.sessionmanager.activeconvo")

    private let databaseWriter: any DatabaseWriter
    private let databaseReader: any DatabaseReader
    private let environment: AppEnvironment
    private let identityStore: any KeychainIdentityStoreProtocol
    private var initializationTask: Task<Void, Never>?
    private var unusedInboxPrepTask: Task<Void, Never>?
    private let deviceRegistrationManager: any DeviceRegistrationManagerProtocol
    private let unusedInboxCache: any UnusedInboxCacheProtocol
    private let notificationChangeReporter: any NotificationChangeReporterType
    private let platformProviders: PlatformProviders
    private let lifecycleManager: any InboxLifecycleManagerProtocol
    private let sleepingInboxChecker: SleepingInboxMessageChecker

    init(databaseWriter: any DatabaseWriter,
         databaseReader: any DatabaseReader,
         environment: AppEnvironment,
         identityStore: any KeychainIdentityStoreProtocol,
         unusedInboxCache: (any UnusedInboxCacheProtocol)? = nil,
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
        self.unusedInboxCache = unusedInboxCache ?? UnusedInboxCache(
            identityStore: identityStore,
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
                await self.unusedInboxCache.prepareUnusedInboxIfNeeded(
                    databaseWriter: self.databaseWriter,
                    databaseReader: self.databaseReader,
                    environment: self.environment
                )
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
        if let activeConversationObserver {
            NotificationCenter.default.removeObserver(activeConversationObserver)
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

        // Clear active conversation when a conversation is left/exploded
        leftConversationObserver = NotificationCenter.default
            .addObserver(forName: .leftConversationNotification, object: nil, queue: .main) { [weak self] notification in
                guard let self else { return }
                guard let conversationId = notification.userInfo?["conversationId"] as? String,
                      let clientId = notification.userInfo?["clientId"] as? String else {
                    return
                }

                // Clear activeConversationId if the left conversation matches the current active one
                self.activeConversationQueue.sync {
                    if self.activeConversationId == conversationId {
                        self.activeConversationId = nil
                        Log.info("Cleared active conversation after explosion/leave: \(conversationId)")
                    }
                }

                // Delete the inbox (XMTP client and keys)
                Task {
                    do {
                        try await self.deleteInbox(clientId: clientId)
                        Log.info("Deleted inbox after explosion: \(clientId)")
                    } catch {
                        Log.error("Failed to delete inbox after explosion: \(error.localizedDescription)")
                    }
                }
            }

        activeConversationObserver = NotificationCenter.default
            .addObserver(forName: .activeConversationChanged, object: nil, queue: .main) { [weak self] notification in
                guard let self else { return }
                let conversationId = notification.userInfo?["conversationId"] as? String
                self.setActiveConversationId(conversationId)
                Log.info("Active conversation changed to: \(conversationId ?? "none")")

                // Rebalance inboxes when active conversation changes
                // This will sleep LRU inboxes while protecting the active conversation's inbox
                Task {
                    let activeClientId = await self.clientId(for: conversationId)
                    await self.lifecycleManager.rebalance(activeClientId: activeClientId)
                }
            }
    }

    private func setActiveConversationId(_ conversationId: String?) {
        activeConversationQueue.sync {
            activeConversationId = conversationId
        }
    }

    // MARK: - Inbox Management

    public func addInbox() async -> AnyMessagingService {
        let messagingService = await unusedInboxCache.consumeOrCreateMessagingService(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )

        // Get the inboxId from the messaging service state
        do {
            let inboxReady = try await messagingService.inboxStateManager.waitForInboxReadyResult()
            let inboxId = inboxReady.client.inboxId
            let clientId = messagingService.clientId

            // Wake it through the lifecycle manager so it's properly tracked
            _ = try await lifecycleManager.wake(clientId: clientId, inboxId: inboxId, reason: .userInteraction)
        } catch {
            Log.error("Failed to register new inbox with lifecycle manager: \(error)")
        }

        return messagingService
    }

    public func deleteInbox(clientId: String) async throws {
        // Get the service from lifecycle manager if awake
        if let service = await lifecycleManager.getService(for: clientId) {
            Log.info("Stopping messaging service for clientId: \(clientId)")
            await service.stopAndDelete()
        } else {
            Log.info("Messaging service not awake for clientId \(clientId), proceeding with DB cleanup")
        }

        // Sleep the inbox first to remove it from tracking
        await lifecycleManager.sleep(clientId: clientId)

        // Always delete from database regardless of in-memory service state
        let inboxWriter = InboxWriter(dbWriter: databaseWriter)
        try await inboxWriter.delete(clientId: clientId)
    }

    public func deleteAllInboxes() async throws {
        // Always clear device registration state, even if deletion fails
        defer { DeviceRegistrationManager.clearRegistrationState(deviceInfo: platformProviders.deviceInfo) }

        // Get all awake services and stop them
        let awakeClientIds = await lifecycleManager.awakeClientIds
        for clientId in awakeClientIds {
            if let service = await lifecycleManager.getService(for: clientId) {
                await service.stopAndDelete()
            }
        }

        // Stop all tracking in lifecycle manager
        await lifecycleManager.stopAll()

        // Delete all from database
        let inboxWriter = InboxWriter(dbWriter: databaseWriter)
        Log.info("Deleting all inboxes from database")
        try await inboxWriter.deleteAll()
    }

    // MARK: - Messaging Services

    public func messagingService(for clientId: String, inboxId: String) async -> AnyMessagingService {
        do {
            return try await lifecycleManager.getOrWake(clientId: clientId, inboxId: inboxId)
        } catch {
            Log.error("Failed to wake inbox \(clientId): \(error), creating fallback service")
            // Fallback: create a service directly if lifecycle manager fails
            return MessagingService.authorizedMessagingService(
                for: inboxId,
                clientId: clientId,
                databaseWriter: databaseWriter,
                databaseReader: databaseReader,
                environment: environment,
                identityStore: identityStore,
                startsStreamingServices: true,
                platformProviders: platformProviders
            )
        }
    }

    // MARK: - Factory methods for repositories

    public func inviteRepository(for conversationId: String) -> any InviteRepositoryProtocol {
        InviteRepository(
            databaseReader: databaseReader,
            conversationId: conversationId,
            conversationIdPublisher: Just(conversationId).eraseToAnyPublisher()
        )
    }

    public func conversationRepository(for conversationId: String, inboxId: String, clientId: String) async -> any ConversationRepositoryProtocol {
        let messagingService = await messagingService(for: clientId, inboxId: inboxId)
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

    public func conversationsRepository(for consent: [Consent]) -> any ConversationsRepositoryProtocol {
        ConversationsRepository(dbReader: databaseReader, consent: consent)
    }

    public func conversationsCountRepo(for consent: [Consent], kinds: [ConversationKind]) -> any ConversationsCountRepositoryProtocol {
        ConversationsCountRepository(databaseReader: databaseReader, consent: consent, kinds: kinds)
    }

    // MARK: Notifications

    public func shouldDisplayNotification(for conversationId: String) async -> Bool {
        let currentActiveConversationId = activeConversationQueue.sync { activeConversationId }

        // Don't display notification if we're in the conversations list
        guard let currentActiveConversationId else {
            Log.info("Suppressing notification from conversations list: \(conversationId)")
            return false
        }

        // Don't display notification if it's for the currently active conversation
        if currentActiveConversationId == conversationId {
            Log.info("Suppressing notification for active conversation: \(conversationId)")
            return false
        }
        return true
    }

    public func notifyChangesInDatabase() {
        notificationChangeReporter.notifyChangesInDatabase()
    }

    // MARK: - Lifecycle Management

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

    private func clientId(for conversationId: String?) async -> String? {
        guard let conversationId else { return nil }
        do {
            return try await databaseReader.read { db in
                try DBConversation
                    .filter(DBConversation.Columns.id == conversationId)
                    .fetchOne(db)?
                    .clientId
            }
        } catch {
            Log.error("Failed to look up clientId for conversationId \(conversationId): \(error)")
            return nil
        }
    }
}
