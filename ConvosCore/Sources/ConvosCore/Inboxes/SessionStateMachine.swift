import ConvosInvites
import Foundation
import GRDB
import os
@preconcurrency import XMTPiOS

extension SessionStateMachine.State {
    var isReady: Bool {
        switch self {
        case .ready:
            return true
        default:
            return false
        }
    }

    var clientId: String {
        switch self {
        case .idle(let clientId),
             .authorizing(let clientId, _),
             .registering(let clientId),
             .authenticatingBackend(let clientId, _),
             .ready(let clientId, _),
             .backgrounded(let clientId, _),
             .deleting(let clientId, _),
             .error(let clientId, _):
            return clientId
        }
    }

    /// The current user's XMTP inbox ID if known from the state, else nil.
    /// Available synchronously from `SessionStateManagerProtocol.currentState`.
    public var inboxId: String? {
        switch self {
        case .authorizing(_, let inboxId),
             .authenticatingBackend(_, let inboxId):
            return inboxId
        case .ready(_, let result),
             .backgrounded(_, let result):
            return result.client.inboxId
        case .deleting(_, let inboxId):
            return inboxId
        case .idle, .registering, .error:
            return nil
        }
    }
}

enum SessionStateError: Error {
    case inboxNotReady, clientIdInboxInconsistency
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
        case authorize(inboxId: String, clientId: String),
             register(clientId: String),
             clientAuthorized(clientId: String, client: any XMTPClientProvider),
             clientRegistered(clientId: String, client: any XMTPClientProvider),
             authorized(clientId: String, result: InboxReadyResult),
             enterBackground,
             enterForeground,
             delete,
             stop
    }

    public enum State: Sendable {
        case idle(clientId: String)
        case authorizing(clientId: String, inboxId: String)
        case registering(clientId: String)
        case authenticatingBackend(clientId: String, inboxId: String)
        case ready(clientId: String, result: InboxReadyResult)
        case backgrounded(clientId: String, result: InboxReadyResult)
        case deleting(clientId: String, inboxId: String?)
        case error(clientId: String, error: any Error)
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

    private var currentTask: Task<Void, Never>?
    private var actionQueue: [Action] = []
    private var isProcessing: Bool = false
    private var networkMonitorTask: Task<Void, Never>?
    private var appLifecycleTask: Task<Void, Never>?
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

    var inboxId: String? {
        switch _state {
        case .authorizing(_, let inboxId),
                .authenticatingBackend(_, let inboxId):
            return inboxId
        case .deleting(_, let inboxId):
            return inboxId
        case .ready(_, let result),
                .backgrounded(_, let result):
            return result.client.inboxId
        default:
            return nil
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
        apiClient: (any ConvosAPIClientProtocol)? = nil
    ) {
        let initialState: State = .idle(clientId: clientId)
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
        Log.debug("   isSecure = \(environment.isSecure)")

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

    func authorize(inboxId: String, clientId: String) {
        enqueueAction(.authorize(inboxId: inboxId, clientId: clientId))
    }

    func register(clientId: String) {
        enqueueAction(.register(clientId: clientId))
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

    // MARK: - SessionStateManagerProtocol

    public func waitForInboxReadyResult() async throws -> InboxReadyResult {
        for await state in stateSequence {
            switch state {
            case .ready(_, let result),
                 .backgrounded(_, let result):
                return result
            case .error(_, let error):
                throw error
            default:
                continue
            }
        }
        throw SessionStateError.inboxNotReady
    }

    public func ensureForeground() {
        if case .backgrounded = currentState {
            enqueueAction(.enterForeground)
        }
    }

    public func reauthorize(inboxId: String, clientId: String) async throws -> InboxReadyResult {
        if case .ready(let currentClientId, let result) = _state,
           result.client.inboxId == inboxId && currentClientId == clientId {
            Log.info("Already authorized with inbox \(inboxId) and clientId \(clientId), skipping reauthorization")
            return result
        }

        Log.info("Reauthorizing with inbox \(inboxId)...")

        if case .ready = _state {
            stop()
            for await state in stateSequence {
                if case .idle = state {
                    break
                }
            }
        }

        authorize(inboxId: inboxId, clientId: clientId)

        for await state in stateSequence {
            switch state {
            case .ready(_, let result):
                if result.client.inboxId == inboxId {
                    Log.info("Successfully reauthorized to inbox \(inboxId)")
                    return result
                } else {
                    Log.info("Waiting for correct inbox... current: \(result.client.inboxId), expected: \(inboxId)")
                    continue
                }
            case .error(_, let error):
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
            switch (_state, action) {
            case let (.idle, .authorize(inboxId, clientId)):
                try await handleAuthorize(inboxId: inboxId, clientId: clientId)
            case let (.error(erroredClientId, _), .authorize(inboxId, clientId)):
                try await handleStop(clientId: erroredClientId)
                try await handleAuthorize(inboxId: inboxId, clientId: clientId)

            case (.idle, let .register(clientId)):
                try await handleRegister(clientId: clientId)
            case let (.error(erroredClientId, _), .register(clientId)):
                try await handleStop(clientId: erroredClientId)
                try await handleRegister(clientId: clientId)

            case (.authorizing, let .clientAuthorized(clientId, client)):
                try await handleClientAuthorized(clientId: clientId, client: client)
            case (.registering, let .clientRegistered(clientId, client)):
                try await handleClientRegistered(clientId: clientId, client: client)

            case (.authenticatingBackend, let .authorized(clientId, result)):
                try await handleAuthorized(clientId: clientId, result: result)

            case (let .ready(clientId, result), .delete):
                try await handleDelete(clientId: clientId, client: result.client, apiClient: result.apiClient)
            case (let .error(clientId, _), .delete):
                try await handleDeleteFromError(clientId: clientId)
            case (let .idle(clientId), .delete),
                 (let .authorizing(clientId, _), .delete),
                 (let .registering(clientId), .delete),
                 (let .authenticatingBackend(clientId, _), .delete):
                try await handleDeleteFromIdle(clientId: clientId)
            case (.deleting, .delete):
                // Already deleting - ignore duplicate delete request (idempotent)
                Log.debug("Duplicate delete request while already deleting, ignoring")
            case let (.ready(clientId, result), .enterBackground):
                try await handleEnterBackground(clientId: clientId, result: result)

            case let (.backgrounded(clientId, result), .enterForeground):
                try await handleEnterForeground(clientId: clientId, result: result)

            case let (.error(clientId, _), .enterForeground):
                try await handleRetryFromError(clientId: clientId)

            case (let .backgrounded(clientId, result), .delete):
                try await handleDeleteFromBackgrounded(clientId: clientId, result: result)

            case let (.ready(clientId, _), .stop),
                let (.error(clientId, _), .stop),
                let (.deleting(clientId, _), .stop),
                let (.backgrounded(clientId, _), .stop):
                try await handleStop(clientId: clientId)

            case (.idle, .stop):
                break

            // Ignore lifecycle events when not in appropriate state
            case (_, .enterBackground), (_, .enterForeground):
                Log.debug("Ignoring lifecycle event for transition: \(_state) -> \(action)")

            default:
                Log.warning("Invalid state transition: \(_state) -> \(action)")
            }
        } catch {
            if error is CancellationError {
                Log.debug("Action cancelled: \(action)")
                return
            }

            await stopNetworkMonitoring()

            Log.error(
                "Failed state transition \(_state) -> \(action): \(error.localizedDescription)"
            )
            emitStateChange(.error(clientId: _state.clientId, error: error))
        }
    }

    private func handleAuthorize(inboxId: String, clientId: String) async throws {
        try Task.checkCancellation()

        guard let identity = try await identityStore.load() else {
            throw KeychainIdentityStoreError.identityNotFound("No identity in keychain")
        }
        guard identity.inboxId == inboxId else {
            throw KeychainIdentityStoreError.identityNotFound("Singleton inboxId mismatch: expected \(inboxId), got \(identity.inboxId)")
        }

        try Task.checkCancellation()

        // Verify clientId matches
        guard identity.clientId == clientId else {
            throw KeychainIdentityStoreError.identityNotFound("ClientId mismatch: expected \(clientId), got \(identity.clientId)")
        }

        emitStateChange(.authorizing(clientId: clientId, inboxId: inboxId))
        Log.info(
            "Started authorization flow for inbox: \(inboxId), clientId: \(clientId)"
        )

        // Set custom local address before building/creating client
        // Only updates if different, avoiding unnecessary mutations
        setCustomLocalAddress()

        let keys = identity.keys
        let clientOptions = clientOptions(keys: keys)
        let client: any XMTPClientProvider
        do {
            try Task.checkCancellation()
            client = try await buildXmtpClient(
                inboxId: identity.inboxId,
                identity: keys.signingKey.identity,
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

        // Ensure inbox is saved to database when authorizing
        // (in case it was registered as unused but is now being used)
        let inboxWriter = InboxWriter(dbWriter: databaseWriter)
        try await inboxWriter.save(inboxId: client.inboxId, clientId: identity.clientId)
        Log.info("Saved inbox to database: \(client.inboxId)")

        enqueueAction(.clientAuthorized(clientId: clientId, client: client))
    }

    private func handleRegister(clientId: String) async throws {
        try Task.checkCancellation()

        emitStateChange(.registering(clientId: clientId))
        Log.info("Started registration flow with clientId: \(clientId)")

        // Set custom local address before creating client
        // Only updates if different, avoiding unnecessary mutations
        setCustomLocalAddress()

        try Task.checkCancellation()

        let keys = try await identityStore.generateKeys()

        try Task.checkCancellation()

        let client = try await createXmtpClient(
            signingKey: keys.signingKey,
            options: clientOptions(keys: keys)
        )

        try Task.checkCancellation()

        Log.info("Generated clientId: \(clientId) for inboxId: \(client.inboxId)")

        // Save to keychain as the identity
        _ = try await identityStore.save(inboxId: client.inboxId, clientId: clientId, keys: keys)

        try Task.checkCancellation()

        // Save to database
        do {
            let inboxWriter = InboxWriter(dbWriter: databaseWriter)
            try await inboxWriter.save(inboxId: client.inboxId, clientId: clientId)
            Log.info("Saved inbox to database with clientId: \(clientId)")
        } catch {
            // Rollback keychain entry on database failure to maintain consistency
            Log.error("Failed to save inbox to database, rolling back keychain: \(error)")
            try? await identityStore.delete()
            throw error
        }

        enqueueAction(.clientRegistered(clientId: clientId, client: client))
    }

    private func handleClientAuthorized(clientId: String, client: any XMTPClientProvider) async throws {
        try Task.checkCancellation()

        emitStateChange(.authenticatingBackend(clientId: clientId, inboxId: client.inboxId))

        Log.info("Authenticating with backend...")
        try await authenticateBackend()

        try Task.checkCancellation()

        enqueueAction(.authorized(clientId: clientId, result: .init(client: client, apiClient: apiClient)))
    }

    private func handleClientRegistered(clientId: String, client: any XMTPClientProvider) async throws {
        try Task.checkCancellation()

        emitStateChange(.authenticatingBackend(clientId: clientId, inboxId: client.inboxId))
        Log.info("Authenticating with backend...")
        try await authenticateBackend()

        try Task.checkCancellation()

        enqueueAction(.authorized(clientId: clientId, result: .init(client: client, apiClient: apiClient)))
    }

    private func handleAuthorized(clientId: String, result: InboxReadyResult) async throws {
        await syncingManager?.start(with: result.client, apiClient: result.apiClient)
        foregroundRetryCount = 0
        emitStateChange(.ready(clientId: clientId, result: result))
        // Start app lifecycle observation and network monitoring after starting sync
        await startNetworkMonitoring()
        startAppLifecycleObservation()
        // check if app was backgrounded during auth
        if await appLifecycle.currentState != .active {
            enqueueAction(.enterBackground)
        }
    }

    private func handleDelete(clientId: String, client: any XMTPClientProvider, apiClient: any ConvosAPIClientProtocol) async throws {
        try Task.checkCancellation()

        Log.info("Deleting inbox with clientId: \(clientId)...")
        let inboxId = client.inboxId
        emitStateChange(.deleting(clientId: clientId, inboxId: inboxId))

        defer { enqueueAction(.stop) }

        // Stop app lifecycle observation and network monitoring
        stopAppLifecycleObservation()
        await stopNetworkMonitoring()

        await syncingManager?.stop()

        // Perform common cleanup operations
        try await performInboxCleanup(clientId: clientId, client: client, apiClient: apiClient)
    }

    private func handleDeleteFromError(clientId: String) async throws {
        try Task.checkCancellation()

        Log.info("Deleting inbox with clientId \(clientId) from error state...")
        defer { enqueueAction(.stop) }

        // Resolve inboxId from database since it might be nil in error state
        let resolvedInboxId: String? = try await databaseWriter.write { db in
            try? DBInbox
                .filter(DBInbox.Columns.clientId == clientId)
                .fetchOne(db)?
                .inboxId
        }

        if resolvedInboxId == nil {
            Log.warning("Could not resolve inboxId for clientId \(clientId) - database files will not be cleaned up")
        }

        emitStateChange(.deleting(clientId: clientId, inboxId: resolvedInboxId))

        // Stop app lifecycle observation and network monitoring
        stopAppLifecycleObservation()
        await stopNetworkMonitoring()

        await syncingManager?.stop()

        try Task.checkCancellation()

        // Clean up database records and keychain if we have an inbox ID
        try await cleanupInboxData(clientId: clientId)

        try Task.checkCancellation()

        // Delete identity - idempotent operation, may already be deleted from previous attempt
        let priorIdentity = try? await identityStore.load()
        try? await identityStore.delete()
        if let priorIdentity, priorIdentity.clientId == clientId {
            Log.debug("Deleted identity from keychain for clientId: \(clientId)")
            deleteDatabaseFiles(for: priorIdentity.inboxId)
        } else if let resolvedInboxId {
            Log.debug("Identity absent or not matching clientId: \(clientId), continuing cleanup")
            deleteDatabaseFiles(for: resolvedInboxId)
        }

        Log.info("Deleted inbox with clientId \(clientId)")
    }

    /// Handles deletion when we don't have an initialized client/apiClient
    /// Used for .idle, .authorizing, .registering, and .authenticatingBackend states
    private func handleDeleteFromIdle(clientId: String) async throws {
        Log.info("Deleting inbox with clientId \(clientId) without initialized client...")
        defer { enqueueAction(.stop) }

        // Try to get inboxId from database if available
        let inboxIdFromDb: String? = try? await databaseWriter.read { db in
            try DBInbox
                .filter(DBInbox.Columns.clientId == clientId)
                .fetchOne(db)?
                .inboxId
        }

        try Task.checkCancellation()

        emitStateChange(.deleting(clientId: clientId, inboxId: inboxIdFromDb))

        // Stop app lifecycle observation and network monitoring
        stopAppLifecycleObservation()
        await stopNetworkMonitoring()

        await syncingManager?.stop()

        try Task.checkCancellation()

        // Clean up database records
        try await cleanupInboxData(clientId: clientId)

        try Task.checkCancellation()

        // Delete identity - idempotent operation, may already be deleted
        let priorIdentity = try? await identityStore.load()
        try? await identityStore.delete()
        if let priorIdentity, priorIdentity.clientId == clientId {
            Log.debug("Deleted identity from keychain for clientId: \(clientId)")
            deleteDatabaseFiles(for: priorIdentity.inboxId)
        } else if let inboxIdFromDb {
            Log.debug("Identity absent or not matching clientId: \(clientId), continuing cleanup")
            deleteDatabaseFiles(for: inboxIdFromDb)
        }

        Log.info("Deleted inbox with clientId \(clientId)")
    }

    private func handleStop(clientId: String) async throws {
        Log.info("Stopping inbox with clientId \(clientId)...")

        // Capture client reference before state transition
        let clientToClose: (any XMTPClientProvider)?
        switch _state {
        case .ready(_, let result), .backgrounded(_, let result):
            clientToClose = result.client
        default:
            clientToClose = nil
        }

        // Cancel app lifecycle and network monitoring
        stopAppLifecycleObservation()
        await stopNetworkMonitoring()

        // Stop sync BEFORE dropping database connection to prevent in-flight operations from failing
        await syncingManager?.stop()

        // Drop database connection after sync is stopped
        // This releases SQLCipher connections in the Rust layer (LibXMTP)
        if let client = clientToClose {
            do {
                try client.dropLocalDatabaseConnection()
                Log.debug("Dropped local database connection for \(clientId)")
            } catch {
                Log.error("Failed to drop database connection for \(clientId): \(error)")
            }
        }

        emitStateChange(.idle(clientId: clientId))

        // Clean up all state continuations to prevent memory leaks
        cleanupContinuations()
    }

    private func handleEnterBackground(clientId: String, result: InboxReadyResult) async throws {
        Log.info("App entering background, pausing sync for clientId \(clientId)...")

        // Stop network monitoring while backgrounded
        await stopNetworkMonitoring()

        // Pause the syncing manager
        await syncingManager?.pause()

        try result.client.dropLocalDatabaseConnection()

        emitStateChange(.backgrounded(clientId: clientId, result: result))
        Log.info("Inbox backgrounded successfully")
    }

    private func handleEnterForeground(clientId: String, result: InboxReadyResult) async throws {
        Log.info("App entering foreground, resuming sync for clientId \(clientId)...")

        try await result.client.reconnectLocalDatabase()

        // Restart network monitoring
        await startNetworkMonitoring()

        // Resume the syncing manager
        await syncingManager?.resume()

        emitStateChange(.ready(clientId: clientId, result: result))
        Log.info("Inbox returned to ready state")
    }

    private func handleRetryFromError(clientId: String) async throws {
        try Task.checkCancellation()

        guard foregroundRetryCount < Self.maxForegroundRetries else {
            Log.warning("Max foreground retries (\(Self.maxForegroundRetries)) reached, not retrying")
            return
        }

        guard let identity = try await identityStore.load(), identity.clientId == clientId else {
            Log.warning("Cannot retry from error: no identity matching clientId \(clientId)")
            return
        }

        foregroundRetryCount += 1
        Log.info("Retrying authorization for inbox \(identity.inboxId) after foregrounding (attempt \(foregroundRetryCount)/\(Self.maxForegroundRetries))")
        try await handleStop(clientId: clientId)
        try await handleAuthorize(inboxId: identity.inboxId, clientId: clientId)
    }

    private func handleDeleteFromBackgrounded(clientId: String, result: InboxReadyResult) async throws {
        try Task.checkCancellation()

        Log.info("Deleting inbox with clientId \(clientId) from backgrounded state...")
        let inboxId = result.client.inboxId
        emitStateChange(.deleting(clientId: clientId, inboxId: inboxId))

        defer { enqueueAction(.stop) }

        // App lifecycle observation is still running, stop it
        stopAppLifecycleObservation()

        // Network monitoring already stopped when backgrounded

        // Perform common cleanup operations
        try await performInboxCleanup(clientId: clientId, client: result.client, apiClient: result.apiClient)
    }

    /// Performs common cleanup operations when deleting an inbox
    private func performInboxCleanup(
        clientId: String,
        client: any XMTPClientProvider,
        apiClient: any ConvosAPIClientProtocol
    ) async throws {
        try Task.checkCancellation()

        // Stop all services
        await syncingManager?.stop()

        try Task.checkCancellation()

        // Unsubscribe from inbox-level welcome topic and unregister installation from backend
        // Note: Conversation topics are handled by ConversationStateMachine.cleanUp()
        let welcomeTopic = client.installationId.xmtpWelcomeTopicFormat

        // Unsubscribe from welcome topic (inbox-level topic only)
        do {
            try await apiClient.unsubscribeFromTopics(clientId: clientId, topics: [welcomeTopic])
            Log.debug("Unsubscribed from welcome topic: \(welcomeTopic)")
        } catch {
            Log.error("Failed to unsubscribe from welcome topic: \(error)")
            // Continue with cleanup even if unsubscribe fails
        }

        try Task.checkCancellation()

        // Unregister installation
        do {
            try await apiClient.unregisterInstallation(clientId: clientId)
            Log.debug("Unregistered installation from backend: \(clientId)")
        } catch {
            // Ignore errors during unregistration (common during account deletion when auth may be invalid)
            Log.debug("Could not unregister installation (likely during account deletion): \(error)")
        }

        try Task.checkCancellation()

        // Clean up all database records for this inbox
        try await cleanupInboxData(clientId: clientId)

        try Task.checkCancellation()

        // Delete identity and local database
        // Idempotent: delete swallows the not-found case, so retries are safe.
        try? await identityStore.delete()
        Log.debug("Deleted identity from keychain (clientId: \(clientId))")

        try Task.checkCancellation()

        // Delete XMTP local database
        // Try SDK method first, fall back to manual file deletion if it fails
        do {
            try client.deleteLocalDatabase()
            Log.debug("Deleted XMTP local database via SDK for inbox: \(client.inboxId)")
        } catch {
            Log.warning("SDK deleteLocalDatabase failed, attempting manual file deletion: \(error)")
            deleteDatabaseFiles(for: client.inboxId)
        }

        Log.info("Deleted inbox \(client.inboxId) with clientId \(clientId)")
    }

    private func deleteDatabaseFiles(for inboxId: String) {
        let fileManager = FileManager.default
        let dbDirectory = environment.defaultDatabasesDirectoryURL

        // XMTP creates files like: xmtp-{env}-{inboxId}.db3
        // Note: .local environment uses "localhost" in filename, not "local"
        let envPrefix: String
        switch environment.xmtpEnv {
        case .local:
            envPrefix = "localhost"
        case .dev:
            envPrefix = "dev"
        case .production:
            envPrefix = "production"
        @unknown default:
            envPrefix = "unknown"
        }

        let dbBaseName = "xmtp-\(envPrefix)-\(inboxId)"

        let filesToDelete = [
            "\(dbBaseName).db3",
            "\(dbBaseName).db3.sqlcipher_salt",
            "\(dbBaseName).db3-shm",
            "\(dbBaseName).db3-wal"
        ]

        for filename in filesToDelete {
            let fileURL = dbDirectory.appendingPathComponent(filename)
            if fileManager.fileExists(atPath: fileURL.path) {
                do {
                    try fileManager.removeItem(at: fileURL)
                    Log.debug("Deleted XMTP database file: \(filename)")
                } catch {
                    Log.error("Failed to delete XMTP database file \(filename): \(error)")
                }
            }
        }
    }

    private func cleanupInboxData(clientId: String) async throws {
        try Task.checkCancellation()

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
        // The gateway handles env/isSecure automatically, so we don't set them
        // if let gatewayUrl = environment.gatewayUrl, !gatewayUrl.isEmpty {
        //     // d14n mode: gateway handles network selection
        //     Log.info("Using XMTP d14n - Gateway: \(gatewayUrl)")
        //     apiOptions = .init(
        //         appVersion: "convos/\(Bundle.appVersion)",
        //         gatewayUrl: gatewayUrl
        //     )
        // }

        // Direct XMTP v3 connection: we specify env and isSecure
        Log.debug("Using direct XMTP connection with env: \(environment.xmtpEnv)")
        let apiOptions: ClientOptions.Api = .init(
            env: environment.xmtpEnv,
            isSecure: environment.isSecure,
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
                GroupUpdatedCodec(),
                ExplodeSettingsCodec(),
                InviteJoinErrorCodec(),
                ProfileUpdateCodec(),
                ProfileSnapshotCodec(),
                JoinRequestCodec(),
                AssistantJoinRequestCodec(),
                TypingIndicatorCodec(),
                ReadReceiptCodec()
            ],
            dbEncryptionKey: keys.databaseKey,
            dbDirectory: environment.defaultDatabasesDirectory,
            deviceSyncEnabled: true,
            maxDbPoolSize: 10,
            minDbPoolSize: 3
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
        let client = try await Client.create(account: signingKey, options: options)
        Log.info("XMTP Client created with app version: convos/\(Bundle.appVersion)")
        return client
    }

    private func buildXmtpClient(inboxId: String,
                                 identity: PublicIdentity,
                                 options: ClientOptions) async throws -> any XMTPClientProvider {
        Log.debug("Building XMTP client for \(inboxId)...")
        let client = try await Client.build(
            publicIdentity: identity,
            options: options,
            inboxId: inboxId
        )
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

                Log.debug("Authenticating with backend and storing JWT...")
                _ = try await apiClient.authenticate(appCheckToken: appCheckToken, retryCount: 0)
                Log.info("Successfully authenticated with backend")
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
