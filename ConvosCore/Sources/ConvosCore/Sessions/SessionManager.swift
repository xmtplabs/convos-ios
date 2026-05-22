import Combine
import ConvosConnections
import Foundation
import GRDB
import os

public extension Notification.Name {
    static let leftConversationNotification: Notification.Name = Notification.Name("LeftConversationNotification")
    static let activeConversationChanged: Notification.Name = Notification.Name("ActiveConversationChanged")
}

public typealias AnyMessagingService = any MessagingServiceProtocol
public typealias AnyClientProvider = any XMTPClientProvider

/// Coordinates the XMTP inbox that backs the app.
///
/// On first access (`prepareNewConversation` / `messagingService`) the
/// manager either loads the existing identity from the keychain and
/// authorizes its `MessagingService`, or registers a fresh identity.
/// Subsequent calls return the same service.
///
/// @unchecked Sendable: mutable state is protected by `cachedMessagingService`. Long-lived
/// tasks (initialization, foreground observation, asset renewal) are created
/// during init and cancelled in deinit.
public final class SessionManager: SessionManagerProtocol, @unchecked Sendable {
    /// Pending invite drafts older than this are removed during cleanup.
    public static let stalePendingInviteInterval: TimeInterval = 24 * 60 * 60

    private var foregroundObserverTask: Task<Void, Never>?
    private var assetRenewalTask: Task<Void, Never>?
    private var cloudConnectionsCancellable: AnyCancellable?
    private var activeConversationObserver: NSObjectProtocol?
    private var contactBlockingObserver: NSObjectProtocol?
    private var quarantineSweeperTask: Task<Void, Never>?
    private var cachedQuarantineSweeper: (any QuarantineSweeperProtocol)?

    /// Tracks the user's current screen context. Used by
    /// `shouldDisplayNotification(for:)` to suppress in-app banners when they
    /// would be redundant — either because the user is already viewing the
    /// target conversation, or because they're on the list where the new-
    /// message indicator already surfaces the update.
    private let screenStateLock: OSAllocatedUnfairLock<ScreenState> = .init(initialState: ScreenState())

    private struct ScreenState {
        var activeConversationId: String?
        var isOnConversationsList: Bool = false
    }

    let databaseWriter: any DatabaseWriter
    let databaseReader: any DatabaseReader
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

    /// Wall-clock of the last `identityStore.loadSync()` failure, lock-
    /// protected via the same lock as `cachedMessagingService` (both live
    /// inside the same `withLock` block). Used together with
    /// `consecutiveKeychainReadFailures` to short-circuit `loadSync`
    /// reads during a persistent keychain error.
    private var lastKeychainReadFailure: Date?
    private var consecutiveKeychainReadFailures: Int = 0

    /// How long `loadOrCreateService` holds off re-calling
    /// `identityStore.loadSync()` once we've seen two consecutive failures.
    /// The first retry after any failure is always free so transient
    /// errors (locked keychain at first-unlock, iCloud Keychain not yet
    /// synced) recover on the very next accessor call. A second failure
    /// signals "probably persistent" (access-group mismatch, corrupt
    /// data); the backoff then prevents SwiftUI-driven repeat reads from
    /// hammering `securityd` at 60fps. 5s is short enough to pick up a
    /// delayed iCloud sync without noticeable user-facing lag.
    private static let keychainRetryBackoff: TimeInterval = 5

    /// Runtime context for the owning binary. The main app needs the full
    /// session machinery (push-token registration, asset renewal, prewarm,
    /// worker timers); the App Clip just needs to seed the keychain
    /// identity and hand off. The clip context skips the post-init
    /// background work — see `ClipIdentityBootstrap`.
    enum Mode: Sendable {
        case fullApp
        case clipBootstrap
    }

