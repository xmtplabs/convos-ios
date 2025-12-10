import Foundation
import GRDB
import UIKit
import XMTPiOS

private extension AppEnvironment {
    var xmtpEnv: XMTPEnvironment {
        if let network = self.xmtpNetwork {
            switch network.lowercased() {
            case "local": return .local
            case "dev": return .dev
            case "production", "prod": return .production
            default:
                Log.warning("Unknown xmtpNetwork '\(network)', falling back to environment default")
            }
        }

        switch self {
        case .local, .tests: return .local
        case .dev: return .dev
        case .production: return .production
        }
    }

    var customLocalAddress: String? {
        guard let endpoint = self.xmtpEndpoint, !endpoint.isEmpty else {
            return nil
        }
        return endpoint
    }

    var isSecure: Bool {
        if let network = self.xmtpNetwork {
            switch network.lowercased() {
            case "local":
                return false
            case "dev", "production", "prod":
                return true
            default:
                Log.warning("Unknown xmtpNetwork '\(network)', falling back to environment default")
            }
        }

        switch self {
        case .local, .tests:
            return false
        default:
            return true
        }
    }
}

extension InboxStateMachine.State {
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
             .stopping(let clientId),
             .error(let clientId, _):
            return clientId
        }
    }
}

enum InboxStateError: Error {
    case inboxNotReady, clientIdInboxInconsistency
}

public struct InboxReadyResult: @unchecked Sendable {
    public let client: any XMTPClientProvider
    public let apiClient: any ConvosAPIClientProtocol

    /// InboxReadyResult is marked @unchecked Sendable because:
    /// - XMTPClientProvider wraps XMTPiOS.Client which is not Sendable
    /// - However, XMTP Client is designed for concurrent use (async/await API)
    /// - All access is properly isolated through actors in the state machine
    public init(client: any XMTPClientProvider, apiClient: any ConvosAPIClientProtocol) {
        self.client = client
        self.apiClient = apiClient
    }
}

typealias AnySyncingManager = (any SyncingManagerProtocol)
typealias AnyInviteJoinRequestsManager = (any InviteJoinRequestsManagerProtocol)

// swiftlint:disable type_body_length

