import ConvosConnections
import ConvosInvites
import ConvosMetrics
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
    func requestDiscovery() async
    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) async
    func setTypingIndicatorHandler(_ handler: @escaping @Sendable (String, String, Bool) -> Void) async

    /// Safety net for a join request the message stream never delivered.
    /// Polls for unprocessed join-request DMs for a bounded window after the
    /// user does something that invites someone, processing anything the
    /// stream missed. See `SyncingManager.startJoinRequestPolling`.
    ///
    /// The stream dying loudly is handled by the state machine, which now
    /// restarts on `.resume`. This covers the case it cannot see: a stream
    /// that is nominally alive and silently delivering nothing.
    func startJoinRequestPolling(reason: JoinRequestPollReason) async

    /// Drain the backlog of activity since `cursor` in one batched transaction,
    /// before streams resume. Runs the message-side `BatchCatchUp` and the
    /// invite-side `InviteJoinRequestsManager.processJoinRequestOutcomes`
    /// sequentially, both keyed off the same cursor.
    ///
    /// Returns silently on best-effort failure — the stream path that follows
    /// is the safety net (per-event handlers still pick up anything the batch
    /// missed).
    nonisolated func runBatchCatchUp(client: AnyClientProvider, since: Date?) async

    /// Message-side catch-up that ignores every cursor and re-ingests all
    /// messages libxmtp holds locally. Run after a history-archive import
    /// (post-pairing): imported messages predate the cursors and emit no
    /// stream events, so the regular forward-only paths never see them.
    nonisolated func runHistoryBackfill(client: AnyClientProvider) async
}

/// Wrapper for client and API client parameters used in state transitions
///
/// Marked @unchecked Sendable because:
/// - XMTPClientProvider wraps XMTPiOS.Client which is not Sendable
/// - ConvosAPIClient is marked @unchecked Sendable
public struct SyncClientParams: @unchecked Sendable {
    public let client: AnyClientProvider
    public let apiClient: any ConvosAPIClientProtocol
    public let consentStates: [ConsentState]

    public init(client: AnyClientProvider, apiClient: any ConvosAPIClientProtocol, consentStates: [ConsentState] = [.allowed, .unknown]) {
        self.client = client
        self.apiClient = apiClient
        self.consentStates = consentStates
    }
}

/// Carries the non-Sendable client across the `withTimeout` task boundary in
/// `runGlobalSync`. Same rationale as `SyncClientParams` above; scoped down
/// because that path has no API client in hand.
private struct UncheckedClientBox: @unchecked Sendable {
    let client: AnyClientProvider
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

/// What prompted a join-request poll. The poll itself is identical either
/// way - `processJoinRequestOutcomes` has never been agent-specific - but a
/// rescue means something different depending on who was kept waiting, so
/// the two report separately.
public enum JoinRequestPollReason: Sendable {
    /// The user asked an assistant to join. The assistant polls the network
    /// and gives up after 60s.
    case assistantJoin
    /// The user surfaced an invite - shared the link or put the code on
    /// screen - so a person may be trying to join right now. They watch
    /// "Verifying" for 150s before it times out.
    case inviteShared

    var logLabel: String {
        switch self {
        case .assistantJoin: return "assistant-join"
        case .inviteShared: return "invite-shared"
        }
    }
}

// swiftlint:disable:next type_body_length
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
    let streamProcessor: any StreamProcessorProtocol
    // Maximum consecutive stream failures before giving up. Prevents FD exhaustion when
    // XMTP service is unavailable (each failed connection attempt can leak file descriptors).
    // Injectable so tests can reach the exhausted/`.error` state without sitting through
    // the full ~2.5 minute backoff ladder.
    private let maxStreamRetries: Int

    private var messageStreamTask: Task<Void, Never>?
    private var conversationStreamTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?

    /// The params of the most recent `start`, retained so a session that has
    /// fallen into `.error` can be restarted from a plain `.resume`.
    ///
    /// `.error` carries only the `Error`, so without this the state machine
    /// had nothing to restart *with* and every recovery trigger the app sends
    /// (foreground, network reconnect) is a `.resume` that could only be
    /// dropped. Cleared on `stop` so a stopped session is never resurrected.
    private var lastClientParams: SyncClientParams?

    /// Temporary diagnostic state for the agent-join poll. The task is the
    /// bounded polling loop; the date stamps the last message the stream
    /// actually delivered, so poll logs can report how stale the stream is.
    private var joinRequestPollTask: Task<Void, Never>?
    private var lastMessageStreamEventDate: Date?

