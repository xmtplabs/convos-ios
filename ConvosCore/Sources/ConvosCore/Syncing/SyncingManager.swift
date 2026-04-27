import ConvosInvites
import ConvosMessagingProtocols
import Foundation
import GRDB
// FIXME: see docs/outstanding-messaging-abstraction-work.md#stream-wire-layer
@preconcurrency import XMTPiOS

// MARK: - Protocol

public protocol SyncingManagerProtocol: Actor {
    var isSyncReady: Bool { get }
    func start(with client: any MessagingClient, apiClient: any ConvosAPIClientProtocol)
    func stop() async
    func pause() async
    func resume() async
    func requestDiscovery() async
    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) async
    func setTypingIndicatorHandler(_ handler: @escaping @Sendable (String, String, Bool) -> Void) async
}

/// Wrapper for client and API client parameters used in state transitions
///
/// Marked @unchecked Sendable because:
/// - MessagingClient (e.g. XMTPiOSMessagingClient) wraps an XMTPiOS.Client
///   which is not Sendable
/// - ConvosAPIClient is marked @unchecked Sendable
public struct SyncClientParams: @unchecked Sendable {
    public let client: any MessagingClient
    public let apiClient: any ConvosAPIClientProtocol
    public let consentStates: [MessagingConsentState]

