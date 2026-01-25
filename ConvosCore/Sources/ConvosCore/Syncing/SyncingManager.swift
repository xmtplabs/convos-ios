import Foundation
import GRDB
@preconcurrency import XMTPiOS

// MARK: - Protocol

public protocol SyncingManagerProtocol: Actor {
    var isSyncReady: Bool { get }
    func start(with client: AnyClientProvider, apiClient: any ConvosAPIClientProtocol)
    func stop() async
    func pause() async
    func resume() async
    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) async
}

/// Wrapper for client and API client parameters used in state transitions
///
/// Marked @unchecked Sendable because:
/// - XMTPClientProvider wraps XMTPiOS.Client which is not Sendable
/// - However, XMTP Client is designed for concurrent use (async/await API)
/// - All access is properly isolated through actors in the state machine
public struct SyncClientParams: @unchecked Sendable {
    public let client: AnyClientProvider
    public let apiClient: any ConvosAPIClientProtocol

    public init(client: AnyClientProvider, apiClient: any ConvosAPIClientProtocol) {
        self.client = client
        self.apiClient = apiClient
    }
}

/// Manages real-time synchronization of conversations and messages
///
/// SyncingManager coordinates continuous synchronization between the local database
/// and XMTP network. It handles:
/// - Initial sync of all conversations and messages via syncAllConversations
/// - Real-time streaming of new conversations and messages
/// - Processing join requests via DMs
/// - Managing conversation consent states
/// - Push notification topic subscriptions
/// - Exponential backoff retry logic for network failures
///
/// The manager maintains separate streams for conversations and messages with
/// automatic retry and backoff handling. It uses a state machine pattern to
/// manage lifecycle transitions and ensure proper sequencing of operations.
actor SyncingManager: SyncingManagerProtocol {
    // MARK: - State Machine

    enum Action {
        case start(SyncClientParams)
        case syncComplete(SyncClientParams)
        case pause
        case resume
        case stop
    }

    enum State: Sendable {
        case idle
        case starting(SyncClientParams, pauseOnComplete: Bool)
        case ready(SyncClientParams)
        case paused(SyncClientParams)
        case stopping
        case error(Error)

        var client: AnyClientProvider? {
            switch self {
            case .idle, .stopping, .error:
                return nil
            case .starting(let params, _),
                 .ready(let params),
                 .paused(let params):
                return params.client
            }
        }

        var apiClient: (any ConvosAPIClientProtocol)? {
            switch self {
            case .idle, .stopping, .error:
                return nil
            case .starting(let params, _),
                 .ready(let params),
                 .paused(let params):
                return params.apiClient
            }
        }
    }

    // MARK: - Properties

    private let identityStore: any KeychainIdentityStoreProtocol
    private let streamProcessor: any StreamProcessorProtocol
    private let joinRequestsManager: any InviteJoinRequestsManagerProtocol
    private let consentStates: [ConsentState] = [.allowed, .unknown]

    private var messageStreamTask: Task<Void, Never>?
    private var conversationStreamTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    private var activeConversationId: String?

    // State machine
    private var _state: State = .idle
    private var actionQueue: [Action] = []

    var isSyncReady: Bool {
        if case .ready = _state { return true }
        return false
    }
    private var isProcessing: Bool = false
    private var currentTask: Task<Void, Never>?

    // Notification handling
    // Safe to use nonisolated(unsafe) because the array is only mutated during actor-isolated
    // setup, and deinit only runs after all actor tasks complete (no concurrent access possible).
    nonisolated(unsafe) private var notificationObservers: [NSObjectProtocol] = []
    private var notificationTask: Task<Void, Never>?

    // MARK: - Initialization

    init(identityStore: any KeychainIdentityStoreProtocol,
         databaseWriter: any DatabaseWriter,
         databaseReader: any DatabaseReader,
         deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)? = nil) {
        self.identityStore = identityStore
        self.streamProcessor = StreamProcessor(
            identityStore: identityStore,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            deviceRegistrationManager: deviceRegistrationManager
        )
        self.joinRequestsManager = InviteJoinRequestsManager(
            identityStore: identityStore,
            databaseReader: databaseReader
        )
    }

    deinit {
        // Clean up tasks
        syncTask?.cancel()
        notificationTask?.cancel()
        messageStreamTask?.cancel()
        conversationStreamTask?.cancel()
        currentTask?.cancel()

        // Remove observers
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public Interface

    func start(with client: AnyClientProvider, apiClient: any ConvosAPIClientProtocol) {
        enqueueAction(.start(SyncClientParams(client: client, apiClient: apiClient)))
    }

    func stop() async {
        enqueueAction(.stop)
        // Wait until idle (stop processed) with timeout
        let maxWaitTime = 10.0 // 10 seconds
        let startTime = Date()
        while true {
            if case .idle = _state { break }
            if case .error = _state { break } // Handle error state
            if Date().timeIntervalSince(startTime) > maxWaitTime {
                Log.error("Stop timeout - state: \(_state)")
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    func pause() async {
        enqueueAction(.pause)
    }

    func resume() async {
        enqueueAction(.resume)
    }

    // MARK: - State Machine

    private func enqueueAction(_ action: Action) {
        actionQueue.append(action)
        processNextAction()
    }

    private func processNextAction() {
        guard !isProcessing, !actionQueue.isEmpty else { return }

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
            case (.idle, .start(let params)):
                try await handleStart(client: params.client, apiClient: params.apiClient)

            case (.starting, .start):
                // Already starting - ignore duplicate start
                Log.info("Already starting, ignoring duplicate start request")

            case let (.starting(stateParams, pauseOnComplete), .syncComplete(actionParams)):
                // Validate this syncComplete is for the current starting session
                guard stateParams.client.inboxId == actionParams.client.inboxId else {
                    Log.info("Ignoring stale syncComplete for old session (expected \(stateParams.client.inboxId), got \(actionParams.client.inboxId))")
                    break
                }
                try await handleSyncComplete(params: actionParams, pauseOnComplete: pauseOnComplete)

            case let (.ready(readyParams), .start(startParams)):
                if readyParams.client.inboxId != startParams.client.inboxId {
                    // stop first, then start
                    Log.info("Starting with different client params")
                    try await handleStop()
                    try await handleStart(
                        client: startParams.client,
                        apiClient: startParams.apiClient
                    )
                } else {
                    Log.info("Already ready, ignoring duplicate start request")
                }
            case (.paused, .start(let params)):
                // Already running - stop first, then start
                try await handleStop()
                try await handleStart(client: params.client, apiClient: params.apiClient)

            case (.error, .start(let params)):
                // Recover from error by starting fresh
                try await handleStart(client: params.client, apiClient: params.apiClient)

            case (.ready, .pause):
                try await handlePause()

            case (.paused, .resume):
                try await handleResume()

            case (.starting(let params, _), .pause):
                // Pause requested during starting - will pause once sync completes
                Log.info("Pause requested while starting - will pause once sync completes")
                emitStateChange(.starting(params, pauseOnComplete: true))

            case (.starting(let params, _), .resume):
                // User changed their mind - cancel the pending pause
                Log.info("Resume requested while starting - cancelling pending pause")
                emitStateChange(.starting(params, pauseOnComplete: false))

            case (.ready, .stop), (.paused, .stop), (.error, .stop), (.starting, .stop):
                try await handleStop()

            case (.idle, .stop), (.stopping, _):
                // Already idle or stopping, ignore
                break

            case (.idle, .syncComplete(_)):
                // Sync completed but stop was already processed - ignore
                // This can happen if syncAllConversations completes just before cancellation
                Log.info("Sync completed after stop - ignoring")

            default:
                Log.warning("Invalid state transition: \(_state) -> \(action)")
            }
        } catch {
            await cancelAndAwaitTasks()
            Log.error("Failed state transition \(_state) -> \(action): \(error.localizedDescription)")
            emitStateChange(.error(error))
        }
    }

    private func emitStateChange(_ newState: State) {
        _state = newState
    }

    // MARK: - Action Handlers

    private func handleStart(client: AnyClientProvider, apiClient: any ConvosAPIClientProtocol) async throws {
        let params = SyncClientParams(client: client, apiClient: apiClient)
        emitStateChange(.starting(params, pauseOnComplete: false))

        // Setup notifications if not already done
        if notificationObservers.isEmpty {
            setupNotificationObservers()
        }

        // Start streams first
        Log.info("Starting message and conversation streams...")
        messageStreamTask?.cancel()
        conversationStreamTask?.cancel()

        messageStreamTask = Task { [weak self, params] in
            guard let self else { return }
            await self.runMessageStream(params: params)
        }

        conversationStreamTask = Task { [weak self, params] in
            guard let self else { return }
            await self.runConversationStream(params: params)
        }

        // Now call syncAllConversations after streams are setup
        Log.info("Streams started - calling syncAllConversations...")
        syncTask = Task { [weak self, params] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                _ = try await params.client.conversationsProvider.syncAllConversations(consentStates: self.consentStates)
                try Task.checkCancellation()
                // Route sync completion through the action queue for consistent state transitions
                await self.enqueueAction(.syncComplete(params))
            } catch is CancellationError {
                Log.info("syncAllConversations cancelled")
            } catch {
                Log.error("syncAllConversations failed: \(error)")
                // Transition to ready state anyway - streams are already running
                // and will continue to receive updates. The initial sync failure
                // shouldn't block the app from functioning.
                await self.enqueueAction(.syncComplete(params))
            }
        }
    }

    private func handleSyncComplete(params: SyncClientParams, pauseOnComplete: Bool) async throws {
        if pauseOnComplete {
            messageStreamTask?.cancel()
            conversationStreamTask?.cancel()

            if let task = messageStreamTask {
                _ = await task.value
                messageStreamTask = nil
            }
            if let task = conversationStreamTask {
                _ = await task.value
                conversationStreamTask = nil
            }
            emitStateChange(.paused(params))
            Log.info("syncAllConversations completed, transitioned to paused (pause was requested during starting)")
        } else {
            emitStateChange(.ready(params))
            Log.info("syncAllConversations completed, sync ready")
        }
    }

    private func handlePause() async throws {
        guard case .ready(let params) = _state else {
            Log.warning("Cannot pause - not in ready state")
            return
        }

        Log.info("Pausing sync...")

        messageStreamTask?.cancel()
        conversationStreamTask?.cancel()

        if let task = messageStreamTask {
            _ = await task.value
            messageStreamTask = nil
        }
        if let task = conversationStreamTask {
            _ = await task.value
            conversationStreamTask = nil
        }

        emitStateChange(.paused(params))
        Log.info("Sync paused")
    }

    private func handleResume() async throws {
        guard case .paused(let params) = _state else {
            Log.warning("Cannot resume - not in paused state")
            return
        }

        Log.info("Resuming sync...")

        // Restart streams
        messageStreamTask?.cancel()
        conversationStreamTask?.cancel()

        messageStreamTask = Task { [weak self, params] in
            guard let self else { return }
            await self.runMessageStream(params: params)
        }

        conversationStreamTask = Task { [weak self, params] in
            guard let self else { return }
            await self.runConversationStream(params: params)
        }

        emitStateChange(.ready(params))
        Log.info("Sync resumed")
    }

    private func handleStop() async throws {
        Log.info("Stopping sync...")
        emitStateChange(.stopping)

        await cancelAndAwaitTasks()
        activeConversationId = nil

        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()

        emitStateChange(.idle)
        Log.info("Sync stopped")
    }

    private func cancelAndAwaitTasks() async {
        syncTask?.cancel()
        messageStreamTask?.cancel()
        conversationStreamTask?.cancel()

        if let task = syncTask {
            _ = await task.value
            syncTask = nil
        }
        if let task = messageStreamTask {
            _ = await task.value
            messageStreamTask = nil
        }
        if let task = conversationStreamTask {
            _ = await task.value
            conversationStreamTask = nil
        }
    }

    // MARK: - Stream Management

    private func runMessageStream(params: SyncClientParams) async {
        var retryCount = 0

        while !Task.isCancelled {
            do {
                // Exponential backoff
                if retryCount > 0 {
                    let delay = TimeInterval.calculateExponentialBackoff(for: retryCount)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }

                Log.info("Starting message stream (attempt \(retryCount + 1))")

                // Stream messages - the loop will exit when onClose is called and continuation.finish() happens
                var isFirstMessage = true
                for try await message in params.client.conversationsProvider.streamAllMessages(
                    type: .all,
                    consentStates: consentStates,
                    onClose: {
                        Log.info("Message stream closed via onClose callback")
                    }
                ) {
                    // Check cancellation
                    try Task.checkCancellation()

                    // Reset retry count after first successful message (stream is healthy)
                    if isFirstMessage {
                        retryCount = 0
                        isFirstMessage = false
                    }

                    // Process message
                    await streamProcessor.processMessage(
                        message,
                        params: params,
                        activeConversationId: activeConversationId
                    )
                }

                // Stream ended (onClose was called and continuation finished)
                retryCount += 1
                Log.info("Message stream ended...")
            } catch is CancellationError {
                Log.info("Message stream cancelled")
                break
            } catch {
                retryCount += 1
                Log.error("Message stream error: \(error)")
            }
        }
    }

    private func runConversationStream(params: SyncClientParams) async {
        var retryCount = 0

        while !Task.isCancelled {
            do {
                if retryCount > 0 {
                    let delay = TimeInterval.calculateExponentialBackoff(for: retryCount)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }

                Log.info("Starting conversation stream (attempt \(retryCount + 1))")

                // Stream conversations - the loop will exit when onClose is called
                var isFirstConversation = true
                for try await conversation in params.client.conversationsProvider.stream(
                    type: .groups,
                    onClose: {
                        Log.info("Conversation stream closed via onClose callback")
                    }
                ) {
                    guard case .group(let conversation) = conversation else {
                        continue
                    }

                    // Check cancellation
                    try Task.checkCancellation()

                    // Reset retry count after first successful conversation (stream is healthy)
                    if isFirstConversation {
                        retryCount = 0
                        isFirstConversation = false
                    }

                    // Process conversation
                    try await streamProcessor.processConversation(
                        conversation,
                        params: params
                    )
                }

                // Stream ended (onClose was called and continuation finished)
                retryCount += 1
                Log.info("Conversation stream ended, will retry...")
            } catch is CancellationError {
                Log.info("Conversation stream cancelled")
                break
            } catch {
                retryCount += 1
                Log.error("Conversation stream error: \(error)")
            }
        }
    }

    // MARK: - Mutation

    func setActiveConversationId(_ conversationId: String?) {
        // Update the active conversation
        activeConversationId = conversationId
    }

    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) async {
        await streamProcessor.setInviteJoinErrorHandler(handler)
    }

    // MARK: - Notification Observers

    private func setupNotificationObservers() {
        let activeConversationObserver = NotificationCenter.default.addObserver(
            forName: .activeConversationChanged,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let conversationId = notification.userInfo?["conversationId"] as? String
            Task { [weak self] in
                await self?.setActiveConversationId(conversationId)
            }
        }
        notificationObservers.append(activeConversationObserver)
    }
}
