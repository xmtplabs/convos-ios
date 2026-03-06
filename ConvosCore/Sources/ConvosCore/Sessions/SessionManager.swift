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
///
/// @unchecked Sendable: All stored protocol dependencies are Sendable. Mutable state
/// (leftConversationObserver, Tasks) is only modified during init and deinit. The
/// lifecycleManager actor coordinates all inbox state. NotificationCenter observers
/// use weak self and main queue dispatch.
public final class SessionManager: SessionManagerProtocol, @unchecked Sendable {
    private var leftConversationObserver: Any?
    private var vaultImportTask: Task<Void, Never>?
    private var vaultDeleteTask: Task<Void, Never>?
    private var foregroundObserverTask: Task<Void, Never>?
    private var assetRenewalTask: Task<Void, Never>?

    private let databaseWriter: any DatabaseWriter
    public let databaseReader: any DatabaseReader
    private let environment: AppEnvironment
    private let identityStore: any KeychainIdentityStoreProtocol
    private var initializationTask: Task<Void, Never>?
    private var unusedInboxPrepTask: Task<Void, Never>?
    private let deviceRegistrationManager: any DeviceRegistrationManagerProtocol
    private let notificationChangeReporter: any NotificationChangeReporterType
    private let platformProviders: PlatformProviders
    private let lifecycleManager: any InboxLifecycleManagerProtocol
    private let sleepingInboxChecker: SleepingInboxMessageChecker
    private let apiClient: any ConvosAPIClientProtocol
    public let vaultService: (any VaultServiceProtocol)?

    init(databaseWriter: any DatabaseWriter,
         databaseReader: any DatabaseReader,
         environment: AppEnvironment,
         identityStore: any KeychainIdentityStoreProtocol,
         lifecycleManager: (any InboxLifecycleManagerProtocol)? = nil,
         sleepingInboxChecker: SleepingInboxMessageChecker? = nil,
         vaultService: (any VaultServiceProtocol)? = nil,
         platformProviders: PlatformProviders) {
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
        self.environment = environment
        self.identityStore = identityStore
        self.vaultService = vaultService
        self.platformProviders = platformProviders
        self.deviceRegistrationManager = DeviceRegistrationManager(
            environment: environment,
            platformProviders: platformProviders
        )
        self.apiClient = ConvosAPIClientFactory.client(environment: environment)
        let resolvedLifecycleManager = lifecycleManager ?? InboxLifecycleManager(
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            identityStore: identityStore,
            environment: environment,
            platformProviders: platformProviders,
            deviceRegistrationManager: self.deviceRegistrationManager,
            apiClient: self.apiClient
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

            // Bootstrap vault (creates identity + XMTP client if needed)
            if let vaultManager = self.vaultService as? VaultManager {
                await vaultManager.bootstrapVault(
                    databaseWriter: self.databaseWriter,
                    environment: self.environment
                )
            }
            guard !Task.isCancelled else { return }

            // Initialize inbox lifecycle manager
            await self.lifecycleManager.initializeOnAppLaunch()

            guard !Task.isCancelled else { return }

            await self.sleepingInboxChecker.startPeriodicChecks()

            guard !Task.isCancelled else { return }
            self.unusedInboxPrepTask = Task(priority: .background) { [weak self] in
                guard let self, !Task.isCancelled else { return }
                await self.lifecycleManager.prepareUnusedConversationIfNeeded()
            }

            guard !Task.isCancelled else { return }
            self.assetRenewalTask = Task(priority: .utility) { [weak self] in
                guard let self, !Task.isCancelled else { return }
                let recoveryHandler = ExpiredAssetRecoveryHandler(databaseWriter: self.databaseWriter)
                let renewalManager = AssetRenewalManager(
                    databaseWriter: self.databaseWriter,
                    apiClient: self.apiClient,
                    recoveryHandler: recoveryHandler
                )
                await renewalManager.performRenewalIfNeeded()
            }
        }
    }

    deinit {
        initializationTask?.cancel()
        unusedInboxPrepTask?.cancel()
        foregroundObserverTask?.cancel()
        assetRenewalTask?.cancel()
        vaultImportTask?.cancel()
        vaultDeleteTask?.cancel()
        if let leftConversationObserver {
            NotificationCenter.default.removeObserver(leftConversationObserver)
        }
    }

    // MARK: - Private Methods

