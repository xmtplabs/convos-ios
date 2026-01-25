@testable import ConvosCore
import Foundation
import GRDB
import Testing
@preconcurrency import XMTPiOS

// Set custom XMTP endpoint at module load time (before any async code)
// This runs synchronously when the test module is loaded
// @preconcurrency import suppresses strict concurrency warnings for XMTP static properties
private let _configureXMTPEndpoint: Void = {
    if let endpoint = ProcessInfo.processInfo.environment["XMTP_NODE_ADDRESS"] {
        XMTPEnvironment.customLocalAddress = endpoint
    }
}()

/// Waits until a condition becomes true, polling at a specified interval
/// - Parameters:
///   - timeout: Maximum time to wait (default: 10 seconds)
///   - interval: Polling interval (default: 50ms)
///   - condition: Async closure that returns true when condition is met
/// - Throws: TimeoutError if condition not met within timeout
func waitUntil(
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

/// Test fixtures for creating XMTP clients in tests
class TestFixtures {
    let environment: AppEnvironment
    let identityStore: MockKeychainIdentityStore
    let keychainService: MockKeychainService
    let databaseManager: MockDatabaseManager

    var clientA: (any XMTPClientProvider)?
    var clientB: (any XMTPClientProvider)?
    var clientC: (any XMTPClientProvider)?

    var clientIdA: String?
    var clientIdB: String?
    var clientIdC: String?

    init() {
        self.environment = .tests
        self.identityStore = MockKeychainIdentityStore()
        self.keychainService = MockKeychainService()
        self.databaseManager = MockDatabaseManager.makeTestDatabase()

        // Configure logging for tests
        ConvosLog.configure(environment: .tests)

        // Configure mock singletons for code that doesn't use dependency injection
        // Uses resetForTesting() to allow reconfiguration across test runs
        DeviceInfo.resetForTesting()
        DeviceInfo.configure(MockDeviceInfoProvider())
        PushNotificationRegistrar.resetForTesting()
        PushNotificationRegistrar.configure(MockPushNotificationRegistrarProvider())

        // XMTP endpoint is configured at module load time via _configureXMTPEndpoint
    }

    /// Create a new XMTP client for testing
    func createClient() async throws -> (client: any XMTPClientProvider, clientId: String, keys: KeychainIdentityKeys) {
        let keys = try await identityStore.generateKeys()
        let clientId = ClientId.generate().value

        // Check environment variables for CI configuration
        let isSecure: Bool
        if let envSecure = ProcessInfo.processInfo.environment["XMTP_IS_SECURE"] {
            isSecure = envSecure.lowercased() == "true" || envSecure == "1"
        } else {
            isSecure = false
        }

        let clientOptions = ClientOptions(
            api: .init(
                env: .local,
                isSecure: isSecure,
                appVersion: "convos-tests/1.0.0"
            ),
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
            dbDirectory: environment.defaultDatabasesDirectory
        )

        let client = try await Client.create(account: keys.signingKey, options: clientOptions)

        // Save to mock identity store
        _ = try await identityStore.save(inboxId: client.inboxId, clientId: clientId, keys: keys)

        return (client, clientId, keys)
    }

    /// Create three test clients (A, B, C) for testing
    func createTestClients() async throws {
        let (a, aId, _) = try await createClient()
        let (b, bId, _) = try await createClient()
        let (c, cId, _) = try await createClient()

        clientA = a
        clientB = b
        clientC = c
        clientIdA = aId
        clientIdB = bId
        clientIdC = cId
    }

    /// Clean up all test clients
    func cleanup() async throws {
        if let client = clientA {
            try? client.deleteLocalDatabase()
        }
        if let client = clientB {
            try? client.deleteLocalDatabase()
        }
        if let client = clientC {
            try? client.deleteLocalDatabase()
        }

        try await identityStore.deleteAll()
        try databaseManager.erase()
    }
}

/// Mock implementation of InvitesRepositoryProtocol for testing
class MockInvitesRepository: InvitesRepositoryProtocol {
    private var invites: [String: [Invite]] = [:]

    func fetchInvites(for creatorInboxId: String) async throws -> [Invite] {
        invites[creatorInboxId] ?? []
    }

    // Test helper methods
    func addInvite(_ invite: Invite, for creatorInboxId: String) {
        var existing = invites[creatorInboxId] ?? []
        existing.append(invite)
        invites[creatorInboxId] = existing
    }

    func clearInvites(for creatorInboxId: String) {
        invites.removeValue(forKey: creatorInboxId)
    }
}

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

    func start(with client: AnyClientProvider, apiClient: any ConvosAPIClientProtocol) {
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

    func setInviteJoinErrorHandler(_ handler: (any InviteJoinErrorHandler)?) async {
    }
}

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

    public func start() async {
        // Mock doesn't need to do anything on start
    }

    public func stop() async {
        // Clean up continuations
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

    // Test helper methods to simulate network changes
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