    public init(
        client: any MessagingClient,
        apiClient: any ConvosAPIClientProtocol,
        consentStates: [MessagingConsentState] = [.allowed, .unknown]
    ) {
        self.client = client
        self.apiClient = apiClient
        self.consentStates = consentStates
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
enum SyncingError: Error {
    case streamRetriesExhausted
}

actor SyncingManager: SyncingManagerProtocol {
    // MARK: - State Machine

    enum Action {
        case start(SyncClientParams)
        case syncComplete(SyncClientParams)
        case pause
        case resume
        case stop
        case streamFailed
    }

    enum State: Sendable {
        case idle
        case starting(SyncClientParams, pauseOnComplete: Bool)
        case ready(SyncClientParams)
        case paused(SyncClientParams)
        case stopping
        case error(Error)

        var client: (any MessagingClient)? {
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
    // Maximum consecutive stream failures before giving up. Prevents FD exhaustion when
    // XMTP service is unavailable (each failed connection attempt can leak file descriptors).
    private let maxStreamRetries: Int = 10

    private var messageStreamTask: Task<Void, Never>?
    private var conversationStreamTask: Task<Void, Never>?
    private var dmStreamTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    private var activeConversationId: String?

    // Stream readiness tracking - used to wait for streams to subscribe before signaling ready
    private var messageStreamReadyContinuation: AsyncStream<Void>.Continuation?
    private var conversationStreamReadyContinuation: AsyncStream<Void>.Continuation?

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

    private let databaseReader: any DatabaseReader

    init(identityStore: any KeychainIdentityStoreProtocol,
         databaseWriter: any DatabaseWriter,
         databaseReader: any DatabaseReader,
         deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)? = nil,
         notificationCenter: any UserNotificationCenterProtocol) {
        self.identityStore = identityStore
        self.databaseReader = databaseReader
        self.streamProcessor = StreamProcessor(
            identityStore: identityStore,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            deviceRegistrationManager: deviceRegistrationManager,
            notificationCenter: notificationCenter
        )
        self.joinRequestsManager = InviteJoinRequestsManager(
            identityStore: identityStore,
            databaseWriter: databaseWriter
        )
    }

    deinit {
        // Clean up tasks
        syncTask?.cancel()
        notificationTask?.cancel()
        messageStreamTask?.cancel()
        conversationStreamTask?.cancel()
        dmStreamTask?.cancel()
        currentTask?.cancel()

        // Remove observers
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public Interface

    func start(with client: any MessagingClient, apiClient: any ConvosAPIClientProtocol) {
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
                Log.debug("Already starting, ignoring duplicate start request")

            case let (.starting(stateParams, pauseOnComplete), .syncComplete(actionParams)):
                // Validate this syncComplete is for the current starting session
                guard stateParams.client.inboxId == actionParams.client.inboxId else {
                    Log.debug("Ignoring stale syncComplete for old session (expected \(stateParams.client.inboxId), got \(actionParams.client.inboxId))")
                    break
                }
                try await handleSyncComplete(params: actionParams, pauseOnComplete: pauseOnComplete)

            case let (.ready(readyParams), .start(startParams)):
                if readyParams.client.inboxId != startParams.client.inboxId {
                    // stop first, then start
                    Log.debug("Starting with different client params")
                    try await handleStop()
                    try await handleStart(
                        client: startParams.client,
                        apiClient: startParams.apiClient
                    )
                } else {
                    Log.debug("Already ready, ignoring duplicate start request")
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
                Log.debug("Pause requested while starting - will pause once sync completes")
                emitStateChange(.starting(params, pauseOnComplete: true))

            case (.starting(let params, _), .resume):
                // User changed their mind - cancel the pending pause
                Log.debug("Resume requested while starting - cancelling pending pause")
                emitStateChange(.starting(params, pauseOnComplete: false))

            case (.ready, .streamFailed), (.starting, .streamFailed):
                await cancelAndAwaitTasks()
                emitStateChange(.error(SyncingError.streamRetriesExhausted))
                Log.error("Streams exhausted max retries, transitioning to error state")

            case (.error, .streamFailed):
                break

            case (.ready, .stop), (.paused, .stop), (.error, .stop), (.starting, .stop):
                try await handleStop()

            case (.idle, .stop), (.stopping, _):
                // Already idle or stopping, ignore
                break

            case (.idle, .syncComplete(_)):
                // Sync completed but stop was already processed - ignore
                // This can happen if syncAllConversations completes just before cancellation
                Log.debug("Sync completed after stop - ignoring")

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

    private func handleStart(client: any MessagingClient, apiClient: any ConvosAPIClientProtocol) async throws {
        // Gap 2: SyncingManager's stream + sync paths now flow through
        // the `MessagingClient.conversations` abstraction. The DTU
        // lane uses the polling-based `streamAllMessages` /
        // `streamAll` shims in `DTUMessagingConversations` and the
        // abstraction-typed `processMessage(message:)` /
        // `processConversation(group:)` overloads on
        // `StreamProcessor`. The legacy-provider short-circuit that
        // used to no-op the entire DTU lane has been removed —
        // DTU-backed clients now run the same code path as
        // XMTPiOS-backed ones.
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
        dmStreamTask?.cancel()

        // Set up stream readiness tracking BEFORE creating tasks to avoid race conditions.
        // If we create tasks first, they might signal readiness before continuations are set up.
        let streams = setupStreamReadinessTracking()

        messageStreamTask = Task { [weak self, params] in
            guard let self else { return }
            await self.runMessageStream(params: params)
        }

        conversationStreamTask = Task { [weak self, params] in
            guard let self else { return }
            await self.runConversationStream(params: params)
        }

        // Gap 2: XMTPiOS-only DM stream sibling. Spawned at the actor
        // level so the DM/invite back-channel keeps consuming
        // `DecodedMessage` directly via the existing
        // `processMessage(_ message:DecodedMessage,...)` path.
        // Skipped on DTU since DTU has no DM channel today.
        if isXMTPiOSBacked(client: client) {
            dmStreamTask = Task { [weak self, params] in
                guard let self else { return }
                await self.runDmMessageStream(params: params)
            }
        }

        // Wait for streams to enter their async iteration loops before proceeding.
        // This ensures streams are actually subscribed to the XMTP network before
        // we signal isSyncReady, preventing race conditions where messages sent
        // immediately after isSyncReady could be missed.
        Log.debug("Waiting for streams to subscribe...")
        await waitForStreamsToBeReady(messageStream: streams.messageStream, conversationStream: streams.conversationStream)

        // Now call syncAllConversations after streams are subscribed
        Log.debug("Streams subscribed - calling syncAllConversations...")
        syncTask = Task { [weak self, params] in
            guard let self else { return }
            let syncStart = CFAbsoluteTimeGetCurrent()
            do {
                try Task.checkCancellation()
                // Gap 2: route through `MessagingClient.conversations.syncAll`
                // (XMTPiOS adapter calls `syncAllConversations`, DTU
                // adapter calls its in-process `sync` action). Test
                // doubles that double-conform `XMTPClientProvider`
                // continue to track `syncCallCount` because their
                // adapter forwards through the same legacy surface.
                _ = try await params.client.conversations.syncAll(
                    consentStates: params.consentStates
                )
                try Task.checkCancellation()
                let syncElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - syncStart) * 1000)
                Log.info("[PERF] sync.all_conversations: \(syncElapsed)ms")
                // Route sync completion through the action queue for consistent state transitions
                await self.enqueueAction(.syncComplete(params))
            } catch is CancellationError {
                Log.debug("syncAllConversations cancelled")
            } catch {
                let syncElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - syncStart) * 1000)
                Log.error("syncAllConversations failed after \(syncElapsed)ms: \(error)")
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
            dmStreamTask?.cancel()

            if let task = messageStreamTask {
                _ = await task.value
                messageStreamTask = nil
            }
            if let task = conversationStreamTask {
                _ = await task.value
                conversationStreamTask = nil
            }
            if let task = dmStreamTask {
                _ = await task.value
                dmStreamTask = nil
            }
            emitStateChange(.paused(params))
            Log.debug("syncAllConversations completed, transitioned to paused (pause was requested during starting)")
        } else {
            emitStateChange(.ready(params))
            Log.info("syncAllConversations completed, sync ready")
            QAEvent.emit(.sync, "completed")

            // Discover any XMTP groups that the conversation stream missed.
            // This handles cases where the joiner was added to a group while
            // the inbox was paused, stopped, or the stream had a timeout.
            await discoverNewConversations(params: params)

            // Process any join requests that may have been missed during stream startup.
            // This handles the race condition where a joiner sends a DM before the message
            // stream has fully subscribed to the XMTP network.
            await processJoinRequestsAfterSync(params: params)
        }
    }

    private func processJoinRequestsAfterSync(params: SyncClientParams) async {
        let results = await joinRequestsManager.processJoinRequests(since: nil, client: params.client)
        if !results.isEmpty {
            Log.info("Processed \(results.count) join requests after sync complete")
        }
    }

    /// Lists all XMTP groups and processes any that are missing from the local database.
    ///
    /// After syncAllConversations syncs the XMTP data layer, the local DB may still be
    /// missing groups that the conversation stream failed to deliver (e.g., stream timeout,
    /// inbox paused during approval, app backgrounded). This method provides a fallback
    /// by listing all groups and storing any that aren't already in the DB.
    private func discoverNewConversations(params: SyncClientParams) async {
        do {
            // Gap 2: list via the abstraction so DTU-backed clients
            // also see their conversations during the post-sync
            // discovery sweep.
            let query = MessagingConversationQuery(
                consentStates: params.consentStates,
                orderBy: .lastActivity
            )
            let groups = try await params.client.conversations.listGroups(query: query)

            let existingIds: Set<String> = try await databaseReader.read { db in
                let ids = try String.fetchAll(
                    db,
                    DBConversation.select(DBConversation.Columns.id)
                )
                return Set(ids)
            }

            var discoveredCount: Int = 0
            for group in groups where !existingIds.contains(group.id) {
                do {
                    let creatorInboxId = try await group.creatorInboxId()
                    let memberCount = try await group.members().count
                    if creatorInboxId == params.client.inboxId && memberCount <= 1 {
                        Log.debug("Skipping self-created single-member group: \(group.id)")
                        continue
                    }
                    try await streamProcessor.processConversation(group: group, params: params)
                    discoveredCount += 1
                } catch {
                    Log.error("Failed to process discovered conversation \(group.id): \(error)")
                }
            }

            if discoveredCount > 0 {
                Log.info("Discovered \(discoveredCount) new conversations after sync")
            }
        } catch {
            Log.error("Failed to discover new conversations: \(error)")
        }
    }

    /// Waits for both message and conversation streams to signal they're ready.
    /// Sets up stream readiness tracking by creating continuations that stream tasks will signal.
    /// Must be called BEFORE creating stream tasks to avoid race conditions.
    /// Returns the streams to wait on.
    private func setupStreamReadinessTracking() -> (messageStream: AsyncStream<Void>, conversationStream: AsyncStream<Void>) {
        let (messageReadyStream, messageReadyContinuation) = AsyncStream<Void>.makeStream()
        let (conversationReadyStream, conversationReadyContinuation) = AsyncStream<Void>.makeStream()

        messageStreamReadyContinuation = messageReadyContinuation
        conversationStreamReadyContinuation = conversationReadyContinuation

        return (messageReadyStream, conversationReadyStream)
    }

    /// Waits for streams to signal they've entered their async iteration loops.
    /// Uses continuations that are resumed by the stream functions when they enter their async loops.
    /// Includes a timeout to prevent indefinite blocking if streams fail to start.
    private func waitForStreamsToBeReady(
        messageStream: AsyncStream<Void>,
        conversationStream: AsyncStream<Void>
    ) async {
        await withTaskGroup(of: Void.self) { [messageStreamReadyContinuation, conversationStreamReadyContinuation] group in
            // Wait for message stream to signal ready
            group.addTask {
                for await _ in messageStream {
                    break
                }
            }

            // Wait for conversation stream to signal ready
            group.addTask {
                for await _ in conversationStream {
                    break
                }
            }

            // Timeout after 10 seconds to prevent indefinite blocking.
            // AsyncStream doesn't respond to task cancellation, so we must finish the
            // continuations to unblock the waiting tasks when timeout fires.
            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(10))
                    Log.warning("Stream ready timeout - proceeding anyway")
                    // Finish continuations so waiting tasks complete (AsyncStream ignores cancelAll)
                    messageStreamReadyContinuation?.finish()
                    conversationStreamReadyContinuation?.finish()
                } catch {
                    // Task was cancelled because streams signaled ready in time - no warning needed
                }
            }

            // Wait for both streams to be ready OR timeout
            var completedCount = 0
            for await _ in group {
                completedCount += 1
                if completedCount >= 2 {
                    // At least 2 tasks completed: either both streams ready,
                    // or one stream + timeout (acceptable fallback)
                    group.cancelAll()
                    break
                }
            }
        }

        // Clean up continuations
        messageStreamReadyContinuation = nil
        conversationStreamReadyContinuation = nil
    }