    private func observe() {
        foregroundObserverTask = Task { [weak self, platformProviders] in
            let foregroundNotifications = NotificationCenter.default.notifications(
                named: platformProviders.appLifecycle.willEnterForegroundNotification
            )
            for await _ in foregroundNotifications {
                guard let self else { return }
                self.notificationChangeReporter.notifyChangesInDatabase()
            }
        }

        observeVaultNotifications()

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
                        Log.debug("Deleted inbox after explosion: \(clientId)")
                    } catch {
                        Log.error("Failed to delete inbox after explosion: \(error.localizedDescription)")
                    }
                }
            }
    }

    // MARK: - Inbox Management

    public func addInbox() async -> (service: AnyMessagingService, conversationId: String?) {
        await lifecycleManager.createNewInbox()
    }

    public func addInboxOnly() async -> AnyMessagingService {
        await lifecycleManager.createNewInboxOnly()
    }

    public func deleteInbox(clientId: String, inboxId: String) async throws {
        try await deleteInboxLocally(clientId: clientId)
        await vaultService?.broadcastConversationDeleted(inboxId: inboxId, clientId: clientId)
    }

    func deleteInboxLocally(clientId: String) async throws {
        let inboxId: String = try await databaseReader.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT inboxId FROM inbox WHERE clientId = ?",
                arguments: [clientId]
            ) ?? ""
        }

        let service = await lifecycleManager.getOrCreateService(clientId: clientId, inboxId: inboxId)
        Log.info("Deleting inbox locally: clientId=\(clientId), inboxId=\(inboxId)")
        await service.stopAndDelete()

        await lifecycleManager.forceRemove(clientId: clientId)

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

                    if let vaultService = self.vaultService {
                        do {
                            try await vaultService.unpairSelf()
                            Log.info("Unpaired from Vault before deleting data")
                        } catch {
                            Log.error("Failed to unpair from Vault: \(error)")
                        }
                    }

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
                    await self.lifecycleManager.clearUnusedConversation()

                    // Delete all from database
                    continuation.yield(.deletingFromDatabase)
                    let inboxWriter = InboxWriter(dbWriter: self.databaseWriter)
                    Log.debug("Deleting all inboxes from database")
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

    public func messagingServiceSync(for clientId: String, inboxId: String) -> AnyMessagingService {
        if let tracked = lifecycleManager.getAwakeService(clientId: clientId) {
            return tracked
        }
        let service = MessagingService.authorizedMessagingService(
            for: inboxId,
            clientId: clientId,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment,
            identityStore: identityStore,
            startsStreamingServices: true,
            platformProviders: platformProviders,
            deviceRegistrationManager: deviceRegistrationManager,
            apiClient: apiClient
        )
        Task { [lifecycleManager] in
            let registered = await lifecycleManager.registerExternalService(service, clientId: clientId)
            if !registered {
                Log.warning("Stopping duplicate MessagingService for \(clientId)")
                await service.stop()
            }
        }
        return service
    }

    // MARK: - Factory methods for repositories

    public func inviteRepository(for conversationId: String) -> any InviteRepositoryProtocol {
        InviteRepository(
            databaseReader: databaseReader,
            conversationId: conversationId,
            conversationIdPublisher: Just(conversationId).eraseToAnyPublisher()
        )
    }

    public func requestAgentJoin(slug: String, instructions: String, forceErrorCode: Int? = nil) async throws -> ConvosAPI.AgentJoinResponse {
        try await apiClient.requestAgentJoin(slug: slug, instructions: instructions, forceErrorCode: forceErrorCode)
    }

    public func redeemInviteCode(_ code: String) async throws {
        try await apiClient.redeemInviteCode(code)
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

    public func attachmentLocalStateWriter() -> any AttachmentLocalStateWriterProtocol {
        AttachmentLocalStateWriter(databaseWriter: databaseWriter)
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
                Log.debug("Suppressing notification for conversation in active inbox: \(conversationId)")
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
            Log.debug("Woke inbox for push notification: \(clientId)")
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
            Log.debug("Woke inbox for push notification: clientId=\(clientId), conversationId=\(conversationId)")
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

    private func observeVaultNotifications() {
        vaultImportTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: .vaultDidImportInbox
            )
            for await notification in notifications {
                guard let self else { return }
                guard let inboxId = notification.userInfo?["inboxId"] as? String,
                      let clientId = notification.userInfo?["clientId"] as? String else {
                    continue
                }
                await self.wakeImportedInbox(inboxId: inboxId, clientId: clientId)
            }
        }

        vaultDeleteTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: .vaultDidDeleteConversation
            )
            for await notification in notifications {
                guard let self else { return }
                guard let clientId = notification.userInfo?["clientId"] as? String else {
                    continue
                }
                do {
                    try await self.deleteInboxLocally(clientId: clientId)
                    Log.info("Deleted conversation from vault sync: clientId=\(clientId)")
                } catch {
                    Log.error("Failed to delete conversation from vault sync: \(error)")
                }
            }
        }
    }

    private func wakeImportedInbox(inboxId: String, clientId: String) async {
        do {
            _ = try await lifecycleManager.wake(clientId: clientId, inboxId: inboxId, reason: .userInteraction)
            Log.info("Woke imported vault inbox: \(inboxId), clientId: \(clientId)")
        } catch {
            Log.error("Failed to wake imported vault inbox \(inboxId): \(error)")
        }
    }

    // MARK: Debug

    public func pendingInviteDetails() throws -> [PendingInviteDetail] {
        let repository = PendingInviteRepository(databaseReader: databaseReader)
        return try repository.allPendingInviteDetails()
    }

    public func deleteExpiredPendingInvites() async throws -> Int {
        let cutoff = Date().addingTimeInterval(-InboxLifecycleManager.stalePendingInviteInterval)

        let expiredInvites: [DBConversation] = try await databaseReader.read { db in
            let sql = """
                SELECT c.*
                FROM conversation c
                WHERE c.id LIKE 'draft-%'
                    AND c.inviteTag IS NOT NULL
                    AND length(c.inviteTag) > 0
                    AND c.createdAt < ?
                    AND (SELECT COUNT(*) FROM conversation_members cm WHERE cm.conversationId = c.id) <= 1
                """
            return try DBConversation.fetchAll(db, sql: sql, arguments: [cutoff])
        }

        guard !expiredInvites.isEmpty else { return 0 }

        let expiredConversationIds = Set(expiredInvites.map { $0.id })
        let expiredClientIds = Set(expiredInvites.map { $0.clientId })

        let clientIdsToKeep: Set<String> = try await databaseReader.read { db in
            let placeholders = expiredClientIds.map { _ in "?" }.joined(separator: ",")
            let expiredIdPlaceholders = expiredConversationIds.map { _ in "?" }.joined(separator: ",")

            let sql = """
                SELECT DISTINCT c.clientId
                FROM conversation c
                WHERE c.clientId IN (\(placeholders))
                    AND (
                        (SELECT COUNT(*) FROM conversation_members cm WHERE cm.conversationId = c.id) > 1
                        OR c.id NOT IN (\(expiredIdPlaceholders))
                    )
                """
            let arguments = StatementArguments(Array(expiredClientIds) + Array(expiredConversationIds))
            return Set(try String.fetchAll(db, sql: sql, arguments: arguments))
        }

        let safeToDeleteClientIds = expiredClientIds.subtracting(clientIdsToKeep)

        let inboxWriter = InboxWriter(dbWriter: databaseWriter)

        for clientId in safeToDeleteClientIds {
            await lifecycleManager.forceRemove(clientId: clientId)

            do {
                let identity = try await identityStore.delete(clientId: clientId)
                Log.debug("Deleted keychain identity for expired invite inbox: \(identity.inboxId)")
            } catch {
                Log.warning("Could not delete keychain identity for clientId \(clientId): \(error)")
            }

            do {
                try await inboxWriter.delete(clientId: clientId)
                Log.debug("Deleted inbox record for expired invite clientId: \(clientId)")
            } catch {
                Log.warning("Could not delete inbox record for clientId \(clientId): \(error)")
            }
        }

        let allExpiredConversationIds = expiredInvites.map { $0.id }

        let deletedCount = try await databaseWriter.write { db in
            try DBConversation
                .filter(allExpiredConversationIds.contains(DBConversation.Columns.id))
                .deleteAll(db)
        }

        if !clientIdsToKeep.isEmpty {
            Log.debug("Kept \(clientIdsToKeep.count) inbox(es) that have other active conversations")
        }

        Log.info("Deleted \(deletedCount) expired pending invite(s), cleaned up \(safeToDeleteClientIds.count) inbox(es)")
        return deletedCount
    }

    public func orphanedInboxDetails() throws -> [OrphanedInboxDetail] {
        let repository = OrphanedInboxRepository(databaseReader: databaseReader)
        return try repository.allOrphanedInboxes()
    }

    public func deleteOrphanedInbox(clientId: String, inboxId: String) async throws {
        await lifecycleManager.forceRemove(clientId: clientId)

        do {
            let identity = try await identityStore.delete(clientId: clientId)
            Log.debug("Deleted keychain identity for orphaned inbox: \(identity.inboxId)")
        } catch {
            Log.warning("Could not delete keychain identity for orphaned clientId \(clientId): \(error)")
        }

        let inboxWriter = InboxWriter(dbWriter: databaseWriter)
        try await inboxWriter.delete(clientId: clientId)

        try await databaseWriter.write { db in
            try DBConversation
                .filter(DBConversation.Columns.clientId == clientId)
                .deleteAll(db)
        }

        Log.info("Deleted orphaned inbox: clientId=\(clientId), inboxId=\(inboxId)")
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

    // MARK: - Asset Renewal

    public func makeAssetRenewalManager() async -> AssetRenewalManager {
        let recoveryHandler = ExpiredAssetRecoveryHandler(databaseWriter: databaseWriter)
        return AssetRenewalManager(
            databaseWriter: databaseWriter,
            apiClient: apiClient,
            recoveryHandler: recoveryHandler
        )
    }
}
