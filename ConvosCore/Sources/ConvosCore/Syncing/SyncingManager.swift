import Foundation
import GRDB
import XMTPiOS

// MARK: - Protocol

public protocol SyncingManagerProtocol: Actor {
    func start(with client: AnyClientProvider, apiClient: any ConvosAPIClientProtocol)
    func stop() async
    func pause() async
    func resume() async
}

/// Wrapper for client and API client parameters used in state transitions
///
/// Marked @unchecked Sendable because:
/// - XMTPClientProvider wraps XMTPiOS.Client which is not Sendable
/// - However, XMTP Client is designed for concurrent use (async/await API)
/// - All access is properly isolated through actors in the state machine
struct SyncClientParams: @unchecked Sendable {
    let client: AnyClientProvider
    let apiClient: any ConvosAPIClientProtocol
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
        case starting(SyncClientParams)
        case ready(SyncClientParams)
        case paused(SyncClientParams)
        case stopping
        case error(Error)

        var client: AnyClientProvider? {
            switch self {
            case .idle, .stopping, .error:
                return nil
            case .starting(let params),
                 .ready(let params),
                 .paused(let params):
                return params.client
            }
        }

        var apiClient: (any ConvosAPIClientProtocol)? {
            switch self {
            case .idle, .stopping, .error:
                return nil
            case .starting(let params),
                 .ready(let params),
                 .paused(let params):
                return params.apiClient
            }
        }
    }

    // MARK: - Properties

    private let identityStore: any KeychainIdentityStoreProtocol
    private let streamProcessor: any StreamProcessorProtocol
    private let profileWriter: any MemberProfileWriterProtocol
    private let joinRequestsManager: any InviteJoinRequestsManagerProtocol
    private let consentStates: [ConsentState] = [.allowed, .unknown]

    private var messageStreamTask: Task<Void, Never>?
    private var conversationStreamTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    private var activeConversationId: String?

    // State machine
    private var _state: State = .idle
    private var actionQueue: [Action] = []
    private var isProcessing: Bool = false
    private var currentTask: Task<Void, Never>?
    private var pauseRequestedDuringStarting: Bool = false

    // Notification handling
    private var notificationObservers: [NSObjectProtocol] = []
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
        self.profileWriter = MemberProfileWriter(databaseWriter: databaseWriter)
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

            case (.ready, .start(let params)),
                 (.paused, .start(let params)):
                // Already running - stop first, then start
                try await handleStop()
                try await handleStart(client: params.client, apiClient: params.apiClient)

            case (.error, .start(let params)):
                // Recover from error by starting fresh
                try await handleStart(client: params.client, apiClient: params.apiClient)

            case (.starting, .syncComplete(let params)):
                try await handleSyncComplete(client: params.client, apiClient: params.apiClient)

            case (.ready, .pause):
                try await handlePause()

            case (.paused, .resume):
                try await handleResume()

            case (.starting, .pause):
                // Pause requested during starting - will pause once ready
                Log.info("Pause requested while starting - will pause once ready")
                pauseRequestedDuringStarting = true

            case (.starting, .resume):
                // Can't resume while starting
                Log.info("Cannot resume while starting")

            case (.ready, .stop), (.paused, .stop), (.error, .stop), (.starting, .stop):
                try await handleStop()

            case (.idle, .stop), (.stopping, _):
                // Already idle or stopping, ignore
                break

            default:
                Log.warning("Invalid state transition: \(_state) -> \(action)")
            }
        } catch {
            // Cancel all running tasks before entering error state
            syncTask?.cancel()
            messageStreamTask?.cancel()
            conversationStreamTask?.cancel()

            // Wait for cancellation to complete
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

            Log.error("Failed state transition \(_state) -> \(action): \(error.localizedDescription)")
            pauseRequestedDuringStarting = false // Reset flag on error
            emitStateChange(.error(error))
        }
    }

    private func emitStateChange(_ newState: State) {
        _state = newState
    }

    // MARK: - Action Handlers

    private func handleStart(client: AnyClientProvider, apiClient: any ConvosAPIClientProtocol) async throws {
        let params = SyncClientParams(client: client, apiClient: apiClient)
        pauseRequestedDuringStarting = false // Reset flag when starting
        emitStateChange(.starting(params))

        // Setup notifications if not already done
        if notificationObservers.isEmpty {
            setupNotificationObservers()
        }

        // Start streams first
        Log.info("Starting message and conversation streams...")
        messageStreamTask?.cancel()
        conversationStreamTask?.cancel()

        messageStreamTask = Task { [weak self] in
            guard let self else { return }
            await self.runMessageStream(client: client, apiClient: apiClient)
        }

        conversationStreamTask = Task { [weak self] in
            guard let self else { return }
            await self.runConversationStream(client: client, apiClient: apiClient)
        }

        // Now call syncAllConversations after streams are setup
        Log.info("Streams started - calling syncAllConversations...")
        syncTask = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                _ = try await client.conversationsProvider.syncAllConversations(consentStates: consentStates)
                try Task.checkCancellation()
                // Check if pause was requested during starting and handle transition
                await self.handleSyncCompleteTransition(params: params)
            } catch is CancellationError {
                Log.info("syncAllConversations cancelled")
            } catch {
                Log.error("syncAllConversations failed: \(error)")
                await self.handleSyncError(error: error)
            }
        }
    }

    private func handleSyncCompleteTransition(params: SyncClientParams) async {
        // Check if pause was requested during starting
        if pauseRequestedDuringStarting {
            pauseRequestedDuringStarting = false
            // Cancel streams before transitioning to paused
            messageStreamTask?.cancel()
            conversationStreamTask?.cancel()
            // Wait for tasks to complete
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
            // Transition to ready state after sync completes
            emitStateChange(.ready(params))
            Log.info("syncAllConversations completed, sync ready")
        }
    }

    private func handleSyncError(error: Error) async {
        pauseRequestedDuringStarting = false
        emitStateChange(.error(error))
    }

    private func handleSyncComplete(client: AnyClientProvider, apiClient: any ConvosAPIClientProtocol) async throws {
        // This method is no longer used in the normal flow
        // Streams are started in handleStart, and syncAllConversations is called there too
        // Keeping this method for backwards compatibility but it shouldn't be called
        Log.warning("handleSyncComplete called but should not be used in current flow")
        let params = SyncClientParams(client: client, apiClient: apiClient)
        emitStateChange(.ready(params))
    }

    private func handlePause() async throws {
        guard case .ready(let params) = _state else {
            Log.warning("Cannot pause - not in ready state")
            return
        }

        Log.info("Pausing sync...")

        // Cancel streams
        messageStreamTask?.cancel()
        conversationStreamTask?.cancel()

        // Wait for tasks to complete
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

        messageStreamTask = Task { [weak self] in
            guard let self else { return }
            await self.runMessageStream(client: params.client, apiClient: params.apiClient)
        }

        conversationStreamTask = Task { [weak self] in
            guard let self else { return }
            await self.runConversationStream(client: params.client, apiClient: params.apiClient)
        }

        emitStateChange(.ready(params))
        Log.info("Sync resumed")
    }

    private func handleStop() async throws {
        Log.info("Stopping sync...")
        emitStateChange(.stopping)

        // Cancel all tasks
        syncTask?.cancel()
        messageStreamTask?.cancel()
        conversationStreamTask?.cancel()

        // Wait for tasks to complete
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

        activeConversationId = nil

        // Clean up notification observers
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()

        emitStateChange(.idle)
        Log.info("Sync stopped")
    }

    // MARK: - Stream Management

    private func runMessageStream(client: AnyClientProvider, apiClient: any ConvosAPIClientProtocol) async {
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
                for try await message in client.conversationsProvider.streamAllMessages(
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
                        client: client,
                        apiClient: apiClient,
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

    private func runConversationStream(client: AnyClientProvider, apiClient: any ConvosAPIClientProtocol) async {
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
                for try await conversation in client.conversationsProvider.stream(
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
                        client: client,
                        apiClient: apiClient
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

    // MARK: - Notification Observers

    private func setupNotificationObservers() {
        let activeConversationObserver = NotificationCenter.default.addObserver(
            forName: .activeConversationChanged,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.setActiveConversationId(notification.userInfo?["conversationId"] as? String)
            }
        }
        notificationObservers.append(activeConversationObserver)
    }
}
