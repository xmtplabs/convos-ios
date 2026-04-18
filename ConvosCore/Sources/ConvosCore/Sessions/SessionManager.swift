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

/// Coordinates the XMTP inbox that backs the app.
///
/// On first access (`addInbox` / `messagingService`) the manager either loads
/// the existing identity from the keychain and authorizes its
/// `MessagingService`, or registers a fresh identity. Subsequent calls return
/// the same service.
///
/// @unchecked Sendable: mutable state is protected by `cachedMessagingService`. Long-lived
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

    /// Single-inbox means a single cached `MessagingService`. The lock
    /// serializes every construction path — any sync or async caller that
    /// hits a cache miss builds the service under this lock, so two
    /// concurrent callers can never spawn two `AuthorizeInboxOperation`s.
    private let cachedMessagingService: OSAllocatedUnfairLock<MessagingService?> = .init(initialState: nil)

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
            identityStore: identityStore
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

        // Leaving a conversation doesn't touch the inbox identity; the
        // observer just logs the event so downstream cleanup can hook in.
        leftConversationObserver = NotificationCenter.default
            .addObserver(forName: .leftConversationNotification, object: nil, queue: .main) { notification in
                let conversationId = notification.userInfo?["conversationId"] as? String
                Log.debug("Left conversation: \(conversationId ?? "unknown")")
            }
    }

    private func prewarmUnusedConversation() async {
        let service = loadOrCreateService()
        await unusedConversationCache.prepareUnusedConversation(
            service: service,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )
    }

    /// Single entry point for the process-wide `MessagingService`. Every
    /// public messaging-service accessor — sync or async, from the main app
    /// or the unused-conversation prewarm — funnels through here. The lock
    /// guarantees exactly one `AuthorizeInboxOperation` for the process:
    /// whichever caller takes it first builds + installs, everyone else
    /// sees the cache hit.
    private func loadOrCreateService() -> MessagingService {
        cachedMessagingService.withLock { cached in
            if let existing = cached {
                return existing
            }
            let identity = try? identityStore.loadSync()
            let service = buildMessagingService(for: identity)
            cached = service
            return service
        }
    }

    /// Build a `MessagingService` for the keychain's current identity, or
    /// register a new one if the keychain is empty. Pure function — no
    /// caching, no mutation outside of what `AuthorizeInboxOperation`'s
    /// state machine does on its own.
    private func buildMessagingService(for identity: KeychainIdentity?) -> MessagingService {
        let op: AuthorizeInboxOperation
        if let identity {
            op = AuthorizeInboxOperation.authorize(
                inboxId: identity.inboxId,
                clientId: identity.clientId,
                identityStore: identityStore,
                databaseReader: databaseReader,
                databaseWriter: databaseWriter,
                environment: environment,
                startsStreamingServices: true,
                platformProviders: platformProviders,
                deviceRegistrationManager: deviceRegistrationManager,
                apiClient: apiClient
            )
        } else {
            op = AuthorizeInboxOperation.register(
                identityStore: identityStore,
                databaseReader: databaseReader,
                databaseWriter: databaseWriter,
                environment: environment,
                platformProviders: platformProviders,
                deviceRegistrationManager: deviceRegistrationManager,
                apiClient: apiClient
            )
        }
        return MessagingService(
            authorizationOperation: op,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            identityStore: identityStore,
            environment: environment,
            backgroundUploadManager: platformProviders.backgroundUploadManager
        )
    }

    // MARK: - Inbox Management

    public func addInbox() async -> (service: AnyMessagingService, conversationId: String?) {
        let service = loadOrCreateService()
        let conversationId = await unusedConversationCache.consumeUnusedConversationId(
            databaseWriter: databaseWriter
        )
        await unusedConversationCache.prepareUnusedConversation(
            service: service,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            environment: environment
        )
        return (service, conversationId)
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

                    let hasService = self.cachedMessagingService.withLock { $0 != nil }
                    continuation.yield(.stoppingServices(completed: 0, total: hasService ? 1 : 0))

                    try await self.tearDownInbox()

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

    private func tearDownInbox() async throws {
        let existing = cachedMessagingService.withLock { cached -> MessagingService? in
            let current = cached
            cached = nil
            return current
        }

        if let existing {
            Log.info("Tearing down authorized inbox")
            await existing.stopAndDelete()
            await existing.waitForDeletionComplete()
        }

        try await identityStore.delete()

        try await wipeResidualInboxRows()
    }

    private func wipeResidualInboxRows() async throws {
        try await databaseWriter.write { db in
            try DBInbox.deleteAll(db)
        }
    }

    // MARK: - Messaging Services

    public func messagingService() -> AnyMessagingService {
        loadOrCreateService()
    }

    public func messagingServiceSync() -> AnyMessagingService {
        loadOrCreateService()
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

    public func conversationRepository(for conversationId: String) -> any ConversationRepositoryProtocol {
        ConversationRepository(
            conversationId: conversationId,
            dbReader: databaseReader,
            sessionStateManager: messagingService().sessionStateManager
        )
    }

    public func messagesRepository(for conversationId: String) -> any MessagesRepositoryProtocol {
        MessagesRepository(
            dbReader: databaseReader,
            conversationId: conversationId,
            currentInboxId: MessagesRepository.currentInboxId(from: databaseReader)
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
        // TODO: suppress notifications when the target conversation is
        // already visible to the user. Safer to over-notify than to swallow.
        true
    }

    public func notifyChangesInDatabase() {
        notificationChangeReporter.notifyChangesInDatabase()
    }

    public func wakeInboxForNotification(conversationId: String) {
        _ = loadOrCreateService()
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

    /// Returns `true` when an inbox is authorized locally but has no joined
    /// conversations and no tagged drafts — a sign of an aborted
    /// registration that can be reset via `deleteAllInboxes`.
    public func isAccountOrphaned() throws -> Bool {
        try databaseReader.read { db in
            guard (try DBInbox.fetchAll(db).first) != nil else { return false }
            let nonDraftCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM conversation WHERE id NOT LIKE 'draft-%'"
            ) ?? 0
            if nonDraftCount > 0 { return false }
            let taggedDraftCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM conversation WHERE id LIKE 'draft-%' AND inviteTag IS NOT NULL AND length(inviteTag) > 0"
            ) ?? 0
            return taggedDraftCount == 0
        }
    }

    // MARK: Helpers

    public func inboxId(for conversationId: String) async -> String? {
        do {
            return try await databaseReader.read { db in
                guard (try DBConversation.fetchOne(db, key: conversationId)) != nil else {
                    return nil
                }
                return try DBInbox.fetchAll(db).first?.inboxId
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
