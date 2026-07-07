import Combine
import ConvosConnections
import ConvosMetrics
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
    /// Launch-time task that builds the messaging service (which starts profile
    /// services). Stored so teardown can cancel it before it can rebuild - and
    /// re-register - an inbox after a `deleteAllInboxes` wipe.
    private var serviceBootstrapTask: Task<Void, Never>?
    /// Task that starts profile services for a freshly built messaging service.
    /// Stored/cancelled for the same reason as `serviceBootstrapTask`: it
    /// re-enters `loadOrCreateService`, which would re-register an inbox on an
    /// empty keychain after teardown if left to fire.
    private var profileServicesTask: Task<Void, Never>?
    private var cloudConnectionsCancellable: AnyCancellable?
    private var activeConversationObserver: NSObjectProtocol?
    private var staleStrangerGCTask: Task<Void, Never>?

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
    private let coreActions: any CoreActions
    private var initializationTask: Task<Void, Never>?
    private let voiceMemoTranscriptionServiceLock: NSLock = NSLock()
    private var _voiceMemoTranscriptionService: (any VoiceMemoTranscriptionServicing)?
    private let deviceRegistrationManager: any DeviceRegistrationManagerProtocol
    private let notificationChangeReporter: any NotificationChangeReporterType
    private let platformProviders: PlatformProviders
    private let apiClient: any ConvosAPIClientProtocol
    private let unusedConversationCache: any UnusedConversationCacheProtocol
    private let agentTemplateRepositoryInstance: any AgentTemplateRepositoryProtocol

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
         mode: Mode = .fullApp,
         coreActions: any CoreActions = NoOpCoreActions()) {
        self.databaseWriter = databaseWriter
        self.databaseReader = databaseReader
        self.environment = environment
        self.identityStore = identityStore
        self.coreActions = coreActions
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
        self.agentTemplateRepositoryInstance = Self.makeAgentTemplateRepository(apiClient: apiClient, databaseWriter: databaseWriter, databaseReader: databaseReader)

        observe()
        wireAgentTemplateRepository()

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

            // Kick off the AgentBuilder grant replayer after the capability
            // providers have bootstrapped — it relies on the cloud-connection
            // and enablement stores being ready to query.
            _ = self.agentBuilderConnectionGrantReplayer()

            // Replay any builder brief whose send a previous process died
            // holding (the agent-join hold can last 150s; see
            // UnsentBuilderBriefReplayer).
            _ = self.unsentBuilderBriefReplayer()

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

            // Ensure the messaging service is built at launch. Building it starts
            // its profile services (backfill + warmUp + bind the publish session)
            // via loadOrCreateService's freshly-built hook, so we don't call
            // startProfileServices here as well - that would double-run backfill.
            // Stored + cancellation-checked so a concurrent teardown cannot let
            // this rebuild (and re-register) an inbox after a delete-all wipe.
            self.serviceBootstrapTask = Task { [weak self] in
                guard let self, !Task.isCancelled else { return }
                _ = self.loadOrCreateService()
            }
        }
    }

    deinit {
        initializationTask?.cancel()
        foregroundObserverTask?.cancel()
        staleStrangerGCTask?.cancel()
        assetRenewalTask?.cancel()
        serviceBootstrapTask?.cancel()
        profileServicesTask?.cancel()
        cloudConnectionsCancellable?.cancel()
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
                self.runStaleStrangerGC(reason: "foreground")
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

        scheduleStaleStrangerGC()
    }

    /// Periodic garbage collector for stranger conversations that have
    /// sat hidden in the main feed (creator never became a contact, so
    /// consent was never promoted past `.unknown`) beyond the retention
    /// window. Runs at launch and once per `staleStrangerGCInterval`
    /// while the process is alive; foreground entries also trigger an
    /// extra run.
    private func scheduleStaleStrangerGC() {
        staleStrangerGCTask?.cancel()
        staleStrangerGCTask = Task { [weak self] in
            await self?.runStaleStrangerGC(reason: "launch")
            while !Task.isCancelled {
                let interval: UInt64 = UInt64(SessionManager.staleStrangerGCInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: interval)
                guard let self, !Task.isCancelled else { return }
                await self.runStaleStrangerGC(reason: "interval")
            }
        }
    }

    private func runStaleStrangerGC(reason: String) {
        Task.detached { [databaseWriter] in
            await SessionManager.deleteStaleStrangerConversations(
                databaseWriter: databaseWriter,
                reason: reason
            )
        }
    }

    /// 7-day hold for stranger conversations before hard delete.
    private static let staleStrangerTTL: TimeInterval = 7 * 24 * 60 * 60
    /// Hourly cadence for the foreground GC loop.
    private static let staleStrangerGCInterval: TimeInterval = 60 * 60

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
        let result: (service: MessagingService, freshlyBuilt: Bool) = cachedMessagingService.withLock { cached in
            let previousWasErrored: Bool
            if let existing = cached {
                if case .error = existing.sessionStateManager.currentState {
                    previousWasErrored = true
                } else {
                    return (existing, false)
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
                return (existing, false)
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
                    return (existing, false)
                }
                Log.error("Keychain identity read failed (\(error)); caching dedicated error-state service until next successful read.")
                let errored = MessagingService(
                    identityReadFailure: error,
                    databaseWriter: databaseWriter,
                    databaseReader: databaseReader,
                    identityStore: identityStore,
                    environment: environment,
                    deviceInfoProvider: platformProviders.deviceInfo,
                    backgroundUploadManager: platformProviders.backgroundUploadManager,
                    coreActions: coreActions
                )
                cached = errored
                return (errored, false)
            }

            let service = buildMessagingService(for: identity)
            cached = service
            return (service, true)
        }
        if result.freshlyBuilt {
            // A freshly built service has an unattached publish session. Start
            // its profile services (backfill + warmUp + bind the publisher) so
            // profile edits actually publish in this app session. Without this,
            // only the one-time launch initialization attaches the session, so a
            // service rebuilt after deleteAllInboxes / refreshAfterPairingCompleted
            // would leave edits enqueued-but-undelivered until the next relaunch.
            // The re-fetch returns the just-cached instance (not freshly built,
            // so it does not re-trigger). startProfileServices self-gates on
            // inbox-ready.
            profileServicesTask?.cancel()
            profileServicesTask = Task { [weak self] in
                guard let self else { return }
                // Cancellation is cooperative: a task cancelled while still
                // queued (e.g. tearDownInbox during delete-all) still enters
                // its closure. Bail before loadOrCreateService, which would
                // otherwise rebuild a service from the just-wiped keychain and
                // re-register a fresh inbox.
                guard !Task.isCancelled else { return }
                await self.loadOrCreateService().startProfileServices()
            }
        }
        return result.service
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
                apiClient: apiClient,
                coreActions: coreActions
            )
        } else {
            op = AuthorizeInboxOperation.register(
                identityStore: identityStore,
                databaseReader: databaseReader,
                databaseWriter: databaseWriter,
                environment: environment,
                platformProviders: platformProviders,
                deviceRegistrationManager: deviceRegistrationManager,
                apiClient: apiClient,
                coreActions: coreActions
            )
        }
        return MessagingService(
            authorizationOperation: op,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            identityStore: identityStore,
            environment: environment,
            deviceInfoProvider: platformProviders.deviceInfo,
            backgroundUploadManager: platformProviders.backgroundUploadManager,
            coreActions: coreActions
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

    public func commitClaimedConversation(id conversationId: String) async {
        await unusedConversationCache.commitClaimedConversation(
            id: conversationId,
            databaseWriter: databaseWriter
        )
    }

    public func releaseClaimedConversation(id conversationId: String) async {
        await unusedConversationCache.releaseClaimedConversationId(conversationId)
    }

    public func registerClaimedConversation(id conversationId: String) async {
        await unusedConversationCache.registerClaimedConversation(id: conversationId)
    }

    public func discardClaimedConversation(id conversationId: String) async {
        await unusedConversationCache.releaseClaimedConversationId(conversationId)
        guard !DBConversation.isDraft(id: conversationId) else { return }

        // Deny consent and leave the XMTP group before the local row goes away
        // so a discarded conversation can't resurface. Cache-claimed
        // conversations are published in `UnusedConversationCache.runPreparation`,
        // so by the time the user discards, the group is live with us as the
        // sole member. `leaveGroup` fails on a solo MLS group ("cannot leave a
        // group that has only one member"), so on its own it leaves the group on
        // the network as allowed; syncs then re-deliver it and the discarded
        // conversation reappears in the chats list on relaunch. Denying consent
        // is the durable, XMTP-synced suppression the chats list filters on (it
        // shows only allowed rows), and it is safe whether or not the group can
        // be left, so it is applied first and unconditionally -- it still lands
        // even when the best-effort `leaveGroup` throws.
        do {
            let inboxReady = try await loadOrCreateService().sessionStateManager.waitForInboxReadyResult()
            if let xmtpConversation = try await inboxReady.client.conversation(with: conversationId) {
                try await xmtpConversation.updateConsentState(state: .denied)
                if case .group(let group) = xmtpConversation {
                    do {
                        try await group.leaveGroup()
                    } catch {
                        Log.error("Failed to leave XMTP group for discarded conversation \(conversationId): \(error). Consent was denied, so it stays filtered out of the chats list.")
                    }
                }
            }
        } catch {
            Log.error("Failed to deny consent for discarded conversation \(conversationId): \(error). The group may remain on the network as allowed.")
        }

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
        // Cancel the launch-time bootstrap and the freshly-built profile-services
        // task first so neither can rebuild - and re-register - an inbox after the
        // wipe below clears the keychain and the cached service.
        serviceBootstrapTask?.cancel()
        serviceBootstrapTask = nil
        profileServicesTask?.cancel()
        profileServicesTask = nil

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
            await existing.stopProfileServices()
            await existing.stopAndDelete()
            await existing.waitForDeletionComplete()
        }

        try await identityStore.delete()

        try await wipeResidualInboxRows()

        cachedMessagingService.withLock { $0 = nil }
    }

    private func wipeResidualInboxRows() async throws {
        try await databaseWriter.write { db in
            try Self.wipeAccountScopedRows(db)
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

    public func agentShareResolver() -> any AgentShareResolving {
        ApiAgentShareResolver(
            apiClient: apiClient,
            databaseReader: databaseReader,
            cacheWriter: AgentTemplateCacheWriter(databaseWriter: databaseWriter)
        )
    }

    public func inviteMembershipResolver() -> any InviteMembershipResolving {
        DatabaseInviteMembershipResolver(databaseReader: databaseReader)
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
            guard try DBInbox.currentInboxId(db) != nil else { return false }
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
                return try DBInbox.currentInboxId(db)
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
    /// Lazily-constructed singleton replayer. Lives for the lifetime of
    /// the session because it owns a long-running `ValueObservation`
    /// stream over `agentBuilderSummary` + member rows. Constructed by
    /// the accessor in `SessionManager+AgentBuilderGrantReplayer.swift`.
    let agentBuilderGrantReplayerLock: OSAllocatedUnfairLock<AgentBuilderConnectionGrantReplayer?> = .init(initialState: nil)

    /// Session-wide unsent-brief replayer (one-shot scan at session start).
    /// Constructed by the accessor in `SessionManager+UnsentBriefReplayer.swift`.
    let unsentBriefReplayerLock: OSAllocatedUnfairLock<UnsentBuilderBriefReplayer?> = .init(initialState: nil)

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
        DefaultDeviceConnectionAuthorizer(
            dataSources: platformProviders.deviceConnections.dataSources
        )
    }

    public func deviceDataSink(for kind: ConnectionKind) -> (any DataSink)? {
        platformProviders.deviceConnections.dataSinks.first(where: { $0.kind == kind })
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

// MARK: - Account reset

extension SessionManager {
    /// Clears every account-scoped table in a full local reset ("Delete All
    /// Data" / delete-all-inboxes). Some tables intentionally survive
    /// conversation deletion during normal app use (for example `contact`
    /// uses `setNull` on `addedViaConversationId` so a contact can outlive a
    /// single source conversation), so a full reset must clear them here.
    ///
    /// Internal (not private) so the clean-slate guarantee can be unit-tested:
    /// a residual row after this runs means a re-paired or different account
    /// inherits stale data.
    static func wipeAccountScopedRows(_ db: Database) throws {
        try DBCloudConnectionGrant.deleteAll(db)
        try DBCloudConnection.deleteAll(db)
        try DBCapabilityResolution.deleteAll(db)
        try DBCreditBalance.deleteAll(db)
        try DBConversationReadReceipt.deleteAll(db)
        // conversation_catchup_cursors rows cascade with the DBConversation
        // deleteAll below (covered by
        // ConversationCatchUpCursorTests.deletingConversationCascades).
        try DBPendingPhotoUpload.deleteAll(db)
        try DBBuilderBundleHiddenMessage.deleteAll(db)
        try DBVoiceMemoTranscript.deleteAll(db)
        try AttachmentLocalState.deleteAll(db)
        try DBPhotoPreferences.deleteAll(db)
        try ConversationLocalState.deleteAll(db)
        try DBInvite.deleteAll(db)
        try DBConversationContactsSync.deleteAll(db)
        try DBAgentTemplate.deleteAll(db)
        try DBMessage.deleteAll(db)
        try DBMemberProfile.deleteAll(db)
        try DBConversationMember.deleteAll(db)
        try DBContact.deleteAll(db)
        try DBMember.deleteAll(db)
        try DBConversation.deleteAll(db)
        try DBInbox.deleteAll(db)
        try DBMyProfile.deleteAll(db)
        // Canonical profile tables. Account-scoped and survive conversation
        // deletion, so a full reset must clear them too; otherwise a re-paired
        // or different account inherits stale identities, avatars, and queued
        // publish jobs.
        try DBProfile.deleteAll(db)
        try DBProfileAvatar.deleteAll(db)
        try DBProfileAvatarSource.deleteAll(db)
        try DBProfilePublishJob.deleteAll(db)
    }
}

// MARK: - Engagement-gated discard

extension SessionManager {
    public func discardClaimedConversationIfUnengaged(id conversationId: String) async {
        guard !DBConversation.isDraft(id: conversationId) else {
            await discardClaimedConversation(id: conversationId)
            return
        }
        let isEngaged: Bool
        do {
            isEngaged = try await databaseReader.read { db in
                try ConversationEngagement.isEngaged(
                    db,
                    conversationId: conversationId,
                    currentInboxId: DBInbox.currentInboxId(db)
                )
            }
        } catch {
            // Destroying user data on a failed read is worse than leaving a
            // row behind, so an engagement check that errors keeps the
            // conversation.
            Log.error("Engagement check failed for \(conversationId), keeping the conversation: \(error)")
            isEngaged = true
        }
        guard isEngaged else {
            await discardClaimedConversation(id: conversationId)
            return
        }
        // The engaged path must never reach the consent-deny in
        // `discardClaimedConversation`: the chats list filters on allowed
        // consent, so deny-then-keep would hide the kept conversation anyway.
        // Committing ensures visibility (idempotent if already committed) and
        // releases the cache claim.
        await commitClaimedConversation(id: conversationId)
        Log.info("Kept engaged claimed conversation \(conversationId) instead of discarding it")
    }
}

// MARK: - Stale-stranger GC

extension SessionManager {
    private static func deleteStaleStrangerConversations(
        databaseWriter: any DatabaseWriter,
        reason: String
    ) async {
        let cutoff: Date = Date().addingTimeInterval(-staleStrangerTTL)
        do {
            let deleted: Int = try await databaseWriter.write { db in
                try deleteStaleStrangerConversations(db: db, cutoff: cutoff)
            }
            if deleted > 0 {
                Log.info("StaleStrangerGC: deleted \(deleted) stranger conversation(s) (reason=\(reason))")
            }
        } catch {
            Log.error("StaleStrangerGC sweep (reason=\(reason)) failed: \(error.localizedDescription)")
        }
    }

    /// Hard-deletes empty stranger conversations (consent `.unknown` with no
    /// local messages) created before `cutoff`. A conversation the user
    /// created, joined, or whose creator became a contact has had its consent
    /// promoted (`.allowed`) or demoted (`.denied`), so anything still
    /// `.unknown` past the window is an unsolicited stranger the user never
    /// engaged with.
    ///
    /// The `NOT EXISTS messages` guard means a stranger conversation that
    /// actually received content is never deleted here - only truly empty
    /// shells are reclaimed. `createdAt` is the XMTP network timestamp, so a
    /// freshly-synced but network-old empty shell is eligible immediately;
    /// gating the grace window on a local-arrival timestamp instead is a
    /// follow-up (the column was dropped with the quarantine machinery).
    ///
    /// Returns the number of rows deleted. `internal` + db/cutoff-injectable
    /// so it can be unit-tested without a clock seam.
    static func deleteStaleStrangerConversations(db: Database, cutoff: Date) throws -> Int {
        let sql: SQL = """
            DELETE FROM conversation
            WHERE createdAt < \(cutoff)
              AND consent = \(Consent.unknown.rawValue)
              AND NOT EXISTS (
                  SELECT 1 FROM message WHERE message.conversationId = conversation.id
              )
            """
        try db.execute(literal: sql)
        return db.changesCount
    }
}

// MARK: - Pairing

public extension SessionManager {
    func joinerPairingService() -> any PairingServiceProtocol {
        LivePairingService(role: .joiner(identityStore: identityStore, environment: environment))
    }

    /// Returns true when the local DB contains at least one `DBConversation`
    /// the user has actually engaged with (`isUnused == false`). Used by
    /// the pairing flow to decide whether the joiner has real data that
    /// would be lost on adoption. Silent identity creation + pre-warmed
    /// unused conversation means every fresh install reports `false` here,
    /// so the destructive-warning sheet stays out of the way.
    func hasAnyUsedConversations() async -> Bool {
        do {
            return try await databaseReader.read { db in
                try DBConversation
                    .filter(DBConversation.Columns.isUnused == false)
                    .fetchCount(db) > 0
            }
        } catch {
            Log.warning("SessionManager.hasAnyUsedConversations failed: \(error)")
            return false
        }
    }

    /// Called after a successful pairing on the joiner side. The paired
    /// secp256k1 key was already saved to the keychain by
    /// `LivePairingService.handleIdentityShare` before this runs. We:
    ///
    /// 1. Stop the placeholder `MessagingService` (the one silent-identity
    ///    bootstrap may have stood up before the deep link arrived).
    /// 2. Delete any pre-existing libxmtp DB files for the *adopted*
    ///    inboxId. See `deleteStaleLibxmtpDatabaseFilesForAdoptedInbox`
    ///    for the file-naming details and the pair-then-re-pair scenario
    ///    that produces the conflict.
    /// 3. Wipe the placeholder's GRDB rows. Without this, the local DB
    ///    still has the placeholder marked as `isCurrentUser` and the
    ///    placeholder's inboxId in `DBInbox`/`DBMember`/`DBMyProfile`.
    ///    History-synced messages from the *paired* identity then come in
    ///    as not-mine and render on the wrong side of the message list.
    /// 4. Clear the cache. Next `messagingService()` call reads the new
    ///    keychain entry and bootstraps a fresh service under the paired
    ///    inboxId.
    ///
    /// Note: we deliberately do NOT call `existing.stopAndDelete()` even
    /// though it has DB-file-deletion logic. The `MessagingService.delete`
    /// path also runs `identityStore.delete()` — and the keychain has
    /// already been overwritten with the freshly-paired identity by
    /// `LivePairingService.handleIdentityShare`. Letting `stopAndDelete`
    /// run would wipe the newly-paired keychain entry. Inline file
    /// deletion keeps the keychain intact.
    func refreshAfterPairingCompleted() async {
        // Mirror `tearDownInbox`'s ordering: keep the cached reference live
        // through stop + wipe so a concurrent `loadOrCreateService()` call
        // observes the being-torn-down service rather than building a second
        // one under the (just-replaced) paired keychain entry.
        let existing = cachedMessagingService.withLock { $0 }
        if let existing {
            Log.info("SessionManager: stopping placeholder messaging service after pairing adoption")
            await existing.stop()
        }
        deleteStaleLibxmtpDatabaseFilesForAdoptedInbox()
        do {
            try await wipeResidualInboxRows()
            Log.info("SessionManager: wiped placeholder GRDB rows after pairing adoption")
        } catch {
            Log.warning("SessionManager: failed to wipe placeholder rows after pairing: \(error)")
        }
        cachedMessagingService.withLock { $0 = nil }
    }

    /// Removes libxmtp's on-disk DB files for the *just-adopted* inboxId
    /// so the paired identity's `Client.create` opens a fresh SQLCipher
    /// store with its own databaseKey.
    ///
    /// File naming and cause of the conflict:
    /// `XMTPiOS.Client.create` builds the alias `xmtp-<env>-<inboxId>.db3`
    /// (see `sdks/ios/Sources/XMTPiOS/Client.swift`) with sidecars
    /// `<alias>-wal`, `<alias>-shm`, and `<alias>.sqlcipher_salt`. Each
    /// inboxId gets its own family. The conflict here is *not* about
    /// "one family per install": it's that the joiner reuses the
    /// **same paired inboxId** across pair attempts (it's the
    /// initiator's). `LivePairingService.handleIdentityShare` generates
    /// a **fresh random databaseKey** on every adoption and overwrites
    /// the keychain. So pair #2 finds pair #1's files at exactly that
    /// per-inbox path, encrypted with the previous key, and SQLCipher
    /// rejects with `PRAGMA key or salt has incorrect value`.
    ///
    /// Targeted deletion only removes the adopted inboxId's family.
    /// The placeholder identity's own files (different inboxId,
    /// different path) are left as cruft until a full "Delete All
    /// Data" sweep — they don't conflict with anything new because the
    /// silent-bootstrap path always generates a fresh inboxId.
    private func deleteStaleLibxmtpDatabaseFilesForAdoptedInbox() {
        let adoptedInboxId: String
        do {
            guard let identity = try identityStore.loadSync() else {
                Log.info("SessionManager: no adopted identity in keychain; skipping libxmtp DB cleanup")
                return
            }
            adoptedInboxId = identity.inboxId
        } catch {
            Log.warning("SessionManager: identityStore.loadSync failed during libxmtp DB cleanup: \(error)")
            return
        }

        let fileManager = FileManager.default
        let dbDirectory = environment.defaultDatabasesDirectoryURL
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dbDirectory,
            includingPropertiesForKeys: nil
        ) else {
            Log.warning("SessionManager: could not enumerate \(dbDirectory.path) for adopted-inbox DB cleanup")
            return
        }

        // Match any file whose name starts with `xmtp-` and contains the
        // adopted inboxId. Covers the current alias form
        // (`xmtp-<env>-<inboxId>.db3`), the legacy form
        // (`xmtp-<env>:443-<inboxId>.db3`) that libxmtp's Swift binding
        // still falls back to, and all four sidecar suffixes (`.db3`,
        // `.db3-wal`, `.db3-shm`, `.db3.sqlcipher_salt`).
        var deletedCount: Int = 0
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix("xmtp-"), name.contains(adoptedInboxId) else { continue }
            do {
                try fileManager.removeItem(at: url)
                deletedCount += 1
            } catch {
                Log.warning("SessionManager: failed to delete stale libxmtp file \(name): \(error)")
            }
        }
        Log.info("SessionManager: removed \(deletedCount) stale libxmtp file(s) for adopted inboxId after pairing adoption")
    }
}

extension SessionManager {
    public func builderBundleHiddenMessagesRepository() -> any BuilderBundleHiddenMessagesRepositoryProtocol {
        BuilderBundleHiddenMessagesRepository(databaseReader: databaseReader)
    }
}

// MARK: - Direct-add agent join

extension SessionManager {
    /// How long to keep polling for the agent's inboxId when registration
    /// outlasts the backend's synchronous wait budget.
    private static var agentRegistrationDeadline: TimeInterval { 30 }
    private static var agentRegistrationPollInterval: TimeInterval { 1 }
    /// Bounded retries of the local member add for an already-provisioned
    /// agent. The add can fail transiently (MLS commit race, key package not
    /// yet propagated to this device, network blip); we retry the *same*
    /// inboxId rather than re-provisioning.
    private static var agentAddMaxAttempts: Int { 3 }
    private static var agentAddRetryDelay: TimeInterval { 1 }

    public func addAgentToConversation(
        conversationId: String,
        templateId: String? = nil,
        options: ConvosAPI.AgentJoinOptions? = nil,
        forceErrorCode: Int? = nil
    ) async throws -> ConvosAPI.AgentJoinResponse {
        // Capture the creator's device timezone on the main actor before any
        // async hop. This seeds the agent's baseline/default zone (Channel A);
        // it is distinct from the per-sender "timezone" ProfileUpdate metadata
        // key published below, which tracks each member's own current device tz.
        let creatorTimezone: String = await MainActor.run { TimeZone.current.identifier }

        // 1. Provision the agent and wait until its XMTP inbox is registered.
        //    Extracted to a helper that touches only the API client (no
        //    messaging service) so the poll loop and its terminal/timeout/
        //    unknown branches are unit-testable — see DirectAddProvisionPollTests.
        let resolved = try await Self.awaitProvisionedAgentInbox(
            requestJoin: {
                try await self.apiClient.requestAgentJoin(
                    slug: nil,
                    conversationId: conversationId.lowercased(),
                    templateId: templateId,
                    options: options,
                    timezone: creatorTimezone,
                    forceErrorCode: forceErrorCode
                )
            },
            fetchStatus: { try await self.apiClient.getAgentJoinStatus(instanceId: $0, variantId: options?.variantId) }
        )
        let instanceId = resolved.instanceId
        let agentInboxId = resolved.inboxId

        // 2. Add: a plain member add by this device — synchronous, no DM
        //    round-trip, no online-accepter dependency. The add durably
        //    publishes a group welcome for the agent's inbox; the runtime
        //    observes it and attaches, so the agent boots even if this app is
        //    killed on the next line.
        //
        //    On failure we retry the add for the *same* inboxId; we never
        //    re-provision here. Re-provisioning would spawn a second instance
        //    (the backend does not dedupe by conversationId) and orphan the
        //    first, risking two agents in one conversation. An add that
        //    exhausts its retries leaves a provisioned-but-unadded instance,
        //    which the runtime reaps on its own attach timeout; we log the
        //    instanceId/inboxId on every failure so it can be correlated.
        var lastError: Error?
        for attempt in 1...Self.agentAddMaxAttempts {
            do {
                try await messagingService().conversationMetadataWriter()
                    .addMembers([agentInboxId], to: conversationId)
                // The conversation now has an agent member. Publish this user's
                // own device timezone into the per-sender ProfileUpdate metadata
                // (Channel B). Best-effort: a failure must not fail the join.
                await publishTimezoneForAgentConversation(conversationId: conversationId)
                return resolved.response
            } catch {
                lastError = error
                Log.error(
                    "Direct-add: addMembers failed (attempt \(attempt)/\(Self.agentAddMaxAttempts)) "
                        + "for agent inbox \(agentInboxId), instance \(instanceId), "
                        + "conversation \(conversationId): \(error.localizedDescription)"
                )
                if attempt < Self.agentAddMaxAttempts {
                    try await Task.sleep(nanoseconds: UInt64(Self.agentAddRetryDelay * 1_000_000_000))
                }
            }
        }
        throw lastError ?? APIError.invalidResponse
    }

    /// Best-effort per-sender timezone publish (agent-timezone Channel B) for a
    /// single conversation. The publisher gates on the conversation actually
    /// containing an agent member, so this is safe to call on any add path.
    private func publishTimezoneForAgentConversation(conversationId: String) async {
        do {
            let publisher = try await messagingService().agentTimezonePublisher()
            await publisher.publishTimezoneIfAgentConversation(conversationId: conversationId)
        } catch {
            Log.warning("Skipped timezone publish for \(conversationId); inbox not ready: \(error.localizedDescription)")
        }
    }

    /// Opportunistic foreground republish of the user's timezone across every
    /// agent conversation (agent-timezone Channel B refresh). Throttled inside
    /// the publisher so a conversation is only republished when the device
    /// timezone changed since the last published value. Best-effort.
    ///
    /// Call only from the foregrounded main app -- never from the Notification
    /// Service Extension or a background task.
    public func republishAgentTimezones() async {
        do {
            let publisher = try await messagingService().agentTimezonePublisher()
            await publisher.republishTimezoneForAgentConversations()
        } catch {
            Log.warning("Skipped agent timezone republish; inbox not ready: \(error.localizedDescription)")
        }
    }

    /// A provisioned agent whose XMTP inbox has registered and is ready to add.
    struct ProvisionedAgent {
        let response: ConvosAPI.AgentJoinResponse
        let instanceId: String
        let inboxId: String
    }

    /// Provisions an agent (`POST /v2/agents/join`) and polls
    /// `GET /v2/agents/join/:instanceId` until its XMTP inbox is registered,
    /// the backend reports a terminal status, or the deadline elapses.
    ///
    /// Touches only the two injected API operations — no messaging service —
    /// so the loop is unit-testable with plain closures, and `now`/`sleep` are
    /// injectable so deadline and poll timing can be driven without real waits.
    ///
    /// `inboxId` presence is the readiness signal: the backend (`pollUntilRegistered`)
    /// populates it only once the agent's identity is registered and key
    /// packages are published, so the caller's subsequent `addMembers` has key
    /// packages to consume. In direct-add the status legitimately stays
    /// `.starting` while the inbox is already present (the agent has not
    /// *joined* yet — that happens after the add), so the inbox check, not the
    /// status, is what ends the wait.
    static func awaitProvisionedAgentInbox(
        deadline: TimeInterval = agentRegistrationDeadline,
        pollInterval: TimeInterval = agentRegistrationPollInterval,
        now: @Sendable () -> Date = { Date() },
        sleep: @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        },
        requestJoin: @Sendable () async throws -> ConvosAPI.AgentJoinResponse,
        fetchStatus: @Sendable (_ instanceId: String) async throws -> ConvosAPI.AgentJoinStatusResponse
    ) async throws -> ProvisionedAgent {
        let response = try await requestJoin()
        guard let instanceId = response.instanceId else {
            throw APIError.agentProvisionFailed
        }

        // Fast path: registration completed within the provision call itself.
        if let inboxId = response.inboxId {
            return ProvisionedAgent(response: response, instanceId: instanceId, inboxId: inboxId)
        }

        let deadlineDate = now().addingTimeInterval(deadline)
        while now() < deadlineDate {
            try await sleep(pollInterval)
            let status = try await fetchStatus(instanceId)

            switch status.provisionStatus {
            case .failed:
                Log.error(
                    "Direct-add: provision failed for instance \(instanceId): "
                        + "\(status.joinFailureReason ?? "no reason given")"
                )
                throw APIError.agentProvisionFailed
            case .noAgentsAvailable:
                Log.error("Direct-add: no agents available for instance \(instanceId)")
                throw APIError.noAgentsAvailable
            case .starting, .joined, .ready, .pendingAcceptance:
                break  // still registering; readiness is signaled by inboxId
            case .unknown(let raw):
                // A status this build doesn't model — not treated as ready or
                // as failure. Logged (so it isn't silently missed) while the
                // deadline bounds the wait.
                Log.warning("Direct-add: unexpected join status \"\(raw)\" for instance \(instanceId)")
            }

            if let inboxId = status.inboxId {
                return ProvisionedAgent(response: response, instanceId: instanceId, inboxId: inboxId)
            }
        }
        Log.error("Direct-add: timed out awaiting agent inbox for instance \(instanceId)")
        throw APIError.agentPoolTimeout
    }
}