    /// Reconciles conversation consent against contact-block state (the
    /// source of truth for feed visibility). Reconstructed per session
    /// start because it captures the live XMTP client.
    private var consentReconciler: ConversationConsentReconciler?
    private var consentBackupMirror: ConsentBackupMirror?

    /// Populates the agent-template read-through cache for template-backed
    /// agent contacts. Reconstructed per start because it captures the
    /// live API client.
    private var agentTemplateCacheCoordinator: AgentTemplateCacheCoordinator?

    private var activeConversationId: String?
    /// The folded agent DM currently on screen (the Agent tab), tracked
    /// separately: the DM is its own conversation whose id never appears in
    /// `activeConversationChanged` (that carries the parent group id).
    private var activeDmConversationId: String?

    // Stream readiness tracking - used to wait for streams to subscribe before signaling ready
    private var messageStreamReadyContinuation: AsyncStream<Void>.Continuation?
    private var conversationStreamReadyContinuation: AsyncStream<Void>.Continuation?

    // State machine
    var _state: State = .idle
    private var actionQueue: [Action] = []

    var isSyncReady: Bool {
        if case .ready = _state { return true }
        return false
    }

    /// True once the streams have exhausted their retry budget and the manager
    /// has fallen into `.error`. Distinct from `!isSyncReady`, which is also
    /// true for the transient `.starting` state - tests need to tell the
    /// terminal state apart from the in-flight one.
    var hasGivenUpOnStreams: Bool {
        if case .error = _state { return true }
        return false
    }
    private var isProcessing: Bool = false
    private var currentTask: Task<Void, Never>?

    // Notification handling
    // Safe to use nonisolated(unsafe) because the array is only mutated during actor-isolated
    // setup, and deinit only runs after all actor tasks complete (no concurrent access possible).
    nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []
    private var notificationTask: Task<Void, Never>?

    // MARK: - Initialization

    private let databaseReader: any DatabaseReader
    /// Held for foreground batch catch-up construction; not used elsewhere
    /// since the stream path's writers live inside `streamProcessor`.
    private let databaseWriter: any DatabaseWriter
    /// Threaded into the writers constructed both at init (the stream
    /// processor's `ConversationWriter`) and per-call inside the foreground
    /// batch catch-up path so metrics-emitting writes have a real sink.
    private let coreActions: any CoreActions

    init(identityStore: any KeychainIdentityStoreProtocol,
         databaseWriter: any DatabaseWriter,
         databaseReader: any DatabaseReader,
         deviceRegistrationManager: (any DeviceRegistrationManagerProtocol)? = nil,
         notificationCenter: any UserNotificationCenterProtocol,
         deviceConnections: DeviceConnectionsBundle = .none,
         maxStreamRetries: Int = 10,
         coreActions: any CoreActions) {
        self.maxStreamRetries = maxStreamRetries
        self.identityStore = identityStore
        self.databaseReader = databaseReader
        self.databaseWriter = databaseWriter
        self.coreActions = coreActions
        let enablementStore: any EnablementStore = GRDBEnablementStore(dbWriter: databaseWriter, dbReader: databaseReader)
        // The GRDB-backed subscription store is a Core-side type that doesn't
        // pull HealthKit; safe to construct unconditionally. The HKHealthStore-
        // backed gateway/reader/registrar come in via `deviceConnections.health`
        // when the host links the `ConvosConnectionsHealth` product.
        let healthSubscriptionStore = GRDBHealthBackgroundSubscriptionStore(
            dbWriter: databaseWriter,
            dbReader: databaseReader
        )
        let invocationRuntime = makeInvocationRuntime(
            enablementStore: enablementStore,
            healthSubscriptionStore: healthSubscriptionStore,
            deviceConnections: deviceConnections
        )
        self.streamProcessor = StreamProcessor(
            identityStore: identityStore,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader,
            deviceRegistrationManager: deviceRegistrationManager,
            notificationCenter: notificationCenter,
            invocationRuntime: invocationRuntime,
            coreActions: coreActions
        )
    }

