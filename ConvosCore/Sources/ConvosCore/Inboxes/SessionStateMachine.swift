import ConvosConnectionsXMTP
import ConvosInvites
import Foundation
import GRDB
import os
@preconcurrency import XMTPiOS

enum SessionStateError: Error {
    case inboxNotReady
    case clientIdInboxInconsistency
    case alreadyRegistered(inboxId: String, clientId: String)
}

public struct InboxReadyResult: @unchecked Sendable {
    public let client: any XMTPClientProvider
    public let apiClient: any ConvosAPIClientProtocol

    /// InboxReadyResult is marked @unchecked Sendable because:
    /// - XMTPClientProvider wraps XMTPiOS.Client which is not Sendable
    /// - ConvosAPIClient is marked @unchecked Sendable
    public init(client: any XMTPClientProvider, apiClient: any ConvosAPIClientProtocol) {
        self.client = client
        self.apiClient = apiClient
    }
}

typealias AnySyncingManager = (any SyncingManagerProtocol)
typealias AnyInviteJoinRequestsManager = (any InviteJoinRequestsManagerProtocol)

/// `.onDisk` routes through libxmtp's persistent SQLCipher path (production
/// behavior). `.inMemory` routes through `Client.createInMemory`, where
/// `dropLocalDatabaseConnection` and friends are no-ops — so the lifecycle-
/// notification broadcast cannot wedge a parallel test's pool.
struct XMTPClientFactory: Sendable {
    typealias Create = @Sendable (SigningKey, ClientOptions) async throws -> any XMTPClientProvider
    typealias Build = @Sendable (String, PublicIdentity, SigningKey, ClientOptions) async throws -> any XMTPClientProvider

    let create: Create
    let build: Build

    static let onDisk: XMTPClientFactory = XMTPClientFactory(
        create: { signingKey, options in
            try await Client.create(account: signingKey, options: options)
        },
        build: { inboxId, identity, _, options in
            try await Client.build(publicIdentity: identity, options: options, inboxId: inboxId)
        }
    )

    /// `build` reuses `createInMemory` because tests carry no on-disk history;
    /// inboxId derives from signing key, preserving the
    /// `client.inboxId == identity.inboxId` invariant in `authorize`.
    static let inMemory: XMTPClientFactory = {
        let createInMemory: Create = { signingKey, options in
            try await Client.createInMemory(account: signingKey, options: options)
        }
        return XMTPClientFactory(
            create: createInMemory,
            build: { _, _, signingKey, options in
                try await createInMemory(signingKey, options)
            }
        )
    }()
}

// swiftlint:disable type_body_length

