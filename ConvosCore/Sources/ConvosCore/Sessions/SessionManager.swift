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

    /// In-process counterpart to `RestoreInProgressFlag` (which covers
    /// the NSE via app-group UserDefaults). Set inside the same lock
    /// block as `cachedMessagingService` so a concurrent push
    /// delivery in the main-app process can't race a second XMTP
    /// client against `RestoreManager`'s throwaway client while a
    /// restore is rewriting the shared SQLCipher DB. `loadOrCreateService`
    /// short-circuits to a `RestoreInProgressError` placeholder while
    /// set. See `docs/plans/icloud-backup-single-inbox.md` §"Throwaway
    /// XMTP client for archive import".
    private var isRestoringInProcess: Bool = false

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
            // Restore short-circuit. Building a real service now would
            // open a second SQLCipher pool against the same xmtp-*.db3
            // that `RestoreManager`'s throwaway client holds open.
            // Return (or build-and-cache) a frozen placeholder whose
            // state is `.error(RestoreInProgressError)`. Observers
            // render that as "Restoring…"; next access after
            // `resumeAfterRestore` clears both the flag and the slot,
            // and the real service builds on the following call.
            if isRestoringInProcess {
                if let existing = cached,
                   case let .error(error) = existing.sessionStateManager.currentState,
                   error is RestoreInProgressError {
                    return existing
                }
                let placeholder = MessagingService(
                    identityReadFailure: RestoreInProgressError(),
                    databaseWriter: databaseWriter,
                    databaseReader: databaseReader,
                    identityStore: identityStore,
                    environment: environment,
                    backgroundUploadManager: platformProviders.backgroundUploadManager
                )
                cached = placeholder
                return placeholder
            }

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

    // MARK: - Restore Lifecycle (package-internal, for RestoreManager)

    /// Signal that a restore is about to rewrite the shared GRDB and
    /// the XMTP local DB. Callable only from `RestoreManager`.
    ///
    /// Four things happen atomically from the perspective of anyone
    /// reading the cached service:
    /// 1. `RestoreInProgressFlag` (app-group UserDefaults) is set so
    ///    the NSE bails on incoming pushes.
    /// 2. `isRestoringInProcess` flips to `true` inside the cache
    ///    lock, so the main-app process short-circuits
    ///    `loadOrCreateService()` to a frozen `RestoreInProgressError`
    ///    placeholder for the duration.
    /// 3. The cached `MessagingService` (if any) is stopped — NOT
    ///    deleted; identity + DBInbox rows are preserved.
    /// 4. The in-flight `UnusedConversationCache` prewarm is
    ///    cancelled and awaited.
    ///
    /// Throws if the app-group flag can't be written. `RestoreManager`
    /// must abort the restore before any destructive op on throw — a
    /// silent "flag not set" would let the NSE proceed into a torn
    /// read of the DB being rewritten page-by-page.
    func pauseForRestore() async throws {
        try RestoreInProgressFlag.set(true, environment: environment)

        let existing = cachedMessagingService.withLock { slot -> MessagingService? in
            isRestoringInProcess = true
            return slot
        }

        // Defensive: `cancel()` and `stop()` are non-throwing today,
        // but if either grows a throw site in the future the caller
        // would see a half-paused session (flag set, cache not
        // cleared) with no cleanup. The `Task.checkCancellation()`
        // below also lets a cancelled restore unwind cleanly — the
        // catch re-runs `resumeAfterRestore` so the flags come off
        // before we rethrow.
        do {
            try Task.checkCancellation()
            await unusedConversationCache.cancel()

            if let existing {
                Log.info("pauseForRestore: stopping cached messaging service")
                await existing.stop()
            }

            // Clear the slot only after `stop()` so a concurrent
            // `loadOrCreateService()` sees the being-stopped service
            // (while also observing `isRestoringInProcess` and falling
            // through to the placeholder path). The slot will be
            // repopulated with a `RestoreInProgressError` placeholder on
            // the next call.
            cachedMessagingService.withLock { $0 = nil }
        } catch {
            await resumeAfterRestore()
            throw error
        }

        Log.info("pauseForRestore: session paused")
    }

    /// Counterpart to `pauseForRestore`. Clears the flags and lets
    /// the next `loadOrCreateService()` build the real service
    /// against the restored DB. Never throws — `pauseForRestore`
    /// already committed, and the flag-clear path must complete
    /// even on partial failure.
    func resumeAfterRestore() async {
        cachedMessagingService.withLock { slot in
            isRestoringInProcess = false
            slot = nil
        }

        do {
            try RestoreInProgressFlag.set(false, environment: environment)
        } catch {
            Log.error("resumeAfterRestore: failed to clear app-group flag (\(error)); NSE will see stale 'restoring' until app-group becomes available")
        }

        // Lazy rebuild — next `messagingService()` caller builds the
        // real service against the restored identity + DB. Mirrors
        // `tearDownInbox`'s pattern (nil the slot, don't prewarm);
        // eagerly rebuilding here would swallow keychain-unreadable
        // errors into a silently-errored cached service.
        Log.info("resumeAfterRestore: session resumed")
    }

    private func wipeResidualInboxRows() async throws {
        try await databaseWriter.write { db in
            // A prior process may have left `isUnused == true` rows from an
            // interrupted prewarm. Under a nil cached service the MLS-side
            // `cleanupInboxData` never runs, so those rows would otherwise
            // survive into the next session and hand out unusable conversation
            // ids via `consumeUnusedConversationId`.
            try DBConversation
                .filter(DBConversation.Columns.isUnused == true)
                .deleteAll(db)
            try DBInbox.deleteAll(db)
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
        // Always returns true today. The hook exists so the NSE has a
        // well-defined place to suppress notifications when the target
        // conversation is already on-screen; until that signal is plumbed
        // through, erring on the side of over-notification is safer than
        // silently swallowing a legitimate notification.
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
