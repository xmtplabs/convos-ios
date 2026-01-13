import Combine
import Foundation
import GRDB
import XMTPiOS

public struct ConversationReadyResult {
    public enum Origin {
        case created
        case joined
        case existing
    }

    public let conversationId: String
    public let origin: Origin
}

/// State machine managing conversation creation and joining flows
///
/// ConversationStateMachine handles the lifecycle of creating a new conversation or joining
/// an existing one via invite code. It coordinates:
/// - Creating new group conversations
/// - Validating and verifying signed invite codes
/// - Joining conversations through XMTP direct messages
/// - Managing placeholder conversations during async join flows
/// - Queueing and sending messages before conversation is ready
/// - Cleaning up when switching between conversations
///
/// The state machine maintains states from uninitialized → creating/validating → validated →
/// joining → ready, with automatic message queuing and delivery once ready.
public actor ConversationStateMachine {
    enum Action {
        case create
        case useExisting(conversationId: String)
        case validate(inviteCode: String)
        case join
        case delete
        case stop
        case reset
    }

    public enum State: Equatable {
        case uninitialized
        case creating
        case validating(inviteCode: String)
        case validated(
            invite: SignedInvite,
            placeholder: ConversationReadyResult,
            inboxReady: InboxReadyResult,
            previousReadyResult: ConversationReadyResult?
        )
        case joining(invite: SignedInvite, placeholder: ConversationReadyResult)
        case joinFailed(inviteTag: String, error: InviteJoinError)
        case ready(ConversationReadyResult)
        case deleting
        case error(Error)

        public var isReadyOrJoining: Bool {
            switch self {
            case .ready, .joining:
                return true
            default:
                return false
            }
        }

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.uninitialized, .uninitialized),
                 (.creating, .creating),
                 (.deleting, .deleting):
                return true
            case let (.joining(lhsInvite, _), .joining(rhsInvite, _)):
                return lhsInvite.invitePayload.conversationToken == rhsInvite.invitePayload.conversationToken
            case let (.joinFailed(lhsTag, _), .joinFailed(rhsTag, _)):
                return lhsTag == rhsTag
            case let (.validating(lhsCode), .validating(rhsCode)):
                return lhsCode == rhsCode
            case let (.validated(lhsInvite, _, lhsInbox, _), .validated(rhsInvite, _, rhsInbox, _)):
                return (lhsInvite.invitePayload.conversationToken == rhsInvite.invitePayload.conversationToken &&
                        lhsInbox.client.inboxId == rhsInbox.client.inboxId)
            case let (.ready(lhsResult), .ready(rhsResult)):
                return lhsResult.conversationId == rhsResult.conversationId
            default:
                return false
            }
        }
    }

    // MARK: - Properties

    private let identityStore: any KeychainIdentityStoreProtocol
    private let inboxStateManager: any InboxStateManagerProtocol
    private let databaseReader: any DatabaseReader
    private let databaseWriter: any DatabaseWriter
    private let environment: AppEnvironment
    private let streamProcessor: any StreamProcessorProtocol

    private var currentTask: Task<Void, Never>?
    private var actionQueue: [Action] = []
    private var isProcessing: Bool = false

    // Message stream for ordered message sending
    private var messageStreamContinuation: AsyncStream<String>.Continuation?
    private var messageProcessingTask: Task<Void, Never>?
    private var isMessageStreamSetup: Bool = false

    // Database observation task for tracking conversation join
    private var observationTask: Task<String, Error>?

    // MARK: - State Observation

    private var stateContinuations: [AsyncStream<State>.Continuation] = []
    private var _state: State = .uninitialized

    var state: State {
        get async {
            _state
        }
    }

    var stateSequence: AsyncStream<State> {
        AsyncStream { continuation in
            Task { @MainActor in
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
        Log.info("State changed from \(_state) to \(newState)")
        _state = newState

        // Emit to all continuations
        for continuation in stateContinuations {
            continuation.yield(newState)
        }
    }

    private func removeStateContinuation(_ continuation: AsyncStream<State>.Continuation) {
        stateContinuations.removeAll { $0 == continuation }
    }

    // MARK: - Init

    init(
        inboxStateManager: any InboxStateManagerProtocol,
        identityStore: any KeychainIdentityStoreProtocol,
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        environment: AppEnvironment
    ) {
        self.inboxStateManager = inboxStateManager
        self.identityStore = identityStore
        self.databaseReader = databaseReader
        self.databaseWriter = databaseWriter
        self.environment = environment
        self.streamProcessor = StreamProcessor(
            identityStore: identityStore,
            databaseWriter: databaseWriter,
            databaseReader: databaseReader
        )
    }

    deinit {
        currentTask?.cancel()
        messageStreamContinuation?.finish()
        messageProcessingTask?.cancel()
        observationTask?.cancel()
    }

    private func setupMessageStream() {
        guard !isMessageStreamSetup else { return }
        isMessageStreamSetup = true

        let stream = AsyncStream<String> { continuation in
            self.messageStreamContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.resetMessageStream()
                }
            }
        }

        // Start a single task that processes messages in order
        messageProcessingTask = Task { [weak self] in
            for await message in stream {
                guard let self else { break }
                await self.processMessage(message)
            }
            // Stream ended, reset so it can be recreated if needed
            await self?.resetMessageStream()
        }
    }

    private func resetMessageStream() {
        isMessageStreamSetup = false
        messageStreamContinuation = nil
        messageProcessingTask = nil
    }

    private func processMessage(_ text: String) async {
        do {
            // Wait for conversation to be ready if it's not
            let result = try await waitForConversationReadyResult()

            // Send the message
            let messageWriter = OutgoingMessageWriter(
                inboxStateManager: inboxStateManager,
                databaseWriter: databaseWriter,
                conversationId: result.conversationId
            )
            try await messageWriter.send(text: text)
        } catch {
            Log.error("Error sending queued message: \(error.localizedDescription)")
        }
    }

    // MARK: - Public Actions

    func create() {
        enqueueAction(.create)
    }

    func useExisting(conversationId: String) {
        enqueueAction(.useExisting(conversationId: conversationId))
    }

    func join(inviteCode: String) {
        enqueueAction(.validate(inviteCode: inviteCode))
    }

    func sendMessage(text: String) {
        setupMessageStream()
        messageStreamContinuation?.yield(text)
    }

    func delete() {
        // Cancel current task immediately to unblock the action queue
        currentTask?.cancel()
        enqueueAction(.delete)
    }

    func reset() {
        // Cancel current task immediately to unblock the action queue
        currentTask?.cancel()
        enqueueAction(.reset)
    }

    func stop() {
        // Cancel current task immediately to unblock the action queue
        currentTask?.cancel()
        enqueueAction(.stop)
    }

    private func waitForConversationReadyResult() async throws -> ConversationReadyResult {
        try Task.checkCancellation()

        for await state in stateSequence {
            try Task.checkCancellation()

            switch state {
            case .ready(let result):
                return result
            case .error(let error):
                throw error
            default:
                continue
            }
        }

        throw ConversationStateMachineError.timedOut
    }

    // MARK: - Private Action Processing

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
            case (.uninitialized, .create), (.error, .create):
                if case .error = _state {
                    await handleStop()
                }
                try await handleCreate()

            case (.uninitialized, let .useExisting(conversationId)), (.error, let .useExisting(conversationId)):
                if case .error = _state {
                    await handleStop()
                }
                handleUseExisting(conversationId: conversationId)

            case (.uninitialized, let .validate(inviteCode)), (.error, let .validate(inviteCode)):
                if case .error = _state {
                    await handleStop()
                }
                try await handleValidate(inviteCode: inviteCode, previousResult: nil)

            case let (.ready(previousResult), .validate(inviteCode)):
                try await handleValidate(inviteCode: inviteCode, previousResult: previousResult)

            case (.joinFailed, let .validate(inviteCode)):
                await handleStop()
                try await handleValidate(inviteCode: inviteCode, previousResult: nil)

            case (let .validated(invite, placeholder, inboxReady, previousResult), .join):
                try await handleJoin(
                    invite: invite,
                    placeholder: placeholder,
                    inboxReady: inboxReady,
                    previousReadyResult: previousResult
                )

            case (.ready, .delete), (.error, .delete), (.joinFailed, .delete):
                try await handleDelete()

            case (.error, .reset), (.joinFailed, .reset):
                await handleReset()

            case (_, .stop):
                await handleStop()

            default:
                Log.warning("Invalid state transition: \(_state) -> \(action)")
            }
        } catch is CancellationError {
            Log.info("Action \(action) cancelled")
        } catch {
            Log.error("Failed state transition \(_state) -> \(action): \(error.localizedDescription)")
            let displayableError: Error = (error is DisplayError ? error :
                                            ConversationStateMachineError.stateMachineError(error))
            emitStateChange(.error(displayableError))
        }
    }

    // MARK: - Action Handlers

    private func handleCreate() async throws {
        emitStateChange(.creating)

        let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
        Log.info("Inbox ready, creating conversation...")

        let client = inboxReady.client

        // Create the optimistic conversation
        let optimisticConversation = try client.prepareConversation()
        let externalConversationId = optimisticConversation.id

        // Publish the conversation
        try await optimisticConversation.publish()

        // Process the conversation in case the syncing manager
        // has not finished starting the streams, or the streams closed
        try await streamProcessor.processConversation(
            optimisticConversation,
            client: client,
            apiClient: inboxReady.apiClient
        )

        // Transition directly to ready state
        emitStateChange(.ready(ConversationReadyResult(
            conversationId: externalConversationId,
            origin: .created
        )))
    }

    private func handleUseExisting(conversationId: String) {
        Log.info("Using existing conversation: \(conversationId)")
        emitStateChange(.ready(ConversationReadyResult(
            conversationId: conversationId,
            origin: .existing
        )))
    }

    private func handleValidate(inviteCode: String, previousResult: ConversationReadyResult?) async throws {
        emitStateChange(.validating(inviteCode: inviteCode))
        Log.info("Validating invite code '\(inviteCode)'")
        let signedInvite: SignedInvite
        do {
            signedInvite = try SignedInvite.fromInviteCode(inviteCode)
        } catch {
            throw ConversationStateMachineError.invalidInviteCodeFormat(inviteCode)
        }

        guard !signedInvite.hasExpired else {
            throw ConversationStateMachineError.inviteExpired
        }

        guard !signedInvite.conversationHasExpired else {
            throw ConversationStateMachineError.conversationExpired
        }

        // Recover the public key of whoever signed this invite
        let signerPublicKey: Data
        do {
            signerPublicKey = try signedInvite.recoverSignerPublicKey()
        } catch {
            throw ConversationStateMachineError.failedVerifyingSignature
        }
        Log.info("Recovered signer's public key: \(signerPublicKey.hexEncodedString())")
        let existingConversation: Conversation? = try await databaseReader.read { db in
            try DBConversation
                .filter(DBConversation.Columns.inviteTag == signedInvite.invitePayload.tag)
                .detailedConversationQuery()
                .fetchOne(db)?
                .hydrateConversation()
        }

        let existingIdentity: KeychainIdentity?
        if let existingConversation, let identity = try? await identityStore.identity(for: existingConversation.inboxId) {
            existingIdentity = identity
        } else {
            existingIdentity = nil
        }

        if existingConversation != nil, existingIdentity == nil {
            Log.warning("Found existing conversation for identity that does not exist, deleting...")
            _ = try await databaseWriter.write { db in
                try DBConversation
                    .filter(DBConversation.Columns.inviteTag == signedInvite.invitePayload.tag)
                    .deleteAll(db)
            }
        }

        if let existingConversation, existingIdentity != nil {
            Log.info("Found existing convo by invite tag...")
            let prevInboxReady = try await inboxStateManager.waitForInboxReadyResult()
            try await inboxStateManager.delete()
            let inboxReady = try await inboxStateManager.reauthorize(
                inboxId: existingConversation.inboxId,
                clientId: existingConversation.clientId
            )
            if existingConversation.hasJoined {
                Log.info("Already joined conversation... moving to ready state.")
                emitStateChange(.ready(.init(conversationId: existingConversation.id, origin: .existing)))
                await cleanUpPreviousConversationIfNeeded(
                    previousResult: previousResult,
                    newConversationId: existingConversation.id,
                    client: prevInboxReady.client,
                    apiClient: prevInboxReady.apiClient
                )
            } else {
                Log.info("Waiting for invite approval...")
                if existingConversation.isDraft {
                    // update the placeholder with the signed invite
                    let messageWriter = IncomingMessageWriter(databaseWriter: databaseWriter)
                    let conversationWriter = ConversationWriter(
                        identityStore: identityStore,
                        databaseWriter: databaseWriter,
                        messageWriter: messageWriter
                    )
                    _ = try await conversationWriter.createPlaceholderConversation(
                        draftConversationId: existingConversation.id,
                        for: signedInvite,
                        inboxId: inboxReady.client.inboxId
                    )
                }
                emitStateChange(.validated(
                    invite: signedInvite,
                    placeholder: .init(conversationId: existingConversation.id, origin: .existing),
                    inboxReady: inboxReady,
                    previousReadyResult: previousResult
                ))
                enqueueAction(.join)
            }
        } else {
            Log.info("Existing conversation not found. Creating placeholder...")
            Log.info("Waiting for inbox ready result...")
            let inboxReady = try await inboxStateManager.waitForInboxReadyResult()
            let messageWriter = IncomingMessageWriter(databaseWriter: databaseWriter)
            let conversationWriter = ConversationWriter(
                identityStore: identityStore,
                databaseWriter: databaseWriter,
                messageWriter: messageWriter
            )
            let conversationId = try await conversationWriter.createPlaceholderConversation(
                draftConversationId: nil,
                for: signedInvite,
                inboxId: inboxReady.client.inboxId
            )
            let placeholder = ConversationReadyResult(conversationId: conversationId, origin: .joined)
            emitStateChange(.validated(
                invite: signedInvite,
                placeholder: placeholder,
                inboxReady: inboxReady,
                previousReadyResult: previousResult
            ))
            enqueueAction(.join)
        }
    }

    private func handleJoin(
        invite: SignedInvite,
        placeholder: ConversationReadyResult,
        inboxReady: InboxReadyResult,
        previousReadyResult: ConversationReadyResult?
    ) async throws {
        emitStateChange(.joining(invite: invite, placeholder: placeholder))

        // Register ourselves as the error handler for invite join errors when app is active
        try await inboxStateManager.setInviteJoinErrorHandler(self)

        Log.info("Requesting to join conversation...")

        let apiClient = inboxReady.apiClient
        let client = inboxReady.client

        let inviterInboxId = invite.invitePayload.creatorInboxIdString

        guard !inviterInboxId.isEmpty else {
            throw ConversationStateMachineError.invalidInviteCodeFormat("Malformed creator inbox ID")
        }

        let dm = try await client.newConversation(with: inviterInboxId)
        let text = try invite.toURLSafeSlug()
        _ = try await dm.prepare(text: text)
        try await dm.publish()

        // Clean up previous conversation, do this without matching the `conversationId`.
        // We don't need the created conversation during the 'joining' state and
        // want to make sure it is deleted even if the conversation never shows
        await self.cleanUpPreviousConversationIfNeeded(
            previousResult: previousReadyResult,
            newConversationId: nil,
            client: client,
            apiClient: apiClient
        )

        // Wait for the conversation to appear in the database via ValueObservation
        // The SyncingManager's conversation stream will process it and write to DB
        Log.info("Waiting for conversation to be joined...")
        observationTask = waitForJoinedConversation(
            inviteTag: invite.invitePayload.tag
        )

        do {
            guard let task = observationTask else {
                throw ConversationStateMachineError.timedOut
            }
            let conversationId = try await task.value
            observationTask = nil

            Log.info("Conversation joined successfully: \(conversationId)")
            await clearInviteJoinErrorHandler()

            guard case .joining(let currentInvite, _) = _state,
                  currentInvite.invitePayload.tag == invite.invitePayload.tag else {
                Log.info("State changed from joining before ready emission, skipping")
                return
            }

            emitStateChange(.ready(ConversationReadyResult(
                conversationId: conversationId,
                origin: .joined
            )))
        } catch is CancellationError {
            observationTask = nil
            await clearInviteJoinErrorHandler()
            Log.info("Conversation join observation cancelled")
            guard case .joinFailed = _state else {
                throw CancellationError()
            }
            Log.info("Already in joinFailed state, not propagating cancellation")
        } catch {
            observationTask = nil
            await clearInviteJoinErrorHandler()
            Log.error("Error waiting for conversation to join: \(error)")
            guard case .joinFailed = _state else {
                throw ConversationStateMachineError.timedOut
            }
            Log.info("Already in joinFailed state, not throwing timeout error")
        }
    }

    private func waitForJoinedConversation(inviteTag: String) -> Task<String, Error> {
        let observation = ValueObservation
            .tracking { [inviteTag] db -> String? in
                try DBConversation
                    .filter(!DBConversation.Columns.id.like("draft-%"))
                    .filter(DBConversation.Columns.inviteTag == inviteTag)
                    .select(DBConversation.Columns.id)
                    .fetchOne(db)
            }

        // Convert observation to AsyncStream
        let stream = observation.values(in: databaseReader)

        // Return a task that can be cancelled by the caller
        return Task {
            try Task.checkCancellation()

            // Wait for non-nil value - cancellable by caller (e.g., stop/delete/deinit)
            for try await conversationId in stream {
                try Task.checkCancellation()

                if let conversationId {
                    return conversationId
                }
            }
            throw ConversationStateMachineError.timedOut
        }
    }

    private func handleDelete() async throws {
        // For invites, we need the external conversation ID if available,
        // capture before changing state
        let conversationId: String? = switch _state {
        case .ready(let result):
            result.conversationId
        default:
            nil
        }

        emitStateChange(.deleting)

        // Unregister error handler if we were in joining state
        await clearInviteJoinErrorHandler()

        // Cancel observation tasks and stop accepting new messages
        // Note: currentTask is already cancelled by delete() - don't cancel ourselves!
        messageStreamContinuation?.finish()
        messageProcessingTask?.cancel()
        observationTask?.cancel()
        observationTask = nil

        if let conversationId {
            // Get the inbox state to access the API client for unsubscribing
            let inboxReady = try await inboxStateManager.waitForInboxReadyResult()

            try await cleanUp(
                conversationId: conversationId,
                client: inboxReady.client,
                apiClient: inboxReady.apiClient,
            )

            try await inboxStateManager.delete()
        }

        emitStateChange(.uninitialized)
    }

    private func cleanUpPreviousConversationIfNeeded(
        previousResult: ConversationReadyResult?,
        newConversationId: String?,
        client: any XMTPClientProvider,
        apiClient: any ConvosAPIClientProtocol
    ) async {
        guard let previousResult,
              previousResult.conversationId != newConversationId else {
            return
        }

        Log.info("Cleaning up previous conversation: \(previousResult.conversationId)")
        do {
            try await cleanUp(
                conversationId: previousResult.conversationId,
                client: client,
                apiClient: apiClient
            )
        } catch {
            Log.error("Failed to clean up previous conversation: \(error)")
        }
    }

    private func cleanUp(
        conversationId: String,
        client: any XMTPClientProvider,
        apiClient: any ConvosAPIClientProtocol
    ) async throws {
        // @jarod until we have self removal, we need to deny the conversation
        // so it doesn't show up in the list
        let externalConversation = try await client.conversationsProvider.findConversation(conversationId: conversationId)
        try await externalConversation?.updateConsentState(state: .denied)

        // Get clientId from keychain (privacy-preserving identifier, not XMTP installationId)
        if let identity = try? await identityStore.identity(for: client.inboxId) {
            // Unsubscribe from this conversation's push notification topic only
            // The welcome topic remains subscribed (it's inbox-level, not conversation-level).
            // Installation unregistration only happens at inbox level in InboxStateMachine.performInboxCleanup()
            let topic = conversationId.xmtpGroupTopicFormat
            do {
                try await apiClient.unsubscribeFromTopics(clientId: identity.clientId, topics: [topic])
                Log.info("Unsubscribed from push topic: \(topic)")
            } catch {
                Log.error("Failed unsubscribing from topic \(topic): \(error)")
                // Continue with cleanup even if unsubscribe fails
            }
        } else {
            Log.warning("Identity not found, skipping push notification cleanup for: \(client.inboxId)")
        }

        // Always clean up database records, even if identity/clientId is missing
        try await databaseWriter.write { db in
            // Delete messages first (due to foreign key constraints)
            try DBMessage
                .filter(DBMessage.Columns.conversationId == conversationId)
                .deleteAll(db)

            // Delete conversation members
            try DBConversationMember
                .filter(DBConversationMember.Columns.conversationId == conversationId)
                .deleteAll(db)

            try ConversationLocalState
                .filter(ConversationLocalState.Columns.conversationId == conversationId)
                .deleteAll(db)

            try DBInvite
                .filter(DBInvite.Columns.conversationId == conversationId)
                .deleteAll(db)

            try DBConversation
                .filter(DBConversation.Columns.id == conversationId)
                .deleteAll(db)

            Log.info("Cleaned up conversation data for conversationId: \(conversationId)")
        }

        try await databaseWriter.write { db in
            let conversationsCount = try DBConversation
                .fetchCount(db)
            if conversationsCount == 0 {
                Log.warning("Leaving inbox \(client.inboxId) with zero conversations!")
            }
        }
    }

    private func handleStop() async {
        await cleanUpState()
    }

    private func handleReset() async {
        await cleanUpState()
    }

    private func cleanUpState() async {
        messageStreamContinuation?.finish()
        messageProcessingTask?.cancel()
        observationTask?.cancel()
        observationTask = nil
        await clearInviteJoinErrorHandler()
        emitStateChange(.uninitialized)
    }

    private func clearInviteJoinErrorHandler() async {
        do {
            try await inboxStateManager.setInviteJoinErrorHandler(nil)
        } catch {
            Log.debug("Failed to clear invite join error handler: \(error)")
        }
    }

    private func subscribeToConversationTopics(
        conversationId: String,
        client: any XMTPClientProvider,
        apiClient: any ConvosAPIClientProtocol,
        context: String
    ) async {
        let conversationTopic = conversationId.xmtpGroupTopicFormat
        let welcomeTopic = client.installationId.xmtpWelcomeTopicFormat

        guard let identity = try? await identityStore.identity(for: client.inboxId) else {
            Log.warning("Identity not found, skipping push notification subscription")
            return
        }

        do {
            let deviceId = DeviceInfo.deviceIdentifier
            try await apiClient.subscribeToTopics(
                deviceId: deviceId,
                clientId: identity.clientId,
                topics: [conversationTopic, welcomeTopic]
            )
            Log.info("Subscribed to push topics \(context): \(conversationTopic), \(welcomeTopic)")
        } catch {
            Log.error("Failed subscribing to topics \(context): \(error)")
        }
    }
}