    /// Signals that the message stream has entered its async iteration loop.
    private func signalMessageStreamReady() {
        messageStreamReadyContinuation?.yield()
        messageStreamReadyContinuation?.finish()
        messageStreamReadyContinuation = nil
    }

    /// Signals that the conversation stream has entered its async iteration loop.
    private func signalConversationStreamReady() {
        conversationStreamReadyContinuation?.yield()
        conversationStreamReadyContinuation?.finish()
        conversationStreamReadyContinuation = nil
    }

    private func handlePause() async throws {
        guard case .ready(let params) = _state else {
            Log.warning("Cannot pause - not in ready state")
            return
        }

        Log.info("Pausing sync...")

        messageStreamTask?.cancel()
        conversationStreamTask?.cancel()
        dmStreamTask?.cancel()

        if let task = messageStreamTask {
            _ = await task.value
            messageStreamTask = nil
        }
        if let task = conversationStreamTask {
            _ = await task.value
            conversationStreamTask = nil
        }
        if let task = dmStreamTask {
            _ = await task.value
            dmStreamTask = nil
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
        dmStreamTask?.cancel()

        // Set up stream readiness tracking BEFORE creating tasks to avoid race conditions.
        let streams = setupStreamReadinessTracking()

        messageStreamTask = Task { [weak self, params] in
            guard let self else { return }
            await self.runMessageStream(params: params)
        }

        conversationStreamTask = Task { [weak self, params] in
            guard let self else { return }
            await self.runConversationStream(params: params)
        }

        if isXMTPiOSBacked(client: params.client) {
            dmStreamTask = Task { [weak self, params] in
                guard let self else { return }
                await self.runDmMessageStream(params: params)
            }
        }

        // Wait for streams to subscribe before transitioning to ready
        Log.debug("Waiting for streams to subscribe after resume...")
        await waitForStreamsToBeReady(messageStream: streams.messageStream, conversationStream: streams.conversationStream)

        // Re-sync to pick up any changes that occurred while paused/backgrounded.
        // The conversation stream only delivers new groups created after subscription,
        // so groups added while paused would be missed without this.
        do {
            let syncStart = CFAbsoluteTimeGetCurrent()
            // Gap 2: route through abstraction. Test doubles still see
            // a syncAllConversations call because the XMTPiOS adapter
            // forwards `syncAll` to the legacy provider.
            _ = try await params.client.conversations.syncAll(
                consentStates: params.consentStates
            )
            let syncElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - syncStart) * 1000)
            Log.info("[PERF] sync.resume_conversations: \(syncElapsed)ms")
        } catch {
            Log.error("syncAllConversations on resume failed: \(error)")
        }