/// State machine managing the lifecycle of an XMTP inbox
///
/// InboxStateMachine coordinates the complex lifecycle of an inbox from creation/authorization
/// through ready state and eventual deletion. It handles:
/// - Creating new XMTP clients or building existing ones from keychain
/// - Authenticating with the Convos backend
/// - Starting sync services for conversations and messages
/// - Registering for push notifications
/// - Cleaning up all resources on deletion
///
/// The state machine ensures proper sequencing of operations through an action queue
/// and maintains state through idle → authorizing/registering → authenticating → ready → deleting → stopping.
public actor InboxStateMachine {
    enum Action {
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
        case stopping(clientId: String)
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

    private var currentTask: Task<Void, Never>?
    private var actionQueue: [Action] = []
    private var isProcessing: Bool = false
    private var networkMonitorTask: Task<Void, Never>?
    private var appLifecycleTask: Task<Void, Never>?

    // MARK: - State Observation

    private var stateContinuations: [AsyncStream<State>.Continuation] = []
    let initialClientId: String
    private var _state: State

    var state: State {
        get async {
            _state
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
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else { return }
                await self.addStateContinuation(continuation)
            }
        }
    }

    private func addStateContinuation(_ continuation: AsyncStream<State>.Continuation) {
        stateContinuations.append(continuation)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeStateContinuation(continuation)
            }
        }
        continuation.yield(_state)
    }

    private func emitStateChange(_ newState: State) {
        _state = newState

        // Emit to all continuations
        for continuation in stateContinuations {
            continuation.yield(newState)
        }
    }

    private func removeStateContinuation(_ continuation: AsyncStream<State>.Continuation) {
        stateContinuations.removeAll { $0 == continuation }
    }

    private func cleanupContinuations() {
        stateContinuations.removeAll { continuation in
            continuation.finish()
            return true
        }
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
        environment: AppEnvironment
    ) {
        self.initialClientId = clientId
        self._state = .idle(clientId: clientId)
        self.identityStore = identityStore
        self.invitesRepository = invitesRepository
        self.databaseWriter = databaseWriter
        self.syncingManager = syncingManager
        self.networkMonitor = networkMonitor
        self.overrideJWTToken = overrideJWTToken ?? environment.defaultOverrideJWTToken
        self.environment = environment

        // Initialize API client
        Log.info("Initializing API client (JWT override: \(self.overrideJWTToken != nil))...")
        self.apiClient = ConvosAPIClientFactory.client(
            environment: environment,
            overrideJWTToken: self.overrideJWTToken
        )

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
        Log.info("   Mode = XMTP v3")
        Log.info("   XMTP_CUSTOM_HOST = \(environment.xmtpEndpoint ?? "nil")")
        Log.info("   customLocalAddress = \(environment.customLocalAddress ?? "nil")")
        Log.info("   xmtpEnv = \(environment.xmtpEnv)")
        Log.info("   isSecure = \(environment.isSecure)")

        // Log the actual XMTPEnvironment.customLocalAddress after setting
        if let customHost = environment.customLocalAddress {
            Log.info("Setting XMTPEnvironment.customLocalAddress = \(customHost)")
            XMTPEnvironment.customLocalAddress = customHost
            Log.info("Actual XMTPEnvironment.customLocalAddress = \(XMTPEnvironment.customLocalAddress ?? "nil")")
        } else {
            Log.info("Using default XMTP endpoints")
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
                try await handleAuthorized(
                    clientId: clientId,
                    client: result.client,
                    apiClient: result.apiClient
                )

            case (let .ready(clientId, result), .delete):
                try await handleDelete(clientId: clientId, client: result.client, apiClient: result.apiClient)
            case (let .error(clientId, _), .delete):
                try await handleDeleteFromError(clientId: clientId)
            case (let .idle(clientId), .delete),
                 (let .authorizing(clientId, _), .delete),
                 (let .registering(clientId), .delete),
                 (let .authenticatingBackend(clientId, _), .delete),
                 (let .stopping(clientId), .delete):
                try await handleDeleteFromIdle(clientId: clientId)
            case (.deleting, .delete):
                // Already deleting - ignore duplicate delete request (idempotent)
                Log.info("Duplicate delete request while already deleting, ignoring")
            case let (.ready(clientId, result), .enterBackground):
                try await handleEnterBackground(clientId: clientId, result: result)

            case let (.backgrounded(clientId, result), .enterForeground):
                try await handleEnterForeground(clientId: clientId, result: result)

            case (let .backgrounded(clientId, result), .delete):
                try await handleDeleteFromBackgrounded(clientId: clientId, result: result)

            case let (.ready(clientId, _), .stop),
                let (.error(clientId, _), .stop),
                let (.deleting(clientId, _), .stop),
                let (.backgrounded(clientId, _), .stop):
                try await handleStop(clientId: clientId)

            case (.idle, .stop), (.stopping, .stop):
                break

            // Ignore lifecycle events when not in appropriate state
            case (_, .enterBackground), (_, .enterForeground):
                Log.info("Ignoring lifecycle event for transition: \(_state) -> \(action)")

            default:
                Log.warning("Invalid state transition: \(_state) -> \(action)")
            }
        } catch {
            // Task cancellation is normal during shutdown, not an error
            if error is CancellationError {
                Log.debug("Action cancelled: \(action)")
                return
            }

            // Cancel app lifecycle observation and network monitoring on error
            stopAppLifecycleObservation()
            await stopNetworkMonitoring()

            Log.error(
                "Failed state transition \(_state) -> \(action): \(error.localizedDescription)"
            )
            emitStateChange(.error(clientId: _state.clientId, error: error))
        }
    }

    private func handleAuthorize(inboxId: String, clientId: String) async throws {
        try Task.checkCancellation()

        let identity = try await identityStore.identity(for: inboxId)

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

        let keys = identity.clientKeys
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
                throw InboxStateError.clientIdInboxInconsistency
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

        // Save to keychain with clientId
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
            _ = try? await identityStore.delete(clientId: clientId)
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

    private func handleAuthorized(clientId: String, client: any XMTPClientProvider, apiClient: any ConvosAPIClientProtocol) async throws {
        await syncingManager?.start(with: client, apiClient: apiClient)
        emitStateChange(.ready(clientId: clientId, result: .init(client: client, apiClient: apiClient)))
        // Start app lifecycle observation and network monitoring after starting sync
        await startNetworkMonitoring()
        startAppLifecycleObservation()
        // check if app was backgrounded during auth
        if await UIApplication.shared.applicationState != .active {
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
        do {
            let deletedIdentity = try await identityStore.delete(clientId: clientId)
            Log.info("Deleted identity from keychain for clientId: \(clientId)")
            deleteDatabaseFiles(for: deletedIdentity.inboxId)
        } catch KeychainIdentityStoreError.identityNotFound {
            Log.info("Identity already deleted for clientId: \(clientId), continuing cleanup")
            if let resolvedInboxId {
                deleteDatabaseFiles(for: resolvedInboxId)
            }
        }

        Log.info("Deleted inbox with clientId \(clientId)")
    }

    /// Handles deletion when we don't have an initialized client/apiClient
    /// Used for .idle, .authorizing, .registering, .authenticatingBackend, and .stopping states
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
        do {
            let deletedIdentity = try await identityStore.delete(clientId: clientId)
            Log.info("Deleted identity from keychain for clientId: \(clientId)")
            deleteDatabaseFiles(for: deletedIdentity.inboxId)
        } catch KeychainIdentityStoreError.identityNotFound {
            Log.info("Identity already deleted for clientId: \(clientId), continuing cleanup")
            if let inboxIdFromDb {
                deleteDatabaseFiles(for: inboxIdFromDb)
            }
        }

        Log.info("Deleted inbox with clientId \(clientId)")
    }

    private func handleStop(clientId: String) async throws {
        Log.info("Stopping inbox with clientId \(clientId)...")

        // Cancel app lifecycle and network monitoring
        stopAppLifecycleObservation()
        await stopNetworkMonitoring()

        emitStateChange(.stopping(clientId: clientId))
        await syncingManager?.stop()
        emitStateChange(.idle(clientId: clientId))
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
            Log.info("Unsubscribed from welcome topic: \(welcomeTopic)")
        } catch {
            Log.error("Failed to unsubscribe from welcome topic: \(error)")
            // Continue with cleanup even if unsubscribe fails
        }

        try Task.checkCancellation()

        // Unregister installation
        do {
            try await apiClient.unregisterInstallation(clientId: clientId)
            Log.info("Unregistered installation from backend: \(clientId)")
        } catch {
            // Ignore errors during unregistration (common during account deletion when auth may be invalid)
            Log.info("Could not unregister installation (likely during account deletion): \(error)")
        }

        try Task.checkCancellation()

        // Clean up all database records for this inbox
        try await cleanupInboxData(clientId: clientId)

        try Task.checkCancellation()

        // Delete identity and local database
        // These operations should be idempotent - if identity is already deleted,
        // we're likely in a retry scenario from a previous failed deletion attempt
        do {
            _ = try await identityStore.delete(clientId: clientId)
            Log.info("Deleted identity from keychain for clientId: \(clientId)")
        } catch KeychainIdentityStoreError.identityNotFound {
            Log.info("Identity already deleted for clientId: \(clientId), continuing cleanup")
        }

        try Task.checkCancellation()

        // Delete XMTP local database
        // Try SDK method first, fall back to manual file deletion if it fails
        do {
            try client.deleteLocalDatabase()
            Log.info("Deleted XMTP local database via SDK for inbox: \(client.inboxId)")
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
                    Log.info("Deleted XMTP database file: \(filename)")
                } catch {
                    Log.error("Failed to delete XMTP database file \(filename): \(error)")
                }
            }
        }
    }

    /// Deletes all database records associated with a given inboxId
    private func cleanupInboxData(clientId: String) async throws {
        try Task.checkCancellation()

        Log.info("Cleaning up all data for inbox clientId: \(clientId)")

        try await databaseWriter.write { db in
            // First, fetch all conversation IDs for this inbox
            let conversationIds = try DBConversation
                .filter(DBConversation.Columns.clientId == clientId)
                .fetchAll(db)
                .map { $0.id }

            Log.info("Found \(conversationIds.count) conversations to clean up for inbox clientId: \(clientId)")

            // Delete messages for all conversations belonging to this inbox
            for conversationId in conversationIds {
                try DBMessage
                    .filter(DBMessage.Columns.conversationId == conversationId)
                    .deleteAll(db)
            }

            // Delete conversation members for all conversations
            for conversationId in conversationIds {
                try DBConversationMember
                    .filter(DBConversationMember.Columns.conversationId == conversationId)
                    .deleteAll(db)
            }

            // Delete conversation local states
            for conversationId in conversationIds {
                try ConversationLocalState
                    .filter(ConversationLocalState.Columns.conversationId == conversationId)
                    .deleteAll(db)
            }

            // Delete invites for all conversations
            for conversationId in conversationIds {
                try DBInvite
                    .filter(DBInvite.Columns.conversationId == conversationId)
                    .deleteAll(db)
            }

            // Delete member profiles for this inbox
            for conversationId in conversationIds {
                try MemberProfile
                    .filter(MemberProfile.Columns.conversationId == conversationId)
                    .deleteAll(db)
            }

            // Delete the member record for this inbox
            if let inboxId: String = try? DBInbox
                .filter(DBInbox.Columns.clientId == clientId)
                .fetchOne(db)?
                .inboxId {
                try Member
                    .filter(Member.Columns.inboxId == inboxId)
                    .deleteAll(db)
            }

            // Delete all conversations for this inbox
            try DBConversation
                .filter(DBConversation.Columns.clientId == clientId)
                .deleteAll(db)

            // Finally, delete the inbox record itself
            try DBInbox
                .filter(DBInbox.Columns.clientId == clientId)
                .deleteAll(db)

            Log.info("Successfully cleaned up all data for inbox clientId: \(clientId)")
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
        Log.info("Using direct XMTP connection with env: \(environment.xmtpEnv)")
        let apiOptions: ClientOptions.Api = .init(
            env: environment.xmtpEnv,
            isSecure: environment.isSecure,
            appVersion: "convos/\(Bundle.appVersion)"
        )

        return ClientOptions(
            api: apiOptions,
            codecs: [
                TextCodec(),
                ReplyCodec(),
                ReactionCodec(),
                AttachmentCodec(),
                RemoteAttachmentCodec(),
                GroupUpdatedCodec(),
                ExplodeSettingsCodec()
            ],
            dbEncryptionKey: keys.databaseKey,
            dbDirectory: environment.defaultDatabasesDirectory,
            deviceSyncEnabled: false
        )
    }

    /// Sets XMTPEnvironment.customLocalAddress from current environment
    /// Must be called before building/creating XMTP client
    private func setCustomLocalAddress() {
        if let customHost = environment.customLocalAddress {
            Log.info("Setting XMTPEnvironment.customLocalAddress = \(customHost)")
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
        Log.info("Building XMTP client for \(inboxId)...")
        let client = try await Client.build(
            publicIdentity: identity,
            options: options,
            inboxId: inboxId
        )
        Log.info("XMTP Client built.")
        return client
    }

    private func authenticateBackend() async throws {
        try Task.checkCancellation()

        // When using JWT override, skip authentication
        // We'll use the JWT token from the push notification payload
        guard overrideJWTToken == nil, !environment.isTestingEnvironment else {
            Log.info("JWT override mode: skipping authentication, will use JWT from push payload")
            return
        }

        // Explicitly authenticate with backend using Firebase AppCheck
        Log.info("Getting Firebase AppCheck token...")
        let appCheckToken = try await FirebaseHelperCore.getAppCheckToken()

        try Task.checkCancellation()

        Log.info("Authenticating with backend and storing JWT...")
        _ = try await apiClient.authenticate(appCheckToken: appCheckToken, retryCount: 0)
        Log.info("Successfully authenticated with backend")
    }

    // MARK: - App Lifecycle Observation

    private func stopAppLifecycleObservation() {
        appLifecycleTask?.cancel()
        appLifecycleTask = nil
    }

    private func startAppLifecycleObservation() {
        stopAppLifecycleObservation()

        appLifecycleTask = Task { [weak self] in
            let notificationCenter = NotificationCenter.default

            // Create async streams for both notifications
            let backgroundNotifications = notificationCenter.notifications(
                named: UIApplication.didEnterBackgroundNotification
            )
            let foregroundNotifications = notificationCenter.notifications(
                named: UIApplication.willEnterForegroundNotification
            )

            // Merge both notification streams and handle them
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in backgroundNotifications {
                        guard let self else { return }
                        await self.enqueueAction(.enterBackground)
                    }
                }

                group.addTask {
                    for await _ in foregroundNotifications {
                        guard let self else { return }
                        await self.enqueueAction(.enterForeground)
                    }
                }
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
        guard case .ready = _state else {
            Log.debug("Ignoring network status change in non-ready state: \(_state)")
            return
        }

        switch status {
        case .connected(let type):
            Log.info("Network connected (\(type)) - resuming sync")
            await handleNetworkConnected()

        case .disconnected:
            Log.info("Network disconnected - pausing sync")
            await handleNetworkDisconnected()

        case .connecting:
            Log.info("Network connecting...")

        case .unknown:
            Log.info("Network status unknown...")
        }
    }

    private func handleNetworkConnected() async {
        // Network monitoring starts in ready state, so we can always resume
        await syncingManager?.resume()
    }

    private func handleNetworkDisconnected() async {
        // Network monitoring starts in ready state, so we can always pause
        await syncingManager?.pause()
    }
}

// swiftlint:enable type_body_length