/// Drives the XMTP inbox lifecycle: creating or loading a client,
/// authenticating with the Convos backend, starting sync, registering for
/// push, and handing back `ready` to observers. Also implements
/// `SessionStateManagerProtocol` so callers can read state synchronously.
public actor SessionStateMachine: SessionStateManagerProtocol {
    /// @unchecked Sendable: Most cases contain only Sendable values. Cases
    /// with `XMTPClientProvider` / `InboxReadyResult` wrap thread-safe XMTP
    /// types designed for async/await use.
    enum Action: @unchecked Sendable {
        case authorize(inboxId: String),
             register,
             clientAuthorized(any XMTPClientProvider),
             clientRegistered(any XMTPClientProvider),
             authorized(InboxReadyResult),
             enterBackground,
             enterForeground,
             delete,
             stop
    }

    public enum State: Sendable {
        case idle
        case authorizing(inboxId: String)
        case registering
        case authenticatingBackend(inboxId: String)
        case ready(InboxReadyResult)
        case backgrounded(InboxReadyResult)
        case deleting(inboxId: String?)
        case error(any Error)
    }

    // MARK: -

    private let identityStore: any KeychainIdentityStoreProtocol
    private let invitesRepository: any InvitesRepositoryProtocol
    private let environment: AppEnvironment
    private let syncingManager: AnySyncingManager?
    private let overrideJWTToken: String?
    private let databaseWriter: any DatabaseWriter
    private let apiClient: any ConvosAPIClientProtocol
    private let networkMonitor: any NetworkMonitorProtocol
    private let appLifecycle: any AppLifecycleProviding
    private let xmtpClientFactory: XMTPClientFactory

    private var currentTask: Task<Void, Never>?
    private var actionQueue: [Action] = []
    private var isProcessing: Bool = false
    private var networkMonitorTask: Task<Void, Never>?
    private var appLifecycleTask: Task<Void, Never>?
    /// Observer handle for `installationWasRevokedByPeer`, set when the
    /// session enters `.ready`. The notification is posted by
    /// `StreamProcessor` when a `DeviceRemovedContent` self-DM lands.
    private nonisolated(unsafe) var revocationObserver: (any NSObjectProtocol)?
    private var foregroundRetryCount: Int = 0
    private static let maxForegroundRetries: Int = 2

    // MARK: - Nonisolated State Cache (SessionStateManagerProtocol)

    private nonisolated let _stateCache: OSAllocatedUnfairLock<State>

    public nonisolated var currentState: State {
        _stateCache.withLock { $0 }
    }

    private func updateStateCache(_ newState: State) {
        _stateCache.withLock { $0 = newState }
    }

    // MARK: - Observer Pattern (SessionStateManagerProtocol)

    private struct WeakObserver: Sendable {
        weak var observer: SessionStateObserver?
    }

    private nonisolated let _observers: OSAllocatedUnfairLock<[WeakObserver]> = .init(initialState: [])

    public nonisolated func addObserver(_ observer: SessionStateObserver) {
        _observers.withLock { observers in
            observers.removeAll { $0.observer == nil }
            observers.append(WeakObserver(observer: observer))
        }
        observer.sessionStateDidChange(currentState)
    }

    public nonisolated func removeObserver(_ observer: SessionStateObserver) {
        _observers.withLock { observers in
            observers.removeAll { $0.observer === observer || $0.observer == nil }
        }
    }

    private nonisolated func notifyObservers(_ state: State) {
        let snapshot = _observers.withLock { observers in
            observers.compactMap { $0.observer }
        }
        for observer in snapshot {
            observer.sessionStateDidChange(state)
        }
        _observers.withLock { observers in
            observers.removeAll { $0.observer == nil }
        }
    }

    public nonisolated func observeState(
        _ handler: @escaping (SessionStateMachine.State) -> Void
    ) -> StateObserverHandle {
        let observer = ClosureStateObserver(handler: handler)
        addObserver(observer)
        return StateObserverHandle(observer: observer, manager: self)
    }

    // MARK: - State Observation (AsyncStream)

    private struct IdentifiedContinuation {
        let id: UUID
        let continuation: AsyncStream<State>.Continuation
    }

    private var stateContinuations: [IdentifiedContinuation] = []
    let initialClientId: String
    private var _state: State

    var state: State {
        get async {
            _state
        }
    }

    public var isSyncReady: Bool {
        get async {
            guard let syncingManager else { return false }
            return await syncingManager.isSyncReady
        }
    }

    var stateSequence: AsyncStream<State> {
        let id = UUID()
        return AsyncStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.addStateContinuation(continuation, id: id)
            }
        }
    }

    private func addStateContinuation(_ continuation: AsyncStream<State>.Continuation, id: UUID) {
        let identified = IdentifiedContinuation(id: id, continuation: continuation)
        stateContinuations.append(identified)
        continuation.onTermination = { [weak self, id] _ in
            Task { [weak self] in
                await self?.removeStateContinuation(id: id)
            }
        }
        continuation.yield(_state)
    }

    private func emitStateChange(_ newState: State) {
        _state = newState
        updateStateCache(newState)
        notifyObservers(newState)

        // Emit to all continuations, removing any that fail
        stateContinuations = stateContinuations.filter { identified in
            let result = identified.continuation.yield(newState)
            switch result {
            case .terminated, .dropped:
                return false
            case .enqueued:
                return true
            @unknown default:
                return true
            }
        }
    }

    private func removeStateContinuation(id: UUID) {
        stateContinuations.removeAll { $0.id == id }
    }

    private func cleanupContinuations() {
        for identified in stateContinuations {
            identified.continuation.finish()
        }
        stateContinuations.removeAll()
    }

    // MARK: - Init

    init(
        clientId: String,
        identityStore: any KeychainIdentityStoreProtocol,
        invitesRepository: any InvitesRepositoryProtocol,
        databaseWriter: any DatabaseWriter,
        syncingManager: AnySyncingManager?,
        networkMonitor: any NetworkMonitorProtocol,
        overrideJWTToken: String? = nil,
        environment: AppEnvironment,
        appLifecycle: any AppLifecycleProviding,
        apiClient: (any ConvosAPIClientProtocol)? = nil,
        xmtpClientFactory: XMTPClientFactory = .onDisk
    ) {
        let initialState: State = .idle
        self.initialClientId = clientId
        self._state = initialState
        self._stateCache = OSAllocatedUnfairLock(initialState: initialState)
        self.identityStore = identityStore
        self.invitesRepository = invitesRepository
        self.databaseWriter = databaseWriter
        self.syncingManager = syncingManager
        self.networkMonitor = networkMonitor
        self.overrideJWTToken = overrideJWTToken ?? environment.defaultOverrideJWTToken
        self.environment = environment
        self.appLifecycle = appLifecycle
        self.xmtpClientFactory = xmtpClientFactory

        // Use provided API client or create a new one
        if let apiClient {
            Log.debug("Using shared API client")
            self.apiClient = apiClient
        } else {
            Log.debug("Initializing API client (JWT override: \(self.overrideJWTToken != nil))...")
            self.apiClient = ConvosAPIClientFactory.client(
                environment: environment,
                overrideJWTToken: self.overrideJWTToken
            )
        }

        // Set custom XMTP host if provided
        Log.info("XMTP Configuration:")

        // @lourou: Enable XMTP v4 d14n when ready
        // if let gatewayUrl = environment.gatewayUrl {
        //     // XMTP d14n - using gateway
        //     Log.info("   Mode = XMTP d14n")
        //     Log.info("   GATEWAY_URL = \(gatewayUrl)")
        //     // Clear any previous custom address when using gateway
        //     if XMTPEnvironment.customLocalAddress != nil {
        //         Log.info("   Clearing previous customLocalAddress for gateway mode")
        //         XMTPEnvironment.customLocalAddress = nil
        //     }
        // }

        // XMTP v3
        Log.debug("   Mode = XMTP v3")
        Log.debug("   XMTP_CUSTOM_HOST = \(environment.xmtpEndpoint ?? "nil")")
        Log.debug("   customLocalAddress = \(environment.customLocalAddress ?? "nil")")
        Log.debug("   xmtpEnv = \(environment.xmtpEnv)")

        // Log the actual XMTPEnvironment.customLocalAddress after setting
        if let customHost = environment.customLocalAddress {
            Log.debug("Setting XMTPEnvironment.customLocalAddress = \(customHost)")
            XMTPEnvironment.customLocalAddress = customHost
            Log.debug("Actual XMTPEnvironment.customLocalAddress = \(XMTPEnvironment.customLocalAddress ?? "nil")")
        } else {
            Log.debug("Using default XMTP endpoints")
        }
    }

    // MARK: - Public

    func authorize(inboxId: String) {
        enqueueAction(.authorize(inboxId: inboxId))
    }

    func register() {
        enqueueAction(.register)
    }

    func stop() {
        enqueueAction(.stop)
    }

    func stopAndDelete() {
        enqueueAction(.delete)
    }

    /// Wait for the deletion process to complete.
    /// Returns when the state machine reaches `.idle` (success) or `.error`
    /// (deletion failed but the session machine will not make further progress).
    public func waitForDeletionComplete() async {
        for await state in stateSequence {
            switch state {
            case .idle:
                return
            case .error:
                return
            default:
                continue
            }
        }
    }

    public func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) async {
        guard let syncingManager else { return }
        await syncingManager.setInviteJoinErrorHandler(handler)
    }

    public func setTypingIndicatorHandler(_ handler: @escaping @Sendable (String, String, Bool) -> Void) async {
        guard let syncingManager else { return }
        await syncingManager.setTypingIndicatorHandler(handler)
    }

    public func requestDiscovery() async {
        guard let syncingManager else { return }
        await syncingManager.requestDiscovery()
    }

    public func startAgentJoinRequestPolling() async {
        guard let syncingManager else { return }
        await syncingManager.startAgentJoinRequestPolling()
    }

    // MARK: - SessionStateManagerProtocol

    public func waitForInboxReadyResult() async throws -> InboxReadyResult {
        for await state in stateSequence {
            switch state {
            case .ready(let result),
                 .backgrounded(let result):
                return result
            case .error(let error):
                throw error
            default:
                continue
            }
        }
        throw SessionStateError.inboxNotReady
    }

    // MARK: - Private

    private func enqueueAction(_ action: Action) {
        actionQueue.append(action)
        processNextAction()
    }

    private func processNextAction() {
        guard !isProcessing, !actionQueue.isEmpty else { return }

        // Cancel any existing task before starting a new one
        currentTask?.cancel()

        isProcessing = true
        let action = actionQueue.removeFirst()

        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.processAction(action)
            await self.setProcessingComplete()
        }
    }

    private func setProcessingComplete() {
        isProcessing = false
        processNextAction()
    }

    private func processAction(_ action: Action) async {
        do {
            try await dispatchTransition(for: action)
        } catch {
            await handleTransitionError(error, during: action)
        }
    }

    /// The state-machine transition table. Each `(state, action)` pair is a
    /// one-line dispatch into a dedicated handler so the table reads as the
    /// state diagram it represents. Error classification lives in the caller
    /// (`processAction`) so this stays pure dispatch.
    private func dispatchTransition(for action: Action) async throws {
        switch (_state, action) {
        case let (.idle, .authorize(inboxId)):
            try await handleAuthorize(inboxId: inboxId)
        case let (.error, .authorize(inboxId)):
            try await handleStop()
            try await handleAuthorize(inboxId: inboxId)

        case (.idle, .register):
            try await handleRegister()
        case (.error, .register):
            try await handleStop()
            try await handleRegister()

        case (.authorizing, let .clientAuthorized(client)):
            try await handleClientAuthorized(client: client)
        case (.registering, let .clientRegistered(client)):
            try await handleClientRegistered(client: client)

        case (.authenticatingBackend, let .authorized(result)):
            try await handleAuthorized(result: result)

        case (.ready, .delete),
             (.backgrounded, .delete),
             (.error, .delete),
             (.idle, .delete),
             (.authorizing, .delete),
             (.registering, .delete),
             (.authenticatingBackend, .delete):
            try await handleDelete()
        case (.deleting, .delete):
            Log.debug("Duplicate delete request while already deleting, ignoring")

        case let (.ready(result), .enterBackground):
            try await handleEnterBackground(result: result)
        case let (.backgrounded(result), .enterForeground):
            try await handleEnterForeground(result: result)
        case (.error, .enterForeground):
            try await handleRetryFromError()

        case (.ready, .stop),
             (.error, .stop),
             (.deleting, .stop),
             (.backgrounded, .stop):
            try await handleStop()
        case (.idle, .stop):
            break

        // Lifecycle events that don't map to a real transition from the
        // current state — logged at debug, not warned, since it's normal
        // for foreground/background to fire while we're mid-transition.
        case (_, .enterBackground), (_, .enterForeground):
            Log.debug("Ignoring lifecycle event for transition: \(_state) -> \(action)")

        default:
            Log.warning("Invalid state transition: \(_state) -> \(action)")
        }
    }

    private func handleTransitionError(_ error: Error, during action: Action) async {
        if error is CancellationError {
            Log.debug("Action cancelled: \(action)")
            return
        }
        await stopNetworkMonitoring()
        Log.error("Failed state transition \(_state) -> \(action): \(error.localizedDescription)")
        emitStateChange(.error(error))
    }

    private func handleAuthorize(inboxId: String) async throws {
        try Task.checkCancellation()

        guard let identity = try await identityStore.load() else {
            throw KeychainIdentityStoreError.identityNotFound("No identity in keychain")
        }
        guard identity.inboxId == inboxId else {
            throw KeychainIdentityStoreError.identityNotFound("Singleton inboxId mismatch: expected \(inboxId), got \(identity.inboxId)")
        }

        try Task.checkCancellation()

        guard identity.clientId == initialClientId else {
            throw KeychainIdentityStoreError.identityNotFound("ClientId mismatch: expected \(initialClientId), got \(identity.clientId)")
        }

        // Installs that registered before the synced backup slot existed
        // only ever wrote the primary slot; mirror the identity here so
        // they become recoverable too. Best-effort, no-op once populated.
        await identityStore.backfillSyncedBackupIfNeeded()

        emitStateChange(.authorizing(inboxId: inboxId))
        Log.info("Started authorization flow for inbox: \(inboxId), clientId: \(initialClientId)")

        // Set custom local address before building/creating client.
        // Only updates if different, avoiding unnecessary mutations.
        setCustomLocalAddress()

        let keys = identity.keys
        let clientOptions = clientOptions(keys: keys)
        let client: any XMTPClientProvider
        do {
            try Task.checkCancellation()
            client = try await buildXmtpClient(
                inboxId: identity.inboxId,
                identity: keys.signingKey.identity,
                signingKey: keys.signingKey,
                options: clientOptions
            )
        } catch {
            try Task.checkCancellation()
            Log.info("Error building client, trying create...")
            client = try await createXmtpClient(
                signingKey: keys.signingKey,
                options: clientOptions
            )
            guard client.inboxId == identity.inboxId else {
                Log.error("Created client with mis-matched inboxId")
                throw SessionStateError.clientIdInboxInconsistency
            }
        }

        try Task.checkCancellation()

        // Ensure inbox is saved to database when authorizing in case it was
        // previously registered as unused but is now being used.
        let inboxWriter = InboxWriter(dbWriter: databaseWriter)
        try await inboxWriter.save(inboxId: client.inboxId, clientId: identity.clientId)
        Log.info("Saved inbox to database: \(client.inboxId)")

        enqueueAction(.clientAuthorized(client))
    }

    private func handleRegister() async throws {
        try Task.checkCancellation()

        // Under single-inbox, registration is only valid from an empty
        // keychain slot. The pre-refactor rollback-snapshot path existed
        // to handle identity swaps mid-process — impossible in the new
        // model. Fail fast if the slot is populated: a successful register
        // would overwrite a potentially-recoverable identity, and a
        // failed one plus rollback would leave the backend half-
        // registered against the new clientId anyway.
        if let existing = try? await identityStore.load() {
            Log.error("handleRegister called with a populated keychain (inboxId \(existing.inboxId)); refusing to overwrite. Caller should have taken the .authorize branch.")
            throw SessionStateError.alreadyRegistered(inboxId: existing.inboxId, clientId: existing.clientId)
        }

        emitStateChange(.registering)
        Log.info("Started registration flow with clientId: \(initialClientId)")

        // Set custom local address before creating client.
        // Only updates if different, avoiding unnecessary mutations.
        setCustomLocalAddress()

        try Task.checkCancellation()

        let keys = try await identityStore.generateKeys()

        try Task.checkCancellation()

        let client = try await createXmtpClient(
            signingKey: keys.signingKey,
            options: clientOptions(keys: keys)
        )

        try Task.checkCancellation()

        Log.info("Generated clientId: \(initialClientId) for inboxId: \(client.inboxId)")

        _ = try await identityStore.save(inboxId: client.inboxId, clientId: initialClientId, keys: keys)

        try Task.checkCancellation()

        do {
            let inboxWriter = InboxWriter(dbWriter: databaseWriter)
            try await inboxWriter.save(inboxId: client.inboxId, clientId: initialClientId)
            Log.info("Saved inbox to database with clientId: \(initialClientId)")
        } catch {
            // Keychain was empty at entry (guard above), so rollback is
            // unambiguous: delete the identity we just wrote.
            Log.error("Failed to save inbox to database, rolling back keychain: \(error)")
            try? await identityStore.delete()
            throw error
        }

        enqueueAction(.clientRegistered(client))
    }

    private func handleClientAuthorized(client: any XMTPClientProvider) async throws {
        try Task.checkCancellation()

        emitStateChange(.authenticatingBackend(inboxId: client.inboxId))

        Log.info("Authenticating with backend...")
        try await authenticateBackend()

        try Task.checkCancellation()

        try await assertInstallationActive(client: client)

        enqueueAction(.authorized(.init(client: client, apiClient: apiClient)))
    }

    private func handleClientRegistered(client: any XMTPClientProvider) async throws {
        try Task.checkCancellation()

        emitStateChange(.authenticatingBackend(inboxId: client.inboxId))
        Log.info("Authenticating with backend...")
        try await authenticateBackend()

        try Task.checkCancellation()

        enqueueAction(.authorized(.init(client: client, apiClient: apiClient)))
    }

    private func handleAuthorized(result: InboxReadyResult) async throws {
        // Drain the backlog in batched form before streams start. Same
        // motivation as `handleEnterForeground` — on cold start the
        // network may have a large backlog (NSE didn't run, or the app
        // was killed for a long time) and per-event stream catch-up
        // would N-times the writes / observer fires / SwiftUI renders.
        // The cursor is the same `lastWelcomeProcessed` UserDefaults
        // value the NSE writes, so even cold start respects whatever the
        // NSE has already processed in the background.
        await runBatchCatchUp(client: result.client)

        await syncingManager?.start(with: result.client, apiClient: result.apiClient)
        foregroundRetryCount = 0
        emitStateChange(.ready(result))
        await startNetworkMonitoring()
        startAppLifecycleObservation()
        startRevocationObserver()
        // .inactive is a transient state during launch (scene activating) and
        // routine interruptions (control center, notifications). Only treat
        // .background as a real background launch — otherwise we drop the
        // libxmtp DB pool here, never receive a willEnterForeground (the OS
        // doesn't post it on a fresh launch), and every worker spins on
        // PoolNeedsConnection until the next process restart.
        if await appLifecycle.currentState == .background {
            enqueueAction(.enterBackground)
        }
    }

    /// Single entry point for `.delete` across every state. Pulls a live
    /// client + apiClient from `.ready`/`.backgrounded` when present; otherwise
    /// resolves the inbox id from the DB for telemetry and falls through to
    /// a manual cleanup that doesn't need the XMTP SDK.
    private func handleDelete() async throws {
        try Task.checkCancellation()

        Log.info("Deleting inbox with clientId: \(initialClientId)...")
        defer { enqueueAction(.stop) }

        let liveContext: (client: any XMTPClientProvider, apiClient: any ConvosAPIClientProtocol)?
        switch _state {
        case .ready(let result), .backgrounded(let result):
            liveContext = (result.client, result.apiClient)
        default:
            liveContext = nil
        }

        let inboxId: String?
        if let liveContext {
            inboxId = liveContext.client.inboxId
        } else {
            let clientId = initialClientId
            inboxId = try? await databaseWriter.read { db in
                try DBInbox
                    .filter(DBInbox.Columns.clientId == clientId)
                    .fetchOne(db)?
                    .inboxId
            }
            if inboxId == nil {
                Log.warning("Could not resolve inboxId for clientId \(clientId) - database files will not be cleaned up")
            }
        }

        emitStateChange(.deleting(inboxId: inboxId))

        stopAppLifecycleObservation()
        await stopNetworkMonitoring()
        await syncingManager?.stop()

        try Task.checkCancellation()

        if let liveContext {
            try await performInboxCleanup(client: liveContext.client, apiClient: liveContext.apiClient)
            return
        }

        // Swallow cleanup failures so identity + file teardown still runs.
        // Otherwise a mid-cleanup throw jumps to `.error` and the encrypted
        // xmtp-*.db3 files survive user-facing "Delete All Data".
        do {
            try await cleanupInboxData()
        } catch {
            Log.error("Failed to clean up inbox data for clientId \(initialClientId): \(error). Continuing with identity + file teardown.")
        }

        try Task.checkCancellation()

        // Identity deletion is idempotent — safe to retry if a previous attempt failed partway through.
        let priorIdentity = try? await identityStore.load()
        try? await identityStore.delete()
        if let priorIdentity, priorIdentity.clientId == initialClientId {
            Log.debug("Deleted identity from keychain for clientId: \(initialClientId)")
            deleteDatabaseFiles()
        } else if inboxId != nil {
            Log.debug("Identity absent or not matching clientId: \(initialClientId), continuing cleanup")
            deleteDatabaseFiles()
        }

        Log.info("Deleted inbox with clientId \(initialClientId)")
    }

    private func handleStop() async throws {
        Log.info("Stopping inbox with clientId \(initialClientId)...")
        stopRevocationObserver()

        let clientToClose: (any XMTPClientProvider)?
        switch _state {
        case .ready(let result), .backgrounded(let result):
            clientToClose = result.client
        default:
            clientToClose = nil
        }

        stopAppLifecycleObservation()
        await stopNetworkMonitoring()

        // Stop sync before dropping database connection to prevent in-flight operations from failing.
        await syncingManager?.stop()

        // Drop database connection after sync is stopped; this releases SQLCipher connections in LibXMTP.
        if let client = clientToClose {
            do {
                try client.dropLocalDatabaseConnection()
                Log.debug("Dropped local database connection for \(initialClientId)")
            } catch {
                Log.error("Failed to drop database connection for \(initialClientId): \(error)")
            }
        }

        emitStateChange(.idle)

        cleanupContinuations()
    }

    private func handleEnterBackground(result: InboxReadyResult) async throws {
        Log.info("App entering background, pausing sync for clientId \(initialClientId)...")

        await stopNetworkMonitoring()
        stopRevocationObserver()
        await syncingManager?.pause()

        try result.client.dropLocalDatabaseConnection()

        emitStateChange(.backgrounded(result))
        Log.info("Inbox backgrounded successfully")
    }

    private func handleEnterForeground(result: InboxReadyResult) async throws {
        Log.info("App entering foreground, resuming sync for clientId \(initialClientId)...")

        try await result.client.reconnectLocalDatabase()

        do {
            try await assertInstallationActive(client: result.client)
        } catch {
            try? result.client.dropLocalDatabaseConnection()
            throw error
        }

        // Drain the backlog in batched form before streams resume.
        await runBatchCatchUp(client: result.client)

        await startNetworkMonitoring()
        await syncingManager?.resume()

        emitStateChange(.ready(result))
        startRevocationObserver()
        Log.info("Inbox returned to ready state")
    }

    /// Probes the XMTP network for whether this device's installation is
    /// still in the inbox's active set. Throws `DeviceReplacedError`
    /// (terminal) if it isn't — typically meaning another paired device
    /// revoked us from its `Devices` screen.
    private func assertInstallationActive(client: any XMTPClientProvider) async throws {
        if await XMTPInstallationStateChecker.isInstallationActive(
            inboxId: client.inboxId,
            installationId: client.installationId,
            environment: environment
        ) {
            return
        }
        Log.warning("SessionStateMachine: installation \(client.installationId) not in active set — DeviceReplacedError")
        throw DeviceReplacedError()
    }

    /// Observes `installationWasRevokedByPeer` (posted by `StreamProcessor`
    /// when a `DeviceRemovedContent` self-DM arrives whose
    /// `revokedInstallationId` matches this client). On match, transitions
    /// the session to `.error(DeviceReplacedError)` — the same terminal
    /// state the bootstrap / foreground checks land in. This replaces a
    /// periodic XMTP-API poll with an event-driven path that's effectively
    /// real-time as long as the device is online and streaming.
    private func startRevocationObserver() {
        stopRevocationObserver()
        revocationObserver = NotificationCenter.default.addObserver(
            forName: .installationWasRevokedByPeer,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { [weak self] in
                await self?.emitTerminalError(DeviceReplacedError())
            }
        }
    }

    private func stopRevocationObserver() {
        if let revocationObserver {
            NotificationCenter.default.removeObserver(revocationObserver)
        }
        revocationObserver = nil
    }

    private func emitTerminalError(_ error: any Error) {
        emitStateChange(.error(error))
    }

    /// Drain the backlog of activity since the last catch-up frontier, in
    /// batched form, before streams start or resume. Called from both
    /// `handleAuthorized` (cold start) and `handleEnterForeground`
    /// (foreground after background). Cursor is the same
    /// `lastWelcomeProcessed` UserDefaults value the NSE writes after
    /// each push-driven catch-up, so foreground/cold-start and NSE all
    /// share the same frontier without double-processing.
    ///
    /// `nonisolated` so the non-Sendable `XMTPClientProvider` doesn't
    /// cross the actor's isolation boundary on the way to
    /// `syncingManager.runBatchCatchUp` (also nonisolated for the same
    /// reason). `syncingManager` is captured locally so we don't need
    /// to hop the actor for it either.
    private nonisolated func runBatchCatchUp(client: any XMTPClientProvider) async {
        let inboxId = client.inboxId
        let cursor = Self.readLastCatchUpCursor(for: inboxId)
        Log.info("[catchup] running batch since=\(cursor.map { "\($0)" } ?? "nil") for inbox=\(inboxId.prefix(8))")
        // Don't advance the cursor unless we actually invoked the batch.
        // `syncingManager` is nil when `AuthorizeInboxOperation` is configured
        // with `startsStreamingServices: false` — silently advancing the
        // cursor in that case would mark missed activity as "processed" and
        // permanently skip it on the next foreground.
        guard let syncingManager else {
            Log.warning("[catchup] syncingManager nil, skipping batch (cursor unchanged)")
            return
        }
        await syncingManager.runBatchCatchUp(client: client, since: cursor)
        Self.writeLastCatchUpCursor(Date(), for: inboxId)
    }

    /// Persisted catch-up cursor shared with `MessagingService+PushNotifications`.
    /// Same UserDefaults key — foreground, cold start, and NSE all update
    /// it as they drain backlog, converging on the same frontier.
    private static let catchUpCursorKeyPrefix: String = "convos.pushNotifications.lastWelcomeProcessed"

    private static func readLastCatchUpCursor(for inboxId: String) -> Date? {
        UserDefaults.standard.object(forKey: "\(catchUpCursorKeyPrefix).\(inboxId)") as? Date
    }

    private static func writeLastCatchUpCursor(_ date: Date?, for inboxId: String) {
        UserDefaults.standard.set(date, forKey: "\(catchUpCursorKeyPrefix).\(inboxId)")
    }

    private func handleRetryFromError() async throws {
        try Task.checkCancellation()

        // Terminal errors (e.g. `DeviceReplacedError`) cannot be cured by
        // foreground retries — the only resolution is the user resetting
        // the device. The observer layer (`StaleDeviceBanner`) handles
        // that surface. Bail before the retry counter advances so a
        // coincidence (transient refresh, race) doesn't accidentally
        // land us back in `.ready` without the user ever seeing the
        // banner.
        if case let .error(error) = _state, error is TerminalSessionError {
            Log.info("Not retrying terminal error: \(type(of: error))")
            return
        }

        guard foregroundRetryCount < Self.maxForegroundRetries else {
            Log.warning("Max foreground retries (\(Self.maxForegroundRetries)) reached, not retrying")
            return
        }

        guard let identity = try await identityStore.load(), identity.clientId == initialClientId else {
            Log.warning("Cannot retry from error: no identity matching clientId \(initialClientId)")
            return
        }

        foregroundRetryCount += 1
        Log.info("Retrying authorization for inbox \(identity.inboxId) after foregrounding (attempt \(foregroundRetryCount)/\(Self.maxForegroundRetries))")
        try await handleStop()
        try await handleAuthorize(inboxId: identity.inboxId)
    }

    /// Performs common cleanup operations when deleting an inbox with a live client.
    private func performInboxCleanup(
        client: any XMTPClientProvider,
        apiClient: any ConvosAPIClientProtocol
    ) async throws {
        try Task.checkCancellation()

        // Unsubscribe from inbox-level welcome topic and unregister installation from backend
        // Note: Conversation topics are handled by ConversationStateMachine.cleanUp()
        let welcomeTopic = client.installationId.xmtpWelcomeTopicFormat

        do {
            try await apiClient.unsubscribeFromTopics(clientId: initialClientId, topics: [welcomeTopic])
            Log.debug("Unsubscribed from welcome topic: \(welcomeTopic)")
        } catch {
            Log.error("Failed to unsubscribe from welcome topic: \(error)")
        }

        try Task.checkCancellation()

        do {
            try await apiClient.unregisterInstallation(clientId: initialClientId)
            Log.debug("Unregistered installation from backend: \(initialClientId)")
        } catch {
            // Auth may be invalid during account deletion; treat as non-fatal.
            Log.debug("Could not unregister installation (likely during account deletion): \(error)")
        }

        try Task.checkCancellation()

        try await cleanupInboxData()

        try Task.checkCancellation()

        // Identity deletion is idempotent — safe to retry if a previous attempt failed partway through.
        try? await identityStore.delete()
        Log.debug("Deleted identity from keychain (clientId: \(initialClientId))")

        try Task.checkCancellation()

        // Try SDK method first, fall back to manual file deletion if it fails.
        do {
            try client.deleteLocalDatabase()
            Log.debug("Deleted XMTP local database via SDK for inbox: \(client.inboxId)")
        } catch {
            Log.warning("SDK deleteLocalDatabase failed, attempting manual file deletion: \(error)")
            deleteDatabaseFiles()
        }

        Log.info("Deleted inbox \(client.inboxId) with clientId \(initialClientId)")
    }

    private func deleteDatabaseFiles() {
        let fileManager = FileManager.default
        let dbDirectory = environment.defaultDatabasesDirectoryURL

        // XMTPiOS names its SQLite files `xmtp-<gRPC-host>-<hash>.db3`
        // (e.g. `xmtp-grpc.dev.xmtp.network-abc123.db3`) — earlier code
        // looked for an `xmtp-<env>-<inboxId>` pattern the SDK never
        // produces, so explicit per-inbox deletion silently no-opped.
        // Under single-inbox there's one `xmtp-*.db3` family per install,
        // so removing every `xmtp-*` file in the directory is the correct
        // scope.
        guard let entries = try? fileManager.contentsOfDirectory(
            at: dbDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for url in entries where url.lastPathComponent.hasPrefix("xmtp-") {
            do {
                try fileManager.removeItem(at: url)
                Log.debug("Deleted XMTP database file: \(url.lastPathComponent)")
            } catch {
                Log.error("Failed to delete XMTP database file \(url.lastPathComponent): \(error)")
            }
        }
    }

    private func cleanupInboxData() async throws {
        try Task.checkCancellation()

        let clientId = initialClientId
        Log.info("Cleaning up all data for inbox clientId: \(clientId)")

        // Reached only via `SessionManager.deleteAllInboxes` — a full
        // account reset, so every conversation row goes with the inbox.
        let attachmentKeys: [String] = try await databaseWriter.write { db in
            let conversationIds = try DBConversation.fetchAll(db).map { $0.id }
            Log.info("Found \(conversationIds.count) conversations to clean up for inbox clientId: \(clientId)")

            var allAttachmentKeys: [String] = []
            for conversationId in conversationIds {
                let messages = try DBMessage
                    .filter(DBMessage.Columns.conversationId == conversationId)
                    .fetchAll(db)
                for message in messages {
                    allAttachmentKeys.append(contentsOf: message.attachmentUrls)
                }

                try DBMessage.filter(DBMessage.Columns.conversationId == conversationId).deleteAll(db)
                try DBConversationMember.filter(DBConversationMember.Columns.conversationId == conversationId).deleteAll(db)
                try ConversationLocalState.filter(ConversationLocalState.Columns.conversationId == conversationId).deleteAll(db)
                try DBInvite.filter(DBInvite.Columns.conversationId == conversationId).deleteAll(db)
                try DBMemberProfile.filter(DBMemberProfile.Columns.conversationId == conversationId).deleteAll(db)
            }

            if let inboxId = try DBInbox.filter(DBInbox.Columns.clientId == clientId).fetchOne(db)?.inboxId {
                try DBMember.filter(DBMember.Columns.inboxId == inboxId).deleteAll(db)
            }

            try DBConversation.deleteAll(db)
            try DBInbox.filter(DBInbox.Columns.clientId == clientId).deleteAll(db)

            Log.info("Successfully cleaned up all data for inbox clientId: \(clientId)")
            return allAttachmentKeys
        }

        if !attachmentKeys.isEmpty {
            Log.info("Removing \(attachmentKeys.count) persistent photo(s) for inbox clientId: \(clientId)")
            ImageCacheContainer.shared.removePersistentImages(for: attachmentKeys)
        }
    }

    // MARK: - Helpers

    private func clientOptions(keys: any XMTPClientKeys) -> ClientOptions {
        // @lourou: Enable XMTP v4 d14n when ready
        // When gatewayUrl is provided, we're using d14n
        // The gateway handles env automatically, so we don't set it
        // if let gatewayUrl = environment.gatewayUrl, !gatewayUrl.isEmpty {
        //     // d14n mode: gateway handles network selection
        //     Log.info("Using XMTP d14n - Gateway: \(gatewayUrl)")
        //     apiOptions = .init(
        //         appVersion: "convos/\(Bundle.appVersion)",
        //         gatewayUrl: gatewayUrl
        //     )
        // }

        // Direct XMTP v3 connection: we specify env. TLS is conveyed via the
        // http:// or https:// scheme on customLocalAddress when overriding the
        // default endpoint.
        Log.debug("Using direct XMTP connection with env: \(environment.xmtpEnv)")
        let apiOptions: ClientOptions.Api = .init(
            env: environment.xmtpEnv,
            appVersion: "convos/\(Bundle.appVersion)"
        )

        // Device sync (XMTP history server) is enabled so the identity
        // carries its group memberships and message history across devices signed
        // in to the same Apple ID. `useDefaultHistorySyncUrl: true` (the default
        // on `ClientOptions.init`) resolves the per-environment URL via
        // `XMTPEnvironment.getHistorySyncUrl()`:
        //   .production → message-history.production.ephemera.network
        //   .dev        → message-history.dev.ephemera.network
        //   .local      → localhost:5558 (overridable via
        //                 `XMTPEnvironment.customHistorySyncUrl` or the
        //                 `XMTP_HISTORY_SERVER_ADDRESS` env var)
        return ClientOptions(
            api: apiOptions,
            codecs: [
                TextCodec(),
                ReplyCodec(),
                ReactionV2Codec(),
                ReactionCodec(),
                AttachmentCodec(),
                RemoteAttachmentCodec(),
                MultiRemoteAttachmentCodec(),
                GroupUpdatedCodec(),
                ExplodeSettingsCodec(),
                InviteJoinErrorCodec(),
                InviteJoinHandledCodec(),
                ProfileUpdateCodec(),
                ProfileSnapshotCodec(),
                JoinRequestCodec(),
                AgentJoinRequestCodec(),
                CloudConnectionGrantRequestCodec(),
                ConnectionEventCodec(),
                CapabilityRequestCodec(),
                CapabilityRequestResultCodec(),
                TypingIndicatorCodec(),
                ReadReceiptCodec(),
                PairingMessageCodec(),
                PairingJoinRequestCodec(),
                IdentityShareCodec(),
                DeviceRemovedCodec(),
                ThinkingCodec(),
                BuilderBundleManifestCodec()
            ] + ConvosConnectionsXMTP.codecs(),
            dbEncryptionKey: keys.databaseKey,
            dbDirectory: environment.defaultDatabasesDirectory,
            deviceSyncEnabled: true,
            dbPoolOptions: DbPoolOptions(maxPoolSize: 10, minPoolSize: 3)
        )
    }

    /// Sets XMTPEnvironment.customLocalAddress from current environment
    /// Must be called before building/creating XMTP client
    private func setCustomLocalAddress() {
        if let customHost = environment.customLocalAddress {
            Log.debug("Setting XMTPEnvironment.customLocalAddress = \(customHost)")
            XMTPEnvironment.customLocalAddress = customHost
        } else {
            Log.debug("Clearing XMTPEnvironment.customLocalAddress")
            XMTPEnvironment.customLocalAddress = nil
        }
    }

    private func createXmtpClient(signingKey: SigningKey,
                                  options: ClientOptions) async throws -> any XMTPClientProvider {
        Log.info("Creating XMTP client...")
        let client = try await xmtpClientFactory.create(signingKey, options)
        Log.info("XMTP Client created with app version: convos/\(Bundle.appVersion)")
        return client
    }

    private func buildXmtpClient(inboxId: String,
                                 identity: PublicIdentity,
                                 signingKey: SigningKey,
                                 options: ClientOptions) async throws -> any XMTPClientProvider {
        Log.debug("Building XMTP client for \(inboxId)...")
        let client = try await xmtpClientFactory.build(inboxId, identity, signingKey, options)
        Log.debug("XMTP Client built.")
        return client
    }

    private static let backendAuthMaxRetries: Int = 3
    private static let backendAuthBaseDelay: UInt64 = 2_000_000_000

    private func authenticateBackend() async throws {
        try Task.checkCancellation()

        guard overrideJWTToken == nil, !environment.isTestingEnvironment else {
            Log.info("JWT override mode: skipping authentication, will use JWT from push payload")
            return
        }

        var lastError: (any Error)?
        for attempt in 0..<Self.backendAuthMaxRetries {
            try Task.checkCancellation()

            if attempt > 0 {
                let connected = await networkMonitor.isConnected
                if !connected {
                    Log.info("Backend auth: waiting for network before retry \(attempt + 1)...")
                    await waitForNetworkConnected()
                }
                let delay = Self.backendAuthBaseDelay * UInt64(1 << min(attempt - 1, 2))
                try await Task.sleep(nanoseconds: delay)
                Log.info("Backend auth: retry \(attempt + 1)/\(Self.backendAuthMaxRetries)...")
            }

            do {
                try Task.checkCancellation()

                Log.debug("Getting Firebase AppCheck token...")
                let appCheckToken = try await FirebaseHelperCore.getAppCheckToken()

                try Task.checkCancellation()

                // Default path: SIWE auth. Loads the on-device identity,
                // signs an EIP-4361 message with its Ethereum private key,
                // exchanges for a JWT containing `accountId`. Registering
                // the signing context with the API client BEFORE the call
                // is what makes the 401 re-auth path and every subsequent
                // authenticated request use the SIWE slot — without this
                // the API client would silently fall back to legacy
                // device-only auth on token expiry.
                if let identity = try await identityStore.load() {
                    let signing = BackendAuthSigningContext.make(from: identity.keys.privateKey)
                    apiClient.updateSIWESigningContext(signing)
                    Log.debug("Authenticating with backend via SIWE (address \(signing.address))...")
                    let token = try await apiClient.authenticateWithSIWE(
                        appCheckToken: appCheckToken,
                        signing: signing
                    )
                    let accountId = BackendAuthProbe.extractAccountId(from: token) ?? "?"
                    Log.info("Successfully authenticated with backend (SIWE, address=\(signing.address), accountId=\(accountId))")
                } else {
                    // No on-device identity yet: clear any stale signing
                    // context and fall back to the legacy device-only
                    // path. SIWE will run on the next attempt once an
                    // identity is provisioned.
                    apiClient.updateSIWESigningContext(nil)
                    Log.debug("No identity yet; falling back to legacy device-only auth...")
                    _ = try await apiClient.authenticate(appCheckToken: appCheckToken, retryCount: 0)
                    Log.info("Successfully authenticated with backend (legacy)")
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                Log.warning("Backend auth attempt \(attempt + 1) failed: \(error.localizedDescription)")
            }
        }

        if let lastError {
            throw lastError
        }
    }

    private func waitForNetworkConnected() async {
        await networkMonitor.start()
        defer { Task { await networkMonitor.stop() } }

        for await status in await networkMonitor.statusSequence where status.isConnected {
            return
        }
    }

    // MARK: - App Lifecycle Observation

    private func stopAppLifecycleObservation() {
        appLifecycleTask?.cancel()
        appLifecycleTask = nil
    }

    private func startAppLifecycleObservation() {
        stopAppLifecycleObservation()

        let backgroundNotificationName = appLifecycle.didEnterBackgroundNotification
        let foregroundNotificationName = appLifecycle.willEnterForegroundNotification
        let notificationCenter = NotificationCenter.default

        appLifecycleTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    let backgroundStream = notificationCenter.notifications(named: backgroundNotificationName)
                    for await _ in backgroundStream {
                        await self?.enqueueAction(.enterBackground)
                    }
                }

                group.addTask { [weak self] in
                    let foregroundStream = notificationCenter.notifications(named: foregroundNotificationName)
                    for await _ in foregroundStream {
                        await self?.enqueueAction(.enterForeground)
                    }
                }

                await group.waitForAll()
            }
        }
    }

    // MARK: - Network Monitoring

    private func stopNetworkMonitoring() async {
        networkMonitorTask?.cancel()
        networkMonitorTask = nil
        await networkMonitor.stop()
    }

    private func startNetworkMonitoring() async {
        await stopNetworkMonitoring()

        await networkMonitor.start()

        networkMonitorTask = Task { [weak self] in
            guard let self else { return }

            for await status in await networkMonitor.statusSequence {
                await self.handleNetworkStatusChange(status)
            }
        }
    }

    private func handleNetworkStatusChange(_ status: NetworkMonitor.Status) async {
        guard case .ready = _state else { return }

        switch status {
        case .connected(let type):
            Log.debug("Network connected (\(type)) - resuming sync")
            await syncingManager?.resume()
        case .disconnected:
            Log.debug("Network disconnected - pausing sync")
            await syncingManager?.pause()
        case .connecting, .unknown:
            break
        }
    }
}

// swiftlint:enable type_body_length