        emitStateChange(.ready(params))
        Log.info("Sync resumed")

        await discoverNewConversations(params: params)
        await processJoinRequestsAfterSync(params: params)
    }

    func requestDiscovery() async {
        guard case .ready(let params) = _state else {
            Log.debug("requestDiscovery ignored - not in ready state (\(_state))")
            return
        }
        do {
            let syncStart = CFAbsoluteTimeGetCurrent()
            // Gap 2: abstraction-routed sync.
            _ = try await params.client.conversations.syncAll(
                consentStates: params.consentStates
            )
            let syncElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - syncStart) * 1000)
            Log.info("[PERF] sync.requestDiscovery: \(syncElapsed)ms")
            await discoverNewConversations(params: params)
        } catch {
            Log.error("requestDiscovery failed: \(error)")
        }
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
        dmStreamTask?.cancel()

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
        if let task = dmStreamTask {
            _ = await task.value
            dmStreamTask = nil
        }
    }

    // MARK: - Stream Management

    private func runMessageStream(params: SyncClientParams) async {
        var retryCount = 0

        while !Task.isCancelled && retryCount < maxStreamRetries {
            do {
                // Exponential backoff
                if retryCount > 0 {
                    let delay = TimeInterval.calculateExponentialBackoff(for: retryCount)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }

                Log.debug("Starting message stream (attempt \(retryCount + 1)/\(maxStreamRetries))")

                // Signal that we're about to subscribe to the stream (only on first attempt)
                if retryCount == 0 {
                    signalMessageStreamReady()
                }

                // Gap 2: drive both XMTPiOS and DTU lanes through the
                // abstraction-typed `streamAllMessages`. The XMTPiOS
                // adapter still bridges DecodedMessage → MessagingMessage
                // internally; the DTU adapter polls
                // `listMessagesAfter` against per-conversation cursors
                // (see DTUMessagingConversations.streamAllMessages).
                // For XMTPiOS-backed clients we additionally run a
                // sibling `runDmMessageStream` task at the actor level
                // so the DM / invite-flow back-channel — which is
                // XMTPiOS-only and consumes DecodedMessage directly —
                // keeps working.
                var isFirstMessage = true
                let stream = params.client.conversations.streamAllMessages(
                    filter: .all,
                    consentStates: params.consentStates,
                    onClose: {
                        Log.debug("Message stream closed via onClose callback")
                    }
                )

                for try await messagingMessage in stream {
                    // Check cancellation
                    try Task.checkCancellation()

                    // Reset retry count after first successful message (stream is healthy)
                    if isFirstMessage {
                        retryCount = 0
                        isFirstMessage = false
                    }

                    // Process message via abstraction — handles group
                    // persistence (and skips DM here; DM lane goes
                    // through `dmStreamTask`).
                    await streamProcessor.processMessage(
                        message: messagingMessage,
                        params: params,
                        activeConversationId: activeConversationId
                    )
                }

                // Stream ended (onClose was called and continuation finished)
                retryCount += 1
                Log.debug("Message stream ended...")
            } catch is CancellationError {
                Log.debug("Message stream cancelled")
                break
            } catch {
                retryCount += 1
                Log.error("Message stream error: \(error)")
            }
        }

        if !Task.isCancelled && retryCount >= maxStreamRetries {
            Log.error("Message stream: max retries (\(maxStreamRetries)) exceeded, giving up")
            enqueueAction(.streamFailed)
        }
    }

    private func runConversationStream(params: SyncClientParams) async {
        var retryCount = 0

        while !Task.isCancelled && retryCount < maxStreamRetries {
            do {
                if retryCount > 0 {
                    let delay = TimeInterval.calculateExponentialBackoff(for: retryCount)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }

                Log.debug("Starting conversation stream (attempt \(retryCount + 1)/\(maxStreamRetries))")

                // Signal that we're about to subscribe to the stream (only on first attempt)
                if retryCount == 0 {
                    signalConversationStreamReady()
                }

                // Gap 2: route conversation streaming through the
                // abstraction. The XMTPiOS adapter bridges
                // `XMTPiOS.Conversation.group(_)` → `MessagingConversation.group`
                // and the DTU adapter polls `listConversations`.
                var isFirstConversation = true
                let stream = params.client.conversations.streamAll(
                    filter: .groups,
                    onClose: {
                        Log.debug("Conversation stream closed via onClose callback")
                    }
                )
                for try await messagingConversation in stream {
                    guard case .group(let group) = messagingConversation else {
                        continue
                    }

                    // Check cancellation
                    try Task.checkCancellation()

                    // Reset retry count after first successful conversation (stream is healthy)
                    if isFirstConversation {
                        retryCount = 0
                        isFirstConversation = false
                    }

                    Log.info("Conversation stream delivered group: \(group.id)")

                    // Process conversation — catch errors to avoid restarting the stream
                    do {
                        try await streamProcessor.processConversation(
                            group: group,
                            params: params
                        )
                    } catch {
                        Log.error("Failed processing streamed conversation \(group.id): \(error)")
                    }
                }

                // Stream ended (onClose was called and continuation finished)
                retryCount += 1
                Log.debug("Conversation stream ended, will retry...")
            } catch is CancellationError {
                Log.debug("Conversation stream cancelled")
                break
            } catch {
                retryCount += 1
                Log.error("Conversation stream error: \(error)")
            }
        }

        if !Task.isCancelled && retryCount >= maxStreamRetries {
            Log.error("Conversation stream: max retries (\(maxStreamRetries)) exceeded, giving up")
            enqueueAction(.streamFailed)
        }
    }

    /// XMTPiOS-only DM/invite back-channel stream. Consumes
    /// `DecodedMessage` directly so the existing
    /// `processMessage(_ message:DecodedMessage,...)` path can decode
    /// invite-error payloads and route join requests through
    /// `InviteJoinRequestsManager`. Skipped on DTU-backed clients
    /// (DTU has no DM channel today; spawning is gated by
    /// `isXMTPiOSBacked` in `handleStart` / `handleResume`).
    private func runDmMessageStream(params: SyncClientParams) async {
        // The DM/invite back-channel is XMTPiOS-only; the spawn gate
        // (`isXMTPiOSBacked`) ensures we only get here for clients
        // backed by `XMTPiOSMessagingClient`. Reach the XMTPiOS
        // `Conversations.streamAllMessages` directly so we can keep
        // consuming `DecodedMessage` (still required for invite-error
        // payload decode + join-request routing).
        guard let xmtpiOS = params.client as? XMTPiOSMessagingClient else {
            Log.debug("DM stream skipped: client is not XMTPiOS-backed")
            return
        }
        let xmtpConversations = xmtpiOS.xmtpClient.conversations
        var retryCount = 0
        while !Task.isCancelled && retryCount < maxStreamRetries {
            do {
                if retryCount > 0 {
                    let delay = TimeInterval.calculateExponentialBackoff(for: retryCount)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                Log.debug("Starting DM message stream (attempt \(retryCount + 1)/\(maxStreamRetries))")
                let xmtpStates = params.consentStates.map(\.xmtpConsentState)
                let stream = xmtpConversations.streamAllMessages(
                    type: .dms,
                    consentStates: xmtpStates,
                    onClose: {
                        Log.debug("DM message stream closed via onClose callback")
                    }
                )
                var isFirstMessage = true
                for try await message in stream {
                    try Task.checkCancellation()
                    if isFirstMessage {
                        retryCount = 0
                        isFirstMessage = false
                    }
                    await streamProcessor.processMessage(
                        message,
                        params: params,
                        activeConversationId: activeConversationId
                    )
                }
                retryCount += 1
                Log.debug("DM message stream ended")
            } catch is CancellationError {
                Log.debug("DM message stream cancelled")
                break
            } catch {
                retryCount += 1
                Log.error("DM message stream error: \(error)")
            }
        }
    }

    /// True when the client is XMTPiOS-backed and can therefore drive
    /// the DM/invite back-channel stream (which still consumes
    /// `DecodedMessage` directly). DTU-backed clients return false —
    /// DTU has no DM channel today.
    private func isXMTPiOSBacked(client: any MessagingClient) -> Bool {
        return (client as? XMTPiOSMessagingClient) != nil
    }

    // MARK: - Mutation

    func setActiveConversationId(_ conversationId: String?) {
        // Update the active conversation
        activeConversationId = conversationId
    }

    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) async {
        await streamProcessor.setInviteJoinErrorHandler(handler)
    }

    func setTypingIndicatorHandler(_ handler: @escaping @Sendable (String, String, Bool) -> Void) async {
        await streamProcessor.setTypingIndicatorHandler(handler)
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
