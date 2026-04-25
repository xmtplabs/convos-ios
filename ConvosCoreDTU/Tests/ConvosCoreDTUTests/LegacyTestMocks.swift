@testable import ConvosCore
@testable import ConvosCoreDTU
import ConvosInvites
import ConvosMessagingProtocols
import Foundation
import GRDB

// MARK: - waitForState + legacyWaitUntil helpers
//
// Stage 6f: helpers for migrated state-machine + sync tests, lifted
// from `ConvosCore/Tests/ConvosCoreTests/TestHelpers.swift`.
//
// `legacyWaitUntil` mirrors the legacy `waitUntil` but renamed to
// avoid a redeclaration conflict with the `waitUntil` already
// defined in `ScheduledExplosionManagerTests.swift` at file scope.

/// Waits until a condition becomes true, polling at a specified interval
func legacyWaitUntil(
    timeout: Duration = .seconds(10),
    interval: Duration = .milliseconds(50),
    condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() {
            return
        }
        try await Task.sleep(for: interval)
    }
    throw TimeoutError()
}

/// Helper to wait for InboxStateMachine to reach a specific state with timeout
func waitForState(
    _ stateMachine: InboxStateMachine,
    timeout: TimeInterval = 30,
    condition: @escaping @Sendable (InboxStateMachine.State) -> Bool
) async throws -> InboxStateMachine.State {
    try await withTimeout(seconds: timeout) {
        for await state in await stateMachine.stateSequence {
            if condition(state) {
                return state
            }
        }
        throw TimeoutError()
    }
}

// MARK: - MockInvitesRepository
//
// Lifted from the same legacy file. Used by InboxStateMachineTests
// and other migrated tests that exercise the invites lookup path.

class MockInvitesRepository: InvitesRepositoryProtocol {
    private var invites: [String: [Invite]] = [:]

    func fetchInvites(for creatorInboxId: String) async throws -> [Invite] {
        invites[creatorInboxId] ?? []
    }

    func addInvite(_ invite: Invite, for creatorInboxId: String) {
        var existing = invites[creatorInboxId] ?? []
        existing.append(invite)
        invites[creatorInboxId] = existing
    }

    func clearInvites(for creatorInboxId: String) {
        invites.removeValue(forKey: creatorInboxId)
    }
}

// MARK: - MockSyncingManager

/// Mock implementation of SyncingManagerProtocol for testing
actor MockSyncingManager: SyncingManagerProtocol {
    var isStarted = false
    var isPaused = false
    var startCallCount = 0
    var stopCallCount = 0
    var pauseCallCount = 0
    var resumeCallCount = 0

    var isSyncReady: Bool {
        isStarted && !isPaused
    }

    func start(with client: any MessagingClient, apiClient: any ConvosAPIClientProtocol) {
        isStarted = true
        isPaused = false
        startCallCount += 1
    }

    func stop() {
        isStarted = false
        isPaused = false
        stopCallCount += 1
    }

    func pause() {
        isPaused = true
        pauseCallCount += 1
    }

    func resume() {
        isPaused = false
        resumeCallCount += 1
    }

    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) async {}

    func setTypingIndicatorHandler(_ handler: @escaping @Sendable (String, String, Bool) -> Void) async {}

    func requestDiscovery() async {}
}

// MARK: - MockNetworkMonitor

/// Mock implementation of NetworkMonitor for testing
public actor MockNetworkMonitor: NetworkMonitorProtocol {
    private var _status: NetworkMonitor.Status = .connected(.wifi)
    private var statusContinuations: [AsyncStream<NetworkMonitor.Status>.Continuation] = []

    public init(initialStatus: NetworkMonitor.Status = .connected(.wifi)) {
        self._status = initialStatus
    }

    public var status: NetworkMonitor.Status {
        _status
    }

    public var isConnected: Bool {
        _status.isConnected
    }

    public func start() async {}

    public func stop() async {
        for continuation in statusContinuations {
            continuation.finish()
        }
        statusContinuations.removeAll()
    }

    public var statusSequence: AsyncStream<NetworkMonitor.Status> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self else { return }
                await self.addStatusContinuation(continuation)
            }
        }
    }

    private func addStatusContinuation(_ continuation: AsyncStream<NetworkMonitor.Status>.Continuation) {
        statusContinuations.append(continuation)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.removeStatusContinuation(continuation)
            }
        }
        continuation.yield(_status)
    }

    private func removeStatusContinuation(_ continuation: AsyncStream<NetworkMonitor.Status>.Continuation) {
        statusContinuations.removeAll { $0 == continuation }
    }

    public func simulateDisconnection() {
        _status = .disconnected
        for continuation in statusContinuations {
            continuation.yield(_status)
        }
    }

    public func simulateConnection(type: NetworkMonitor.ConnectionType = .wifi) {
        _status = .connected(type)
        for continuation in statusContinuations {
            continuation.yield(_status)
        }
    }

    public func simulateConnecting() {
        _status = .connecting
        for continuation in statusContinuations {
            continuation.yield(_status)
        }
    }
}

// MARK: - SequentialMockUnusedConversationCache
//
// Stage 6f: lifted from
// `ConvosCore/Tests/ConvosCoreTests/InboxLifecycleManagerTests.swift`.
// Shared between the migrated `ConsumeInboxOnlyTests`,
// `InboxLifecycleManagerTests`, and `UnusedConversationConsumptionTests`
// so the mock cache lives in one place in the DTU test target.
//
// Each `consume*` call hands out a fresh `MockMessagingService` with
// a deterministic clientId; consumption clears the unused id pair
// until `markNewInboxAvailable()` resets them.