    init(databaseWriter: any DatabaseWriter,
         databaseReader: any DatabaseReader,
         environment: AppEnvironment,
         identityStore: any KeychainIdentityStoreProtocol,
         unusedConversationCache: (any UnusedConversationCacheProtocol)? = nil,
         platformProviders: PlatformProviders,
         mode: Mode = .fullApp) {
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

        guard mode == .fullApp else {
            // Clip bootstrap: skip everything below. The clip writes the
            // keychain identity during its one `messagingService()` call
            // and the main app picks it up via the shared access group —
            // no push token to register (clip lacks the entitlement), no
            // prewarm to do, no renewal to run.
            initializationTask = nil
            return
        }

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

            await self.bootstrapCapabilityProviders()
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
        quarantineSweeperTask?.cancel()
        assetRenewalTask?.cancel()
        cloudConnectionsCancellable?.cancel()
        if let activeConversationObserver {
            NotificationCenter.default.removeObserver(activeConversationObserver)
        }
        if let contactBlockingObserver {
            NotificationCenter.default.removeObserver(contactBlockingObserver)
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
                self.runQuarantineSweep(reason: "foreground")
            }
        }

        activeConversationObserver = NotificationCenter.default.addObserver(
            forName: .activeConversationChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let conversationId = notification.userInfo?["conversationId"] as? String
            self?.updateActiveConversation(conversationId)
        }

        // Trigger an immediate quarantine sweep when a contact gets
        // unblocked (or blocked — though only unblocking has a UX-visible
        // effect on existing held conversations). Without this, the user
        // would have to wait for the next hourly sweep or app-foreground
        // entry before quarantined-by-block conversations reappear in
        // the main feed.
        contactBlockingObserver = NotificationCenter.default.addObserver(
            forName: .contactBlockingDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.runQuarantineSweep(reason: "contactBlockingDidChange")
        }