    deinit {
        // Clean up tasks
        consentReconciler?.stop()
        consentBackupMirror?.stop()
        agentTemplateCacheCoordinator?.stop()
        syncTask?.cancel()
        notificationTask?.cancel()
        messageStreamTask?.cancel()
        conversationStreamTask?.cancel()
        joinRequestPollTask?.cancel()
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
        // Wait for the pause to actually take effect before returning. The
        // backgrounding path drops the SQLCipher connection right after this
        // call; returning early let it yank the pool out from under in-flight
        // stream work, which then burned retries on "Pool needs to reconnect"
        // until foreground. Waits through .starting too - a pause there only
        // sets pauseOnComplete and lands after the startup sync finishes.
        // Exits immediately from any other state (the pause is a no-op there).
        let maxWaitTime = 5.0
        let startTime = Date()
        while true {
            switch _state {
            case .ready, .starting:
                break
            default:
                return
            }
            if Date().timeIntervalSince(startTime) > maxWaitTime {
                Log.error("Pause timeout - state: \(_state)")
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    func resume() async {
        enqueueAction(.resume)
    }

    /// `nonisolated` so the call doesn't enter the actor's isolation domain
    /// — the only state it touches is the immutable `let identityStore` and
    /// `let databaseWriter`, both safely shareable. This avoids strict-
    /// concurrency tripping on the non-Sendable `AnyClientProvider` being
    /// passed to BatchCatchUp / InviteJoinRequestsManager from inside an
    /// actor. The stream-resume that follows is unaffected because it goes
    /// through the actor's normal `enqueueAction(.resume)` path.
    nonisolated func runBatchCatchUp(client: AnyClientProvider, since: Date?) async {
        let globalSyncCompleted = await runGlobalSync(client: client)
        await runMessageBatch(client: client, since: since, syncPerConversation: !globalSyncCompleted)
        await runInviteBatch(client: client, since: since)
    }

    /// One client-wide `syncAllConversations` before the local batch. libxmtp
    /// makes a single batched newest-message-metadata call and then syncs
    /// only the groups with new server activity, capped at 10 concurrent -
    /// which is why the batch's prepare phase can skip its per-group
    /// `conversation.sync()` (`syncFirst: false`): the backlog is already in
    /// libxmtp's local store by the time `listGroups` + `messages(afterNs:)`
    /// read it. Time-boxed so a hung sync cannot stall boot.
    ///
    /// Returns whether the sync completed. On timeout or failure the batch
    /// still runs, but with per-conversation syncs restored: fetching from
    /// an unsynced local store could advance catch-up cursors past backlog
    /// that the still-running sync materializes later, permanently skipping
    /// it (streams only deliver forward from connection time).
    private nonisolated func runGlobalSync(client: AnyClientProvider) async -> Bool {
        let box = UncheckedClientBox(client: client)
        let started = CFAbsoluteTimeGetCurrent()
        do {
            try await BatchCatchUp.withTimeout(seconds: Constant.globalSyncTimeout) {
                _ = try await box.client.conversationsProvider.syncAllConversations(
                    consentStates: [.allowed, .unknown]
                )
            }
            let elapsed = CFAbsoluteTimeGetCurrent() - started
            Log.info("[PERF] catchup.global_sync: \(Int(elapsed * 1000))ms")
            return true
        } catch is BatchCatchUpPrepareTimeout {
            Log.warning("[PERF] catchup.global_sync timed out after \(Int(Constant.globalSyncTimeout))s; running batch with per-conversation syncs")
            return false
        } catch {
            Log.error("catchup.global_sync failed: \(error.localizedDescription); running batch with per-conversation syncs")
            return false
        }
    }

    nonisolated func runHistoryBackfill(client: AnyClientProvider) async {
        let result = await runMessageBatch(client: client, since: nil, fetchFromBeginning: true)
        if let result {
            QAEvent.emit(.pairing, "history_backfill_ran", [
                "conversations": "\(result.conversationsProcessed)",
                "messages": "\(result.messagesProcessed)"
            ])
        }
    }

    /// `syncPerConversation` is passed through to `BatchCatchUp.run`; see
    /// its doc for the cursor-safety contract. Callers other than
    /// `runBatchCatchUp` leave it off because their paths sync beforehand
    /// (the agent-join poll syncs every tick) or read data that never came
    /// from the network (the history-archive backfill).
    @discardableResult
    private nonisolated func runMessageBatch(
        client: AnyClientProvider,
        since: Date?,
        fetchFromBeginning: Bool = false,
        syncPerConversation: Bool = false
    ) async -> BatchCatchUpResult? {
        do {
            guard let identity = try await identityStore.load() else {
                Log.debug("catchup.batch.messages: no identity, skipping")
                return nil
            }
            let messageWriter = IncomingMessageWriter(databaseWriter: databaseWriter)
            let conversationWriter = ConversationWriter(
                identityStore: identityStore,
                databaseWriter: databaseWriter,
                messageWriter: messageWriter,
                coreActions: coreActions
            )
            let batch = BatchCatchUp(
                conversationWriter: conversationWriter,
                messageWriter: messageWriter,
                databaseWriter: databaseWriter
            )
            return try await batch.run(
                client: client,
                inboxId: identity.inboxId,
                since: since,
                activeConversationIds: await activeConversationIds,
                fetchFromBeginning: fetchFromBeginning,
                syncPerConversation: syncPerConversation
            )
        } catch {
            Log.error("catchup.batch.messages failed: \(error.localizedDescription)")
            return nil
        }
    }

    private nonisolated func runInviteBatch(client: AnyClientProvider, since: Date?) async {
        let started = CFAbsoluteTimeGetCurrent()
        let manager = InviteJoinRequestsManager(
            identityStore: identityStore,
            databaseWriter: databaseWriter
        )
        let outcomes = await manager.processJoinRequestOutcomes(since: since, client: client)
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        Log.info("[PERF] catchup.batch.invites: \(Int(elapsed * 1000))ms outcomes=\(outcomes.count)")
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

            case (.error, .resume):
                // Every recovery trigger the app has - returning to the
                // foreground, the network monitor reconnecting - sends
                // `.resume`, never `.start`. Dropping it here made `.error`
                // terminal for the life of the process: streams stay
                // cancelled, so nothing arrives over them and no further
                // catch-up runs, while the session layer stays `.ready` and
                // the UI keeps looking healthy. Restart from the retained
                // params instead. If the underlying failure is still there
                // the streams simply exhaust again, which makes this state
                // transient rather than permanent - and the retry ladder
                // (~2.5 minutes) rate-limits the attempts on its own.
                guard let params = lastClientParams else {
                    Log.warning("Sync is in error state with no retained client params - cannot recover")
                    break
                }
                Log.info("Recovering sync from error state")
                try await handleStart(client: params.client, apiClient: params.apiClient)

            case (.error, .pause):
                // Streams were already cancelled on the way into `.error`,
                // so there is nothing to pause. Backgrounding a errored
                // session is expected, not an invalid transition.
                Log.debug("Pause requested while in error state - nothing to pause")

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

    private func handleStart(client: AnyClientProvider, apiClient: any ConvosAPIClientProtocol) async throws {
        let params = SyncClientParams(client: client, apiClient: apiClient)
        lastClientParams = params
        emitStateChange(.starting(params, pauseOnComplete: false))

        // Setup notifications if not already done
        if notificationObservers.isEmpty {
            setupNotificationObservers()
        }

        // Start streams first
        Log.info("Starting message and conversation streams...")
        messageStreamTask?.cancel()
        conversationStreamTask?.cancel()

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

        restartConsentReconciler(client: client)
        restartAgentTemplateCacheCoordinator(apiClient: apiClient)

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
                _ = try await params.client.conversationsProvider.syncAllConversations(consentStates: params.consentStates)
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
            // Mirror handlePause: tear down the session-scoped observers (consent
            // reconciler + agent-template cache coordinator) before pausing, so
            // they don't keep observing while the inbox is paused.
            stopSessionScopedObservers()
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
            Log.debug("syncAllConversations completed, transitioned to paused (pause was requested during starting)")
        } else {
            emitStateChange(.ready(params))
            Log.info("syncAllConversations completed, sync ready")
            QAEvent.emit(.sync, "completed")

            // Discover any XMTP groups that the conversation stream missed.
            // This handles cases where the joiner was added to a group while
            // the inbox was paused, stopped, or the stream had a timeout.
            await discoverNewConversations(params: params)

            await streamProcessor.reconcilePushSubscriptions(
                params: params,
                context: "after initial sync"
            )
        }
    }

    /// Lists all XMTP groups and processes any that are missing from the local database.
    ///
    /// After syncAllConversations syncs the XMTP data layer, the local DB may still be
    /// missing groups that the conversation stream failed to deliver (e.g., stream timeout,
    /// inbox paused during approval, app backgrounded). This method provides a fallback
    /// by listing all groups and storing any that aren't already in the DB.
    ///
    /// Returns the count of conversations actually processed and written. The count is
    /// load-bearing for `requestDiscovery`'s D3 gate: when the join-poll fires every 3
    /// seconds while waiting for a welcome that hasn't arrived yet, count==0 short-circuits
    /// the downstream push reconcile so the device stops flooding `/v2/notifications/subscribe`.
    /// A best-effort listing failure returns 0 (treat "I couldn't tell" as "nothing new"
    /// so we don't reconcile on a partial signal).
    @discardableResult
    private func discoverNewConversations(params: SyncClientParams) async -> Int {
        do {
            let groups = try params.client.conversationsProvider.listGroups(
                createdAfterNs: nil,
                createdBeforeNs: nil,
                lastActivityAfterNs: nil,
                lastActivityBeforeNs: nil,
                limit: nil,
                consentStates: params.consentStates,
                orderBy: .lastActivity
            )

            let existingIds: Set<String> = try await databaseReader.read { db in
                let ids = try String.fetchAll(
                    db,
                    DBConversation.select(DBConversation.Columns.id)
                )
                return Set(ids)
            }

            let missingGroups = groups.filter { !existingIds.contains($0.id) }
            guard !missingGroups.isEmpty else { return 0 }

            // The self-created-single-member pre-check costs two FFI calls
            // per group; run those in a bounded window. Processing stays
            // sequential below: `streamProcessor` is an actor, so concurrent
            // calls would serialize there anyway, and its per-conversation
            // writes are better off not contending for the GRDB writer.
            let currentInboxId = params.client.inboxId
            let groupsToProcess: [XMTPiOS.Group] = await withTaskGroup(
                of: (index: Int, group: XMTPiOS.Group)?.self
            ) { taskGroup in
                @Sendable func precheckTask(index: Int, group: XMTPiOS.Group) async -> (index: Int, group: XMTPiOS.Group)? {
                    do {
                        let creatorInboxId = try await group.creatorInboxId()
                        let memberCount = try await group.members.count
                        if creatorInboxId == currentInboxId && memberCount <= 1 {
                            Log.debug("Skipping self-created single-member group: \(group.id)")
                            return nil
                        }
                        return (index, group)
                    } catch {
                        Log.error("Failed pre-checking discovered conversation \(group.id): \(error)")
                        return nil
                    }
                }

                var iterator = missingGroups.enumerated().makeIterator()
                var inFlight = 0
                while inFlight < Constant.maxConcurrentDiscoverPrechecks, let (index, group) = iterator.next() {
                    taskGroup.addTask { await precheckTask(index: index, group: group) }
                    inFlight += 1
                }

                var passed: [(index: Int, group: XMTPiOS.Group)] = []
                while let result = await taskGroup.next() {
                    if let result {
                        passed.append(result)
                    }
                    if let (index, group) = iterator.next() {
                        taskGroup.addTask { await precheckTask(index: index, group: group) }
                    }
                }
                return passed
                    .sorted { $0.index < $1.index }
                    .map(\.group)
            }

            var discoveredCount: Int = 0
            for group in groupsToProcess {
                do {
                    try await streamProcessor.processConversation(group, params: params)
                    discoveredCount += 1
                } catch {
                    Log.error("Failed to process discovered conversation \(group.id): \(error)")
                }
            }

            if discoveredCount > 0 {
                Log.info("Discovered \(discoveredCount) new conversations after sync")
            }
            return discoveredCount
        } catch {
            Log.error("Failed to discover new conversations: \(error)")
            return 0
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

        stopSessionScopedObservers()
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

        restartConsentReconciler(client: params.client)
        restartAgentTemplateCacheCoordinator(apiClient: params.apiClient)

        // Wait for streams to subscribe before transitioning to ready
        Log.debug("Waiting for streams to subscribe after resume...")
        await waitForStreamsToBeReady(messageStream: streams.messageStream, conversationStream: streams.conversationStream)

        // Re-sync to pick up any changes that occurred while paused/backgrounded.
        // The conversation stream only delivers new groups created after subscription,
        // so groups added while paused would be missed without this.
        do {
            let syncStart = CFAbsoluteTimeGetCurrent()
            _ = try await params.client.conversationsProvider.syncAllConversations(consentStates: params.consentStates)
            let syncElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - syncStart) * 1000)
            Log.info("[PERF] sync.resume_conversations: \(syncElapsed)ms")
        } catch {
            Log.error("syncAllConversations on resume failed: \(error)")
        }

        emitStateChange(.ready(params))
        Log.info("Sync resumed")

        await discoverNewConversations(params: params)
        await streamProcessor.reconcilePushSubscriptions(
            params: params,
            context: "after resume"
        )
    }

    // D3: ConversationStateMachine.joinFlow polls requestDiscovery every 3s
    // while waiting for the joined group. Before this gate, every tick fired
    // a full /v2/notifications/subscribe (topicCount: 50 in Datadog). Now we
    // only reconcile when discoverNewConversations actually wrote a new row.
    // Token rotation is brought through by the .convosPushTokenDidChange
    // listener (D14), not through here.
    /// Force-drop the iOS-side push topic hash cache. Exposed for sign-out /
    /// "Delete all data" paths AND for tests that need a deterministic
    /// cache-miss without going through the global PushNotificationRegistrar
    /// singleton (which other test suites mutate via resetForTesting and
    /// would race against). Production callers should NOT invoke this on
    /// every resume — the cache key partitioning handles routine state
    /// changes naturally.
    func clearPushSubscriptionCache() async {
        await streamProcessor.clearPushSubscriptionCache()
    }

    func requestDiscovery() async {
        guard case .ready(let params) = _state else {
            Log.debug("requestDiscovery ignored - not in ready state (\(_state))")
            return
        }
        do {
            let syncStart = CFAbsoluteTimeGetCurrent()
            _ = try await params.client.conversationsProvider.syncAllConversations(consentStates: params.consentStates)
            let syncElapsed = String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - syncStart) * 1000)
            Log.info("[PERF] sync.requestDiscovery: \(syncElapsed)ms")
            let discoveredCount = await discoverNewConversations(params: params)
            guard discoveredCount > 0 else {
                Log.debug("requestDiscovery: no new conversations, skipping push topic reconcile")
                return
            }
            await streamProcessor.reconcilePushSubscriptions(
                params: params,
                context: "after requested discovery"
            )
        } catch {
            Log.error("requestDiscovery failed: \(error)")
        }
    }