actor SequentialMockUnusedConversationCache: UnusedConversationCacheProtocol {
    private var nextInboxNumber: Int = 1
    private var currentUnusedInboxId: String?
    private var currentUnusedConversationId: String?

    init() {
        currentUnusedInboxId = "unused-inbox-1"
        currentUnusedConversationId = "unused-conversation-1"
    }

    func prepareUnusedConversationIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {}

    func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> (service: any MessagingServiceProtocol, conversationId: String?) {
        let clientId = "unused-client-\(nextInboxNumber)"
        let conversationId = currentUnusedConversationId
        currentUnusedInboxId = nil
        currentUnusedConversationId = nil
        nextInboxNumber += 1
        let mockStateManager = MockInboxStateManager(initialState: .idle(clientId: clientId))
        return (service: MockMessagingService(inboxStateManager: mockStateManager), conversationId: conversationId)
    }

    func consumeInboxOnly(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> any MessagingServiceProtocol {
        let clientId = "unused-client-\(nextInboxNumber)"
        currentUnusedInboxId = nil
        currentUnusedConversationId = nil
        nextInboxNumber += 1
        let mockStateManager = MockInboxStateManager(initialState: .idle(clientId: clientId))
        return MockMessagingService(inboxStateManager: mockStateManager)
    }

    func clearUnusedFromKeychain() {}

    func isUnusedConversation(_ conversationId: String) -> Bool {
        return conversationId == currentUnusedConversationId
    }

    func isUnusedInbox(_ inboxId: String) -> Bool {
        return inboxId == currentUnusedInboxId
    }

    func hasUnusedConversation() -> Bool {
        return currentUnusedConversationId != nil
    }

    /// Test helper: simulate background creation of new unused conversation
    func markNewInboxAvailable() {
        currentUnusedInboxId = "unused-inbox-\(nextInboxNumber)"
        currentUnusedConversationId = "unused-conversation-\(nextInboxNumber)"
    }
}

// MARK: - DelayingMockUnusedConversationCache
//
// Lifted from the same legacy file. Used by tests that want to
// simulate race conditions during consumption.

actor DelayingMockUnusedConversationCache: UnusedConversationCacheProtocol {
    private var consumeStartedContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?
    private var hasConsumed: Bool = false
    private var consumeStarted: Bool = false

    func prepareUnusedConversationIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {}

    func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> (service: any MessagingServiceProtocol, conversationId: String?) {
        consumeStarted = true
        consumeStartedContinuation?.resume()
        consumeStartedContinuation = nil

        await withCheckedContinuation { continuation in
            resumeContinuation = continuation
        }

        hasConsumed = true
        return (service: MockMessagingService(), conversationId: nil)
    }

    func consumeInboxOnly(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> any MessagingServiceProtocol {
        hasConsumed = true
        return MockMessagingService()
    }

    func clearUnusedFromKeychain() {}

    func isUnusedConversation(_ conversationId: String) -> Bool {
        return false
    }

    func isUnusedInbox(_ inboxId: String) -> Bool {
        return false
    }

    func hasUnusedConversation() -> Bool {
        return !hasConsumed
    }

    /// Test helper: wait for `consumeOrCreateMessagingService` to start
    func waitForConsumeStarted() async {
        await withCheckedContinuation { continuation in
            consumeStartedContinuation = continuation
        }
    }

    /// Test helper: resume the in-flight consume operation
    func resumeConsume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

// MARK: - SimpleMockUnusedConversationCache
//
// Stage 6f: lifted from
// `ConvosCore/Tests/ConvosCoreTests/InboxLifecycleManagerTests.swift`.
// Minimal mock that always hands out a fresh `MockMessagingService`
// without tracking any cached state.

actor SimpleMockUnusedConversationCache: UnusedConversationCacheProtocol {
    func prepareUnusedConversationIfNeeded(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async {}

    func consumeOrCreateMessagingService(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> (service: any MessagingServiceProtocol, conversationId: String?) {
        (service: MockMessagingService(), conversationId: nil)
    }

    func consumeInboxOnly(
        databaseWriter: any DatabaseWriter,
        databaseReader: any DatabaseReader,
        environment: AppEnvironment
    ) async -> any MessagingServiceProtocol {
        MockMessagingService()
    }

    func clearUnusedFromKeychain() {}

    func isUnusedConversation(_ conversationId: String) -> Bool { false }

    func isUnusedInbox(_ inboxId: String) -> Bool { false }

    func hasUnusedConversation() -> Bool { false }
}

// MARK: - InboxLifecycleManager test helpers
//
// Stage 6f: helper extensions lifted from the legacy
// `InboxLifecycleManagerTests.swift` so the migrated tests don't
// have to repeat the wake-and-discard / sleep boilerplate.

extension InboxLifecycleManager {
    /// Helper for tests to wake without returning the non-Sendable service
    func wakeAndDiscard(clientId: String, inboxId: String, reason: WakeReason) async throws {
        _ = try await wake(clientId: clientId, inboxId: inboxId, reason: reason)
    }

    /// Helper for tests to getOrWake without returning the non-Sendable service
    func getOrWakeAndDiscard(clientId: String, inboxId: String) async throws {
        _ = try await getOrWake(clientId: clientId, inboxId: inboxId)
    }

    /// Test helper to manually mark a client as sleeping
    func setSleepingForTest(clientId: String) async {
        if isAwake(clientId: clientId) {
            await sleep(clientId: clientId)
        }
    }
}
