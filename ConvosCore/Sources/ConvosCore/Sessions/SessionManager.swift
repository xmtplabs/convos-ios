import Combine
import Foundation
import GRDB
import os

public extension Notification.Name {
    static let leftConversationNotification: Notification.Name = Notification.Name("LeftConversationNotification")
    static let activeConversationChanged: Notification.Name = Notification.Name("ActiveConversationChanged")
}

public typealias AnyMessagingService = any MessagingServiceProtocol
public typealias AnyClientProvider = any XMTPClientProvider

enum SessionManagerError: Error {
    case inboxNotFound
}

/// Coordinates the single XMTP inbox that backs the app.
///
/// Single-inbox refactor (C4): the prior multi-inbox coordinator has been
/// replaced with a lazy singleton. On first access (`addInbox` / `messagingService`)
/// the manager either loads the existing identity from the keychain and
/// authorizes its `MessagingService`, or registers a fresh identity. Subsequent
/// calls return the same service.
///
/// Several protocol methods that took `clientId` / `inboxId` parameters are
/// retained as pass-throughs to keep the UI layer compiling during the
/// intermediate state; the arguments are ignored. The view-model surface is
/// cleaned up in C11.
///
/// @unchecked Sendable: mutable state is protected by `serviceLock`. Long-lived
/// tasks (initialization, foreground observation, asset renewal) are created
/// during init and cancelled in deinit.
public final class SessionManager: SessionManagerProtocol, @unchecked Sendable {
    /// Pending invite drafts older than this are removed during cleanup.
    public static let stalePendingInviteInterval: TimeInterval = 24 * 60 * 60

    private var leftConversationObserver: Any?
    private var foregroundObserverTask: Task<Void, Never>?
    private var assetRenewalTask: Task<Void, Never>?

    private let databaseWriter: any DatabaseWriter
    private let databaseReader: any DatabaseReader
    private let environment: AppEnvironment
    private let identityStore: any KeychainIdentityStoreProtocol
    private var initializationTask: Task<Void, Never>?
    private let voiceMemoTranscriptionServiceLock: NSLock = NSLock()
    private var _voiceMemoTranscriptionService: (any VoiceMemoTranscriptionServicing)?
    private let deviceRegistrationManager: any DeviceRegistrationManagerProtocol
    private let notificationChangeReporter: any NotificationChangeReporterType
    private let platformProviders: PlatformProviders
    private let apiClient: any ConvosAPIClientProtocol
    private let unusedConversationCache: any UnusedConversationCacheProtocol

    private struct ServiceState {
        var messagingService: MessagingService?
        var creationTask: Task<MessagingService, Never>?
    }
    private let serviceState: OSAllocatedUnfairLock<ServiceState> = .init(initialState: ServiceState())

    init(databaseWriter: any DatabaseWriter,
         databaseReader: any DatabaseReader,
         environment: AppEnvironment,
         identityStore: any KeychainIdentityStoreProtocol,
         unusedConversationCache: (any UnusedConversationCacheProtocol)? = nil,
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
        self.apiClient = ConvosAPIClientFactory.client(environment: environment)
        self.unusedConversationCache = unusedConversationCache ?? UnusedConversationCache(
            identityStore: identityStore,
            platformProviders: platformProviders,
            deviceRegistrationManager: self.deviceRegistrationManager,
            apiClient: self.apiClient
        )
        self.notificationChangeReporter = NotificationChangeReporter(databaseWriter: databaseWriter)

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

            await self.prewarmUnusedConversation()

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
        foregroundObserverTask?.cancel()
        assetRenewalTask?.cancel()
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

        // In the single-inbox model the user keeps their inbox when they leave or
        // explode a conversation — destroying it would destroy the entire account.
        // The observer remains for logging and so downstream cleanup (C9 explode
        // rewrite) can hook in without reintroducing the notification contract.
        leftConversationObserver = NotificationCenter.default
            .addObserver(forName: .leftConversationNotification, object: nil, queue: .main) { notification in
                let conversationId = notification.userInfo?["conversationId"] as? String
                Log.debug("Left conversation: \(conversationId ?? "unknown")")
            }
    }

    private func prewarmUnusedConversation() async {
        await unusedConversationCache.prepareUnusedConversationIfNeeded(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )
    }

    private func cachedService() -> MessagingService? {
        serviceState.withLock { $0.messagingService }
    }