// MARK: - Display Error Protocol

public protocol DisplayError: Error {
    var title: String { get }
    var description: String { get }
}

public enum RetryAction: Equatable {
    case createConversation
    case joinConversation(inviteCode: String)
}

public protocol RetryableDisplayError: DisplayError {
    var retryAction: RetryAction { get }
}

// MARK: - Errors

public enum ConversationStateMachineError: Error {
    case failedFindingConversation
    case failedVerifyingSignature
    case stateMachineError(Error)
    case inviteExpired
    case conversationExpired
    case invalidInviteCodeFormat(String)
    case timedOut
}

extension ConversationStateMachineError: DisplayError {
    public var title: String {
        switch self {
        case .failedFindingConversation:
            return "No convo here"
        case .failedVerifyingSignature:
            return "Invalid invite"
        case .stateMachineError:
            return "Something went wrong"
        case .inviteExpired:
            return "Invite expired"
        case .conversationExpired:
            return "Convo expired"
        case .invalidInviteCodeFormat:
            return "Invalid code"
        case .timedOut:
            return "Try again"
        }
    }

    public var description: String {
        switch self {
        case .failedFindingConversation:
            return "Maybe it already exploded."
        case .failedVerifyingSignature:
            return "This invite couldn't be verified."
        case .stateMachineError(let error):
            return error.localizedDescription
        case .inviteExpired:
            return "This invite has expired."
        case .conversationExpired:
            return "This convo has expired."
        case .invalidInviteCodeFormat:
            return "This code is not valid."
        case .timedOut:
            return "Joining the convo failed."
        }
    }
}

// MARK: - InviteJoinErrorHandler

extension ConversationStateMachine: InviteJoinErrorHandler {
    public func handleInviteJoinError(_ error: InviteJoinError) async {
        guard case .joining(let invite, _) = _state,
              error.inviteTag == invite.invitePayload.tag else {
            Log.info("Ignoring InviteJoinError for non-matching inviteTag or non-joining state")
            return
        }

        Log.info("Transitioning to joinFailed state for inviteTag: \(error.inviteTag)")

        observationTask?.cancel()
        observationTask = nil

        // Unregister error handler before transitioning to joinFailed
        await clearInviteJoinErrorHandler()

        guard case .joining(let currentInvite, _) = _state,
              currentInvite.invitePayload.tag == error.inviteTag else {
            Log.info("State changed after error handler cleanup, not emitting joinFailed")
            return
        }

        emitStateChange(.joinFailed(inviteTag: error.inviteTag, error: error))
    }
}