        scheduleQuarantineSweeper()
    }

    /// Periodic sweeper that promotes quarantined conversations whose
    /// senders have become contacts and deletes those past the TTL. Runs
    /// once at session-observe time and once per `Constant.foregroundSweepInterval`
    /// while the process is alive. The foreground observer above also
    /// triggers an extra sweep on every foreground entry.
    private func scheduleQuarantineSweeper() {
        let sweeper = QuarantineSweeper(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            contactsRepository: ContactsRepository(databaseReader: databaseReader)
        )
        cachedQuarantineSweeper = sweeper

        quarantineSweeperTask?.cancel()
        quarantineSweeperTask = Task { [weak self] in
            // Initial sweep at launch.
            await Self.invokeSweep(sweeper, reason: "launch")
            // Hourly sweep while the process lives. Foreground entries also
            // trigger an extra sweep via the foreground observer.
            while !Task.isCancelled {
                let interval: UInt64 = UInt64(QuarantineSweeper.Constant.foregroundSweepInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: interval)
                guard self != nil, !Task.isCancelled else { return }
                await Self.invokeSweep(sweeper, reason: "interval")
            }
        }
    }

    private func runQuarantineSweep(reason: String) {
        guard let sweeper = cachedQuarantineSweeper else { return }
        Task.detached {
            await Self.invokeSweep(sweeper, reason: reason)
        }
    }

    private static func invokeSweep(
        _ sweeper: any QuarantineSweeperProtocol,
        reason: String
    ) async {
        do {
            try await sweeper.sweep()
        } catch {
            Log.error("QuarantineSweeper sweep (reason=\(reason)) failed: \(error.localizedDescription)")
        }
    }

    private func updateActiveConversation(_ conversationId: String?) {
        screenStateLock.withLock { state in
            state.activeConversationId = (conversationId?.isEmpty == false) ? conversationId : nil
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
    ///
    /// **Cache invariant:** `cached` non-nil means "one service per process",
    /// *not* "the cached service has a usable identity." During the
    /// registering window the service exists but its sessionStateManager
    /// hasn't reached `.ready`; callers needing a ready inbox must
    /// `await waitForInboxReadyResult()`, never read
    /// `currentState.inboxId` directly.
    ///
    /// Identity disposition is strict:
    /// - `loadSync` returns `nil` → keychain confirmed empty, safe to `.register`.
    /// - `loadSync` returns an identity → `.authorize` path.
    /// - `loadSync` throws → keychain is populated-but-unreadable (daemon
    ///   error, corrupt JSON, iCloud sync in flight). Registering on top
    ///   would overwrite a potentially-recoverable identity, so we cache
    ///   a dedicated `FailedIdentityLoadOperation`-backed service that
    ///   reports the real error via `sessionStateManager.currentState`.
    ///   On the next call we retry `loadSync` inside the lock; on success
    ///   the errored cache is replaced by a real service, on continued
    ///   failure the cached errored instance is returned unchanged (no
    ///   fresh allocation, no fresh state machine, no fresh task — this
    ///   fix collapses the pre-refactor thrash where every call rebuilt).
    private func loadOrCreateService() -> MessagingService {
        cachedMessagingService.withLock { cached in
            let previousWasErrored: Bool
            if let existing = cached {
                if case .error = existing.sessionStateManager.currentState {
                    previousWasErrored = true
                } else {
                    return existing
                }
            } else {
                previousWasErrored = false
            }

            // Skip the keychain read entirely if we've seen two or more
            // consecutive failures within the backoff window. First
            // retry after any failure is always free, so transient
            // errors (locked keychain, iCloud Keychain not yet synced)
            // recover on the very next accessor call without waiting
            // out the backoff. Subsequent retries within the window
            // short-circuit to prevent SwiftUI-driven repeat reads
            // from turning a persistent failure into sustained
            // `securityd` IPC traffic.
            if previousWasErrored,
               let existing = cached,
               consecutiveKeychainReadFailures >= 2,
               let lastFailure = lastKeychainReadFailure,
               Date().timeIntervalSince(lastFailure) < Self.keychainRetryBackoff {
                return existing
            }

            let identity: KeychainIdentity?
            do {
                identity = try identityStore.loadSync()
                lastKeychainReadFailure = nil
                consecutiveKeychainReadFailures = 0
            } catch {
                lastKeychainReadFailure = Date()
                consecutiveKeychainReadFailures += 1
                if previousWasErrored, let existing = cached {
                    // Still unhappy; return the frozen errored service we
                    // cached on the previous call. No rebuild thrash.
                    return existing
                }
                Log.error("Keychain identity read failed (\(error)); caching dedicated error-state service until next successful read.")
                let errored = MessagingService(
                    identityReadFailure: error,
                    databaseWriter: databaseWriter,
                    databaseReader: databaseReader,
                    identityStore: identityStore,
                    environment: environment,
                    deviceInfoProvider: platformProviders.deviceInfo,
                    backgroundUploadManager: platformProviders.backgroundUploadManager
                )
                cached = errored
                return errored
            }

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
            deviceInfoProvider: platformProviders.deviceInfo,
            backgroundUploadManager: platformProviders.backgroundUploadManager
        )
    }

    // MARK: - Inbox Management

    public func prepareNewConversation() async -> (service: AnyMessagingService, conversationId: String?) {
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

    public func discardClaimedConversation(id conversationId: String) async {
        guard !DBConversation.isDraft(id: conversationId) else { return }
        do {
            try await databaseWriter.write { db in
                try ConversationLocalState
                    .filter(ConversationLocalState.Columns.conversationId == conversationId)
                    .deleteAll(db)
                try DBMemberProfile
                    .filter(DBMemberProfile.Columns.conversationId == conversationId)
                    .deleteAll(db)
                try DBConversationMember
                    .filter(DBConversationMember.Columns.conversationId == conversationId)
                    .deleteAll(db)
                try DBConversation.deleteOne(db, key: conversationId)
            }
            Log.info("Discarded claimed conversation \(conversationId)")
        } catch {
            Log.error("Failed to discard claimed conversation \(conversationId): \(error)")
        }
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
                    // Yield progress events in lockstep with the work they
                    // describe: the UI reads the stream in order and expects
                    // each event to correspond to the phase that is about to
                    // run (or has just run).
                    continuation.yield(.clearingDeviceRegistration)
                    DeviceRegistrationManager.clearRegistrationState(deviceInfo: self.platformProviders.deviceInfo)

                    let hasService = self.cachedMessagingService.withLock { $0 != nil }
                    continuation.yield(.stoppingServices(completed: 0, total: hasService ? 1 : 0))

                    continuation.yield(.deletingFromDatabase)
                    try await self.tearDownInbox()

                    if hasService {
                        continuation.yield(.stoppingServices(completed: 1, total: 1))
                    }

                    continuation.yield(.completed)
                    continuation.finish()
                } catch {
                    // Still clear device registration on the failure path so
                    // we don't leave a dangling APNs record pointed at a
                    // half-torn-down install.
                    DeviceRegistrationManager.clearRegistrationState(deviceInfo: self.platformProviders.deviceInfo)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func tearDownInbox() async throws {
        await unusedConversationCache.cancel()

        // Keep the cached service reference live through the entire teardown.
        // A concurrent `loadOrCreateService()` (push arriving mid-delete,
        // SwiftUI sync accessor, etc.) will then observe the being-torn-down
        // service rather than building a second one that would open the same
        // SQLCipher xmtp-*.db3 files while the first is being deleted. The
        // cache is cleared only after the XMTP client, keychain, and DBInbox
        // rows are fully gone — at which point any new caller correctly
        // builds a fresh registering-state service.
        let existing = cachedMessagingService.withLock { $0 }

        if let existing {
            Log.info("Tearing down authorized inbox")
            await existing.stopAndDelete()
            await existing.waitForDeletionComplete()
        }

        try await identityStore.delete()

        try await wipeResidualInboxRows()

        cachedMessagingService.withLock { $0 = nil }
    }

    private func wipeResidualInboxRows() async throws {
        try await databaseWriter.write { db in
            // Reached only from "Delete All Data" / delete-all-inboxes, which
            // is a full local account reset rather than a per-conversation
            // cleanup. Some tables intentionally survive conversation deletion
            // during normal app use (for example `contact` uses `setNull` on
            // `addedViaConversationId` so a contact can outlive a single
            // source conversation), so we must explicitly clear those account-
            // scoped tables here as well.
            try DBCloudConnectionGrant.deleteAll(db)
            try DBCloudConnection.deleteAll(db)
            try DBCapabilityResolution.deleteAll(db)
            try DBConversationReadReceipt.deleteAll(db)
            try DBPendingPhotoUpload.deleteAll(db)
            try DBVoiceMemoTranscript.deleteAll(db)
            try AttachmentLocalState.deleteAll(db)
            try DBPhotoPreferences.deleteAll(db)
            try ConversationLocalState.deleteAll(db)
            try DBInvite.deleteAll(db)
            try DBConversationContactsSync.deleteAll(db)
            try DBMessage.deleteAll(db)
            try DBMemberProfile.deleteAll(db)
            try DBConversationMember.deleteAll(db)
            try DBContact.deleteAll(db)
            try DBMember.deleteAll(db)
            try DBConversation.deleteAll(db)
            try DBInbox.deleteAll(db)
            try DBMyProfile.deleteAll(db)
        }
    }

    // MARK: - Messaging Services

    public func messagingService() -> AnyMessagingService {
        loadOrCreateService()
    }

    /// Synchronous accessor for SwiftUI code paths that can't suspend (e.g.
    /// `ConversationsViewModel.updateSelectionState`). Cache hits are free;
    /// cache misses do a keychain `loadSync` plus `AuthorizeInboxOperation`
    /// construction under the service-state lock — typically a few ms, with
    /// worst-case keychain IPC in the tens of ms range. Called once per
    /// process in practice, since the cache fills on first use.
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

    public func requestAgentJoin(
        slug: String,
        templateId: String? = nil,
        options: ConvosAPI.AgentJoinOptions? = nil,
        forceErrorCode: Int? = nil
    ) async throws -> ConvosAPI.AgentJoinResponse {
        try await apiClient.requestAgentJoin(
            slug: slug,
            templateId: templateId,
            options: options,
            forceErrorCode: forceErrorCode
        )
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

    public func agentFilesLinksRepository(for conversationId: String) -> AgentFilesLinksRepository {
        AgentFilesLinksRepository(dbReader: databaseReader, conversationId: conversationId)
    }

    public func agentBuilderSummaryWriter() -> any AgentBuilderSummaryWriterProtocol {
        AgentBuilderSummaryWriter(databaseWriter: databaseWriter)
    }

    public func agentBuilderSummaryRepository() -> any AgentBuilderSummaryRepositoryProtocol {
        AgentBuilderSummaryRepository(databaseReader: databaseReader)
    }

    public func thinkingSessionRepository() -> any ThinkingSessionRepositoryProtocol {
        ThinkingSessionRepository(databaseReader: databaseReader)
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
        let state = screenStateLock.withLock { $0 }
        if state.isOnConversationsList { return false }
        if state.activeConversationId == conversationId { return false }
        return true
    }

    public func setIsOnConversationsList(_ isOn: Bool) {
        screenStateLock.withLock { state in
            state.isOnConversationsList = isOn
        }
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

    // MARK: - Connections

    public func cloudConnectionManager(
        callbackURLScheme: String
    ) -> any CloudConnectionManagerProtocol {
        CloudConnectionManager(
            apiClient: apiClient,
            oauthProvider: platformProviders.oauthSessionProvider,
            databaseWriter: databaseWriter,
            callbackURLScheme: callbackURLScheme,
            grantWriterProvider: { [weak self] in
                self?.messagingService().connectionGrantWriter()
            },
            eventWriterProvider: { [weak self] in
                self?.messagingService().connectionEventWriter()
            },
            resolverProvider: { [weak self] in
                self?.capabilityResolver()
            }
        )
    }

    public func cloudConnectionRepository() -> any CloudConnectionRepositoryProtocol {
        CloudConnectionRepository(databaseReader: databaseReader)
    }

    // MARK: - Capability resolution

    /// Lazily-constructed singleton registry. Multiple subsystems register providers
    /// concurrently (device sinks at boot, cloud OAuth at link/unlink), so we want one
    /// shared registry per session instead of per-callsite copies.
    private let capabilityRegistryLock: OSAllocatedUnfairLock<(any CapabilityProviderRegistry)?> = .init(initialState: nil)
    private let connectionEnablementStoreLock: OSAllocatedUnfairLock<(any EnablementStore)?> = .init(initialState: nil)

    public func capabilityProviderRegistry() -> any CapabilityProviderRegistry {
        capabilityRegistryLock.withLock { registry in
            if let registry { return registry }
            let new: any CapabilityProviderRegistry = InMemoryCapabilityProviderRegistry()
            registry = new
            return new
        }
    }

    public func capabilityResolver() -> any CapabilityResolver {
        GRDBCapabilityResolver(
            database: databaseWriter,
            registry: capabilityProviderRegistry()
        )
    }

    public func capabilityRequestRepository(for conversationId: String) -> any CapabilityRequestRepositoryProtocol {
        CapabilityRequestRepository(dbReader: databaseReader, conversationId: conversationId)
    }

    public func deviceConnectionAuthorizer() -> any DeviceConnectionAuthorizer {
        DefaultDeviceConnectionAuthorizer()
    }

    public func capabilityResolutionsRepository(for conversationId: String) -> any CapabilityResolutionsRepositoryProtocol {
        CapabilityResolutionsRepository(dbReader: databaseReader, conversationId: conversationId)
    }

    public func connectionEnablementStore() -> any EnablementStore {
        connectionEnablementStoreLock.withLock { store in
            if let store { return store }
            let new: any EnablementStore = GRDBEnablementStore(dbWriter: databaseWriter, dbReader: databaseReader)
            store = new
            return new
        }
    }

    /// Registers the default device-provider catalog and starts observing cloud
    /// connections. Device providers report their live OS-authorization state via
    /// the shared `DeviceConnectionAuthorizer`, so the manifest reflects current
    /// permissions on every launch (including kinds the user previously authorized
    /// in another session). Cloud providers are synced reactively from the
    /// `CloudConnection` table — every status flip rebuilds the registry's
    /// `composio.*` entries.
    private func bootstrapCapabilityProviders() async {
        let registry = capabilityProviderRegistry()
        let authorizer = deviceConnectionAuthorizer()
        let supportedDeviceSpecs = DeviceCapabilityProvider.defaultSpecs.filter {
            SupportedConnections.isSupported($0.kind)
        }
        await CapabilityProviderBootstrap.registerDeviceProviders(
            specs: supportedDeviceSpecs,
            registry: registry,
            linkedByUser: { kind in
                { await authorizer.currentAuthorization(for: kind).canDeliverData }
            }
        )

        cloudConnectionsCancellable?.cancel()
        let publisher = cloudConnectionRepository().connectionsPublisher()
        let seedServiceIds = SupportedConnections.supportedCloudServiceIds
        // GRDB's `.immediate` scheduler requires subscription on the main thread.
        await MainActor.run {
            self.cloudConnectionsCancellable = publisher.sink { connections in
                Task { [registry] in
                    await CapabilityProviderBootstrap.syncCloudProviders(
                        connections: connections,
                        seedServiceIds: seedServiceIds,
                        registry: registry
                    )
                }
            }
        }
    }
}