    private func loadOrCreateService() async -> MessagingService {
        enum LoadAction {
            case existing(MessagingService)
            case awaiting(Task<MessagingService, Never>)
            case create
        }

        let action: LoadAction = serviceState.withLock { state in
            if let existing = state.messagingService {
                return .existing(existing)
            }
            if let task = state.creationTask {
                return .awaiting(task)
            }
            return .create
        }

        switch action {
        case .existing(let service):
            return service
        case .awaiting(let task):
            return await task.value
        case .create:
            break
        }

        let creationTask = Task<MessagingService, Never> { [weak self] in
            guard let self else {
                fatalError("SessionManager deallocated during service creation")
            }
            return await self.makeService()
        }
        serviceState.withLock { $0.creationTask = creationTask }

        let service = await creationTask.value

        serviceState.withLock { state in
            state.messagingService = service
            state.creationTask = nil
        }

        return service
    }

    private func makeService() async -> MessagingService {
        let (service, _) = await unusedConversationCache.consumeOrCreateMessagingService(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )
        guard let concrete = service as? MessagingService else {
            fatalError("UnusedConversationCache returned unexpected MessagingService type")
        }
        return concrete
    }

    private func makeServiceOnly() async -> MessagingService {
        let service = await unusedConversationCache.consumeInboxOnly(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )
        guard let concrete = service as? MessagingService else {
            fatalError("UnusedConversationCache returned unexpected MessagingService type")
        }
        return concrete
    }

    private func clearCachedService() async {
        let existing = serviceState.withLock { state -> MessagingService? in
            let current = state.messagingService
            state.messagingService = nil
            state.creationTask?.cancel()
            state.creationTask = nil
            return current
        }
        if let existing {
            await existing.stop()
        }
    }

    // MARK: - Inbox Management

    public func addInbox() async -> (service: AnyMessagingService, conversationId: String?) {
        if let cached = cachedService() {
            return (cached, nil)
        }

        let (service, conversationId) = await unusedConversationCache.consumeOrCreateMessagingService(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )
        if let concrete = service as? MessagingService {
            serviceState.withLock { state in
                state.messagingService = concrete
                state.creationTask = nil
            }
        }
        return (service, conversationId)
    }

    public func addInboxOnly() async -> AnyMessagingService {
        if let cached = cachedService() {
            return cached
        }
        let service = await makeServiceOnly()
        serviceState.withLock { state in
            state.messagingService = service
            state.creationTask = nil
        }
        return service
    }