    private func handleStop() async throws {
        Log.info("Stopping sync...")
        emitStateChange(.stopping)

        await cancelAndAwaitTasks()
        activeConversationId = nil
        // A stopped session must not be revivable by a stray `.resume`.
        lastClientParams = nil

        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        notificationObservers.removeAll()

        emitStateChange(.idle)
        Log.info("Sync stopped")
    }

    private func cancelAndAwaitTasks() async {
        stopSessionScopedObservers()
        syncTask?.cancel()
        messageStreamTask?.cancel()
        conversationStreamTask?.cancel()
        joinRequestPollTask?.cancel()

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
        if let task = joinRequestPollTask {
            _ = await task.value
            joinRequestPollTask = nil
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

                // Stream messages - the loop will exit when onClose is called and continuation.finish() happens
                var isFirstMessage = true
                let stream = params.client.conversationsProvider.streamAllMessages(
                    type: .all,
                    consentStates: params.consentStates,
                    onClose: {
                        Log.debug("Message stream closed via onClose callback")
                    }
                )

                // Signal readiness once the SDK call has returned so the
                // channel is established by the time anyone observing
                // `isSyncReady` sees true.
                if retryCount == 0 {
                    signalMessageStreamReady()
                }

                for try await message in stream {
                    // Check cancellation
                    try Task.checkCancellation()

                    // Diagnostic stamp for the agent-join poll: how recently
                    // the message stream actually delivered anything.
                    lastMessageStreamEventDate = Date()

                    // Reset retry count after first successful message (stream is healthy)
                    if isFirstMessage {
                        retryCount = 0
                        isFirstMessage = false
                    }

                    // Process message
                    await streamProcessor.processMessage(
                        message,
                        params: params,
                        activeConversationIds: activeConversationIds
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

                // Stream conversations - the loop will exit when onClose is called
                var isFirstConversation = true
                let stream = params.client.conversationsProvider.stream(
                    type: .groups,
                    onClose: {
                        Log.debug("Conversation stream closed via onClose callback")
                    }
                )
                for try await conversation in stream {
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

                    Log.info("Conversation stream delivered group: \(conversation.id)")

                    // Process conversation — catch errors to avoid restarting the stream
                    do {
                        try await streamProcessor.processConversation(
                            conversation,
                            params: params
                        )
                    } catch {
                        Log.error("Failed processing streamed conversation \(conversation.id): \(error)")
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
}

// MARK: - Mutation

extension SyncingManager {
    func setActiveConversationId(_ conversationId: String?) {
        // Update the active conversation
        activeConversationId = conversationId
    }

    func setActiveDmConversationId(_ conversationId: String?) {
        activeDmConversationId = conversationId
    }

    /// The conversations exempt from unread marking right now: the active
    /// group and, when the Agent tab is up, its folded DM.
    var activeConversationIds: Set<String> {
        Set([activeConversationId, activeDmConversationId].compactMap { $0 })
    }

    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) async {
        await streamProcessor.setInviteJoinErrorHandler(handler)
    }

    func setTypingIndicatorHandler(_ handler: @escaping @Sendable (String, String, Bool) -> Void) async {
        await streamProcessor.setTypingIndicatorHandler(handler)
    }
}

// MARK: - Agent Join Request Polling (temporary diagnostic)

extension SyncingManager {
    /// Bounded polling fallback for agent join requests. Agents join by
    /// sending a join-request DM to the conversation creator; that DM is
    /// normally picked up by the message stream. When the stream dies
    /// silently the request is never processed and the agent backend gives
    /// up after about two minutes. While we diagnose the stream issue, this
    /// polls the network for a short window after each agents/join call and
    /// processes anything the stream missed, logging loudly when that
    /// happens so stream death is observable in the logs.
    ///
    /// Re-processing a request the stream already handled is safe: the
    /// coordinator returns `.alreadyMember` (no re-add, no duplicate
    /// snapshot), which also keeps the "stream missed it" log signal free
    /// of false positives.
    func startJoinRequestPolling(reason: JoinRequestPollReason) {
        // A second trigger inside an in-flight window (sharing a link right
        // after showing the code, say) rebases the window rather than
        // running two loops over the same DMs.
        joinRequestPollTask?.cancel()
        let startedAt = Date()
        Log.info("[join-poll] starting (\(reason.logLabel)): every \(Int(Constant.joinPollInterval))s for \(Int(Constant.joinPollWindow))s")
        joinRequestPollTask = Task { [weak self] in
            await self?.runJoinRequestPolling(startedAt: startedAt, reason: reason)
        }
    }

    private func runJoinRequestPolling(startedAt: Date, reason: JoinRequestPollReason) async {
        var cursor = startedAt.addingTimeInterval(-Constant.joinPollCursorOverlap)
        let deadline = startedAt.addingTimeInterval(Constant.joinPollWindow)
        var tick = 0
        while !Task.isCancelled && Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: UInt64(Constant.joinPollInterval * 1_000_000_000))
            } catch {
                break
            }
            tick += 1
            guard case .ready(let params) = _state else {
                Log.debug("[join-poll] tick \(tick) skipped - sync not ready (\(_state))")
                continue
            }
            let tickStartedAt = Date()
            do {
                _ = try await params.client.conversationsProvider.syncAllConversations(consentStates: params.consentStates)
            } catch {
                Log.warning("[join-poll] tick \(tick): syncAllConversations failed, will retry: \(error)")
                continue
            }
            let acceptedCount = await runJoinPollBatch(params: params, since: cursor)
            if acceptedCount > 0 {
                let streamAgeSecs: Float = lastMessageStreamEventDate.map { Float(Date().timeIntervalSince($0)) } ?? -1
                let lastStreamEvent: String = streamAgeSecs >= 0 ? "\(Int(streamAgeSecs))s ago" : "never"
                Log.warning(
                    "[join-poll] tick \(tick) (\(reason.logLabel)): accepted \(acceptedCount) join request(s) the message stream had not processed" +
                    " (last stream message: \(lastStreamEvent)) - message stream is likely dead"
                )
                switch reason {
                case .assistantJoin:
                    await coreActions.assistantJoinRescuedByPolling(streamAgeSecs: streamAgeSecs, pollTick: tick)
                case .inviteShared:
                    // `assistantJoinRescuedByPolling` is the only rescue metric
                    // the shared catalog defines, and reporting a person's join
                    // through it would silently corrupt the assistant funnel.
                    // Invite rescues are warning-logged above until the catalog
                    // gains a matching event.
                    break
                }
            } else {
                Log.debug("[join-poll] tick \(tick): no unprocessed join requests")
            }
            cursor = tickStartedAt.addingTimeInterval(-Constant.joinPollCursorOverlap)
        }
        Log.info("[join-poll] finished after \(tick) tick(s)")
    }

    /// Processes join-request DMs since `since`, then pulls the message-side
    /// backlog so the resulting membership change (group_updated) lands in
    /// the local database even while the stream is down. Returns the number
    /// of join requests this pass actually accepted - requests another path
    /// already handled surface as `.alreadyMember` and don't count, so a
    /// healthy stream keeps this at zero.
    ///
    /// `nonisolated` for the same reason as `runBatchCatchUp`: the only
    /// state it touches is the immutable `identityStore` / `databaseWriter`,
    /// and it keeps the non-Sendable client out of the actor's isolation
    /// domain.
    private nonisolated func runJoinPollBatch(params: SyncClientParams, since: Date?) async -> Int {
        let client = params.client
        let manager = InviteJoinRequestsManager(
            identityStore: identityStore,
            databaseWriter: databaseWriter
        )
        let outcomes = await manager.processJoinRequestOutcomes(since: since, client: client)
        var acceptedCount = 0
        for outcome in outcomes {
            if case .accepted = outcome {
                acceptedCount += 1
            }
        }
        await runMessageBatch(client: client, since: since)
        return acceptedCount
    }

    private enum Constant {
        /// Budget for the client-wide sync that precedes a batch catch-up.
        /// Generous: libxmtp syncs changed groups 10 at a time, so even a
        /// heavy backlog normally finishes well inside this; a hung sync
        /// becomes a skip rather than an indefinite boot stall.
        static let globalSyncTimeout: TimeInterval = 60
        /// Sliding-window width for the per-group FFI pre-checks in
        /// `discoverNewConversations`.
        static let maxConcurrentDiscoverPrechecks: Int = 4
        /// How often the temporary agent-join poll checks for unprocessed
        /// join requests.
        static let joinPollInterval: TimeInterval = 5
        /// How long the poll keeps checking after an agents/join call. The
        /// agent backend gives up after about two minutes; poll a bit past
        /// that so the tail end of the window is still observable.
        static let joinPollWindow: TimeInterval = 150
        /// Back-overlap applied when advancing the poll cursor so messages
        /// that land while a sync pass is in flight aren't skipped by the
        /// next tick.
        static let joinPollCursorOverlap: TimeInterval = 5
    }
}

extension SyncingManager {
    // MARK: - Notification Observers

    fileprivate func setupNotificationObservers() {
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
        let activeDmObserver = NotificationCenter.default.addObserver(
            forName: .activeDmConversationChanged,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            let conversationId = notification.userInfo?["conversationId"] as? String
            Task { [weak self] in
                await self?.setActiveDmConversationId(conversationId)
            }
        }
        notificationObservers.append(activeDmObserver)
        installPushTokenObserver()
    }

    /// Stop and clear the session-scoped observers (consent reconciler,
    /// consent backup mirror, and agent-template cache coordinator) on
    /// pause / teardown.
    fileprivate func stopSessionScopedObservers() {
        consentReconciler?.stop()
        consentReconciler = nil
        consentBackupMirror?.stop()
        consentBackupMirror = nil
        agentTemplateCacheCoordinator?.stop()
        agentTemplateCacheCoordinator = nil
    }

    /// (Re)start the consent reconciler and the consent backup mirror with
    /// the live client. Safe to call on every start / resume - the
    /// previous instances are stopped first.
    fileprivate func restartConsentReconciler(client: AnyClientProvider) {
        consentReconciler?.stop()
        let reconciler = ConversationConsentReconciler(
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            client: client
        )
        reconciler.start()
        consentReconciler = reconciler

        consentBackupMirror?.stop()
        let mirror = ConsentBackupMirror(
            databaseReader: databaseReader,
            identityStore: identityStore
        )
        mirror.start()
        consentBackupMirror = mirror
    }

    /// (Re)start the agent-template cache coordinator with the live API
    /// client. Safe to call on every start / resume - the previous instance
    /// is stopped first.
    fileprivate func restartAgentTemplateCacheCoordinator(apiClient: any ConvosAPIClientProtocol) {
        agentTemplateCacheCoordinator?.stop()
        let coordinator = AgentTemplateCacheCoordinator(
            databaseReader: databaseReader,
            apiClient: apiClient,
            cacheWriter: AgentTemplateCacheWriter(databaseWriter: databaseWriter)
        )
        coordinator.start()
        agentTemplateCacheCoordinator = coordinator
    }
}

private func makeInvocationRuntime(
    enablementStore: any EnablementStore,
    healthSubscriptionStore: any HealthBackgroundSubscriptionStore,
    deviceConnections: DeviceConnectionsBundle
) -> ConnectionInvocationRuntime {
    if let health = deviceConnections.health {
        return ConnectionInvocationRuntime(
            store: enablementStore,
            dataSources: deviceConnections.dataSources,
            dataSinks: deviceConnections.dataSinks,
            healthSubscriptionStore: healthSubscriptionStore,
            healthGateway: health.backgroundDeliveryGateway,
            healthBackfillReader: health.backfillReader,
            healthDeltaReader: health.deltaReader,
            healthRegistrar: health.observerRegistrar
        )
    }
    return ConnectionInvocationRuntime(
        store: enablementStore,
        dataSources: deviceConnections.dataSources,
        dataSinks: deviceConnections.dataSinks
    )
}