// MARK: - Agent-template repository factory

extension SessionManager {
    public func agentTemplateRepository() -> any AgentTemplateRepositoryProtocol {
        agentTemplateRepositoryInstance
    }

    static func makeAgentTemplateRepository(
        apiClient: any ConvosAPIClientProtocol,
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader
    ) -> any AgentTemplateRepositoryProtocol {
        AgentTemplateRepository(
            apiClient: apiClient,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            source: "ios-app",
            // Resolved lazily, at generation-submit time, not here at
            // SessionManager init -- so building a session never forces a
            // `DeviceInfo` read. By the time a generation is submitted the
            // platform layer has configured `DeviceInfo`; if not, the existing
            // fatalError still fires (loudly) at the real point of use.
            clientDeviceIdProvider: { DeviceInfo.deviceIdentifier }
        )
    }

    /// Route the repository's agent-join through the session so the direct-add
    /// provision/add runs, then resume any in-flight generations persisted
    /// across a relaunch.
    func wireAgentTemplateRepository() {
        agentTemplateRepositoryInstance.configureJoinHandler { [weak self] conversationId, templateId, variantId in
            // Throw rather than letting optional chaining return a silent `nil`:
            // the invite step only detects failure via thrown errors, so a
            // no-op `nil` would be recorded as a false `.invited` with no agent
            // actually added.
            guard let self else { throw AgentTemplateJoinError.sessionUnavailable }
            // A nil variantId leaves options nil so default builds stay
            // byte-identical; when set, the same slug carries the join routing
            // and (via options.variantId) the load-bearing join-status poll.
            let options = variantId.map { ConvosAPI.AgentJoinOptions(onboarding: nil, variantId: $0) }
            _ = try await self.addAgentToConversation(conversationId: conversationId, templateId: templateId, options: options)
        }
        agentTemplateRepositoryInstance.resumePendingGenerations()
    }
}