    public func deleteInbox(clientId: String, inboxId: String) async throws {
        try await deleteSingletonInbox()
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
                    defer { DeviceRegistrationManager.clearRegistrationState(deviceInfo: self.platformProviders.deviceInfo) }

                    continuation.yield(.clearingDeviceRegistration)

                    let hasService = self.cachedService() != nil
                    continuation.yield(.stoppingServices(completed: 0, total: hasService ? 1 : 0))

                    try await self.deleteSingletonInbox()

                    if hasService {
                        continuation.yield(.stoppingServices(completed: 1, total: 1))
                    }

                    continuation.yield(.deletingFromDatabase)
                    try await self.wipeResidualInboxRows()

                    continuation.yield(.completed)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func deleteSingletonInbox() async throws {
        let existing = serviceState.withLock { state -> MessagingService? in
            let current = state.messagingService
            state.messagingService = nil
            state.creationTask?.cancel()
            state.creationTask = nil
            return current
        }

        if let existing {
            Log.info("Deleting singleton inbox")
            await existing.stopAndDelete()
            await existing.waitForDeletionComplete()
        }

        try await identityStore.deleteSingleton()

        try await wipeResidualInboxRows()
    }

    private func wipeResidualInboxRows() async throws {
        try await databaseWriter.write { db in
            try DBInbox.deleteAll(db)
        }
    }

    // MARK: - Messaging Services

    public func messagingService(for clientId: String, inboxId: String) async throws -> AnyMessagingService {
        await loadOrCreateService()
    }

    public func messagingServiceSync(for clientId: String, inboxId: String) -> AnyMessagingService {
        if let cached = cachedService() {
            return cached
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
        let resolved: MessagingService = serviceState.withLock { state in
            if let concurrent = state.messagingService {
                return concurrent
            }
            state.messagingService = service
            return service
        }
        if resolved !== service {
            Task { await service.stop() }
        }
        return resolved
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

    public func redeemInviteCode(_ code: String) async throws -> ConvosAPI.InviteCodeStatus {
        try await apiClient.redeemInviteCode(code)
    }

    public func fetchInviteCodeStatus(_ code: String) async throws -> ConvosAPI.InviteCodeStatus {
        try await apiClient.fetchInviteCodeStatus(code)
    }

    public func conversationRepository(for conversationId: String, inboxId: String, clientId: String) async throws -> any ConversationRepositoryProtocol {
        let messagingService = try await messagingService(for: clientId, inboxId: inboxId)
        return ConversationRepository(
            conversationId: conversationId,
            dbReader: databaseReader,
            sessionStateManager: messagingService.sessionStateManager
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

    public func voiceMemoTranscriptRepository() -> any VoiceMemoTranscriptRepositoryProtocol {
        VoiceMemoTranscriptRepository(databaseReader: databaseReader)
    }

    public func voiceMemoTranscriptWriter() -> any VoiceMemoTranscriptWriterProtocol {
        VoiceMemoTranscriptWriter(databaseWriter: databaseWriter)
    }

    public func voiceMemoTranscriptionService() -> any VoiceMemoTranscriptionServicing {
        voiceMemoTranscriptionServiceLock.lock()
        defer { voiceMemoTranscriptionServiceLock.unlock() }
        if let existing = _voiceMemoTranscriptionService {
            return existing
        }
        let service = VoiceMemoTranscriptionService(
            transcriptRepository: voiceMemoTranscriptRepository(),
            transcriptWriter: voiceMemoTranscriptWriter()
        )
        _voiceMemoTranscriptionService = service
        return service
    }

    public func attachmentLocalStateWriter() -> any AttachmentLocalStateWriterProtocol {
        AttachmentLocalStateWriter(databaseWriter: databaseWriter)
    }

    public func assistantFilesLinksRepository(for conversationId: String) -> AssistantFilesLinksRepository {
        AssistantFilesLinksRepository(dbReader: databaseReader, conversationId: conversationId)
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
        // Single-inbox model: conversation-level suppression lands with the view-model
        // rework in C11. For now always show notifications — safer to over-notify than to
        // accidentally swallow one during the intermediate state.
        true
    }

    public func notifyChangesInDatabase() {
        notificationChangeReporter.notifyChangesInDatabase()
    }

    // MARK: - Lifecycle Management

    public func setActiveClientId(_ clientId: String?) async {
        // No-op in single-inbox mode.
    }

    public func wakeInboxForNotification(clientId: String, inboxId: String) async {
        _ = await loadOrCreateService()
    }

    public func wakeInboxForNotification(conversationId: String) async {
        _ = await loadOrCreateService()
    }

    public func isInboxAwake(clientId: String) async -> Bool {
        cachedService() != nil
    }

    public func isInboxSleeping(clientId: String) async -> Bool {
        false
    }

    // MARK: Debug

    public func pendingInviteDetails() throws -> [PendingInviteDetail] {
        let repository = PendingInviteRepository(databaseReader: databaseReader)
        return try repository.allPendingInviteDetails()
    }

    public func deleteExpiredPendingInvites() async throws -> Int {
        let cutoff = Date().addingTimeInterval(-Self.stalePendingInviteInterval)

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

        let expiredConversationIds = expiredInvites.map { $0.id }
        let deletedCount = try await databaseWriter.write { db in
            try DBConversation
                .filter(expiredConversationIds.contains(DBConversation.Columns.id))
                .deleteAll(db)
        }

        Log.info("Deleted \(deletedCount) expired pending invite draft(s)")
        return deletedCount
    }

    public func orphanedInboxDetails() throws -> [OrphanedInboxDetail] {
        let repository = OrphanedInboxRepository(databaseReader: databaseReader)
        return try repository.allOrphanedInboxes()
    }

    public func deleteOrphanedInbox(clientId: String, inboxId: String) async throws {
        // In single-inbox mode the user only ever has one identity — deleting
        // the "orphan" is equivalent to full account reset, which users drive
        // through the dedicated delete-all path. The debug surface is kept so
        // we can audit stale inbox rows left behind by an aborted registration,
        // but the action is now a targeted row delete rather than a keychain
        // destroy.
        try await databaseWriter.write { db in
            try DBInbox
                .filter(DBInbox.Columns.clientId == clientId)
                .deleteAll(db)
            try DBConversation
                .filter(DBConversation.Columns.clientId == clientId)
                .deleteAll(db)
        }
        Log.info("Deleted orphaned inbox row: clientId=\(clientId), inboxId=\(inboxId)")
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
