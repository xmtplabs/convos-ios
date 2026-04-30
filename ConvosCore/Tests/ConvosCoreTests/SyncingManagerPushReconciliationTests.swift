@testable import ConvosCore
import Foundation
import os.lock
import Testing
import XMTPiOS

/// Verifies that `SyncingManager` re-runs push topic reconciliation at every
/// point that's expected to: after the initial sync, after resume, and after
/// `requestDiscovery`. A regression here lets stale device-side push state
/// drift away from the live conversation list — the same class of bug this
/// PR was opened to fix.
///
/// The tests stub the XMTP client at the `XMTPClientProvider` level and
/// observe the API calls that the production `PushTopicSubscriptionManager`
/// emits, so they exercise the real wiring through `StreamProcessor` without
/// touching the network.
@Suite("SyncingManager Push Reconciliation Tests", .serialized, .timeLimit(.minutes(2)))
struct SyncingManagerPushReconciliationTests {
    @Test("Reconciles push subscriptions after initial sync")
    func reconcilesAfterInitialSync() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.streamBehavior = .neverClose
        try await seedIdentity(matching: mockClient, into: fixtures)
        let recordingAPI = RecordingPushAPIClientForReconciliationTests()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: NoopDeviceRegistrationManager(),
            notificationCenter: MockUserNotificationCenter()
        )

        await syncingManager.start(with: mockClient, apiClient: recordingAPI)

        try await waitUntil(timeout: .seconds(15)) {
            recordingAPI.subscribeCount >= 1
        }

        let calls = recordingAPI.subscribeCalls
        #expect(calls.count >= 1, "Initial sync should have triggered at least one push reconcile")
        #expect(
            calls.first?.topics.contains(mockClient.installationId.xmtpWelcomeTopicFormat) == true,
            "Reconcile must always include the welcome topic"
        )

        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Reconciles push subscriptions after resume")
    func reconcilesAfterResume() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.streamBehavior = .neverClose
        try await seedIdentity(matching: mockClient, into: fixtures)
        let recordingAPI = RecordingPushAPIClientForReconciliationTests()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: NoopDeviceRegistrationManager(),
            notificationCenter: MockUserNotificationCenter()
        )

        await syncingManager.start(with: mockClient, apiClient: recordingAPI)
        try await waitUntil(timeout: .seconds(15)) { recordingAPI.subscribeCount >= 1 }
        let countAfterStart = recordingAPI.subscribeCount

        await syncingManager.pause()
        await syncingManager.resume()

        try await waitUntil(timeout: .seconds(15)) {
            recordingAPI.subscribeCount > countAfterStart
        }

        #expect(
            recordingAPI.subscribeCount > countAfterStart,
            "Resume must trigger a fresh push topic reconcile"
        )

        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    @Test("Reconciles push subscriptions after requestDiscovery")
    func reconcilesAfterRequestDiscovery() async throws {
        let fixtures = TestFixtures()
        let mockClient = TestableMockClient()
        mockClient.streamBehavior = .neverClose
        try await seedIdentity(matching: mockClient, into: fixtures)
        let recordingAPI = RecordingPushAPIClientForReconciliationTests()

        let syncingManager = SyncingManager(
            identityStore: fixtures.identityStore,
            databaseWriter: fixtures.databaseManager.dbWriter,
            databaseReader: fixtures.databaseManager.dbReader,
            deviceRegistrationManager: NoopDeviceRegistrationManager(),
            notificationCenter: MockUserNotificationCenter()
        )

        await syncingManager.start(with: mockClient, apiClient: recordingAPI)
        try await waitUntil(timeout: .seconds(15)) { recordingAPI.subscribeCount >= 1 }
        let countAfterStart = recordingAPI.subscribeCount

        await syncingManager.requestDiscovery()

        try await waitUntil(timeout: .seconds(15)) {
            recordingAPI.subscribeCount > countAfterStart
        }

        #expect(
            recordingAPI.subscribeCount > countAfterStart,
            "requestDiscovery must trigger a fresh push topic reconcile"
        )

        await syncingManager.stop()
        try? await fixtures.cleanup()
    }

    // MARK: - Helpers

    private func seedIdentity(
        matching client: TestableMockClient,
        into fixtures: TestFixtures
    ) async throws {
        let keys = try await fixtures.identityStore.generateKeys()
        _ = try await fixtures.identityStore.save(
            inboxId: client.inboxId,
            clientId: ClientId.generate().value,
            keys: keys
        )
    }

    private enum TestError: Error {
        case timeout(String)
    }

    private func waitUntil(
        timeout: Duration = .seconds(15),
        interval: Duration = .milliseconds(50),
        condition: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: interval)
        }
        throw TestError.timeout("Condition not met within \(timeout)")
    }
}

/// `PushTopicSubscriptionManager.deviceIdentifier(context:)` returns nil
/// when both `deviceInfoProvider` and `deviceRegistrationManager` are nil,
/// short-circuiting the subscribe path before it can hit the API. Tests
/// don't need real device registration, but they do need the manager
/// reference to be non-nil so the fallback to `DeviceInfo.deviceIdentifier`
/// is reached.
private actor NoopDeviceRegistrationManager: DeviceRegistrationManagerProtocol {
    func startObservingPushTokenChanges() {}
    func stopObservingPushTokenChanges() {}
    func registerDeviceIfNeeded() async {}
    static func clearRegistrationState(deviceInfo: any DeviceInfoProviding) {}
    static func hasRegisteredDevice(deviceInfo: any DeviceInfoProviding) -> Bool { false }
}

/// Records `subscribeToTopics` invocations so tests can assert that the
/// production reconcile pipeline reached the API layer. Stubs every other
/// `ConvosAPIClientProtocol` method as a no-op or trivial value.
private final class RecordingPushAPIClientForReconciliationTests: ConvosAPIClientProtocol, @unchecked Sendable {
    struct SubscribeCall: Sendable {
        let deviceId: String
        let clientId: String
        let topics: [String]
    }

    private let state = OSAllocatedUnfairLock(initialState: [SubscribeCall]())

    var subscribeCalls: [SubscribeCall] {
        state.withLock { $0 }
    }

    var subscribeCount: Int {
        state.withLock { $0.count }
    }

    func request(for path: String, method: String, queryParameters: [String: String]?) throws -> URLRequest {
        guard let url = URL(string: "http://example.com") else {
            throw NSError(domain: "test", code: 1)
        }
        return URLRequest(url: url)
    }

    func registerDevice(deviceId: String, pushToken: String?) async throws {}

    func authenticate(appCheckToken: String, retryCount: Int) async throws -> String {
        "mock-jwt-token"
    }

    func uploadAttachment(data: Data, filename: String, contentType: String, acl: String) async throws -> String {
        ""
    }

    func uploadAttachmentAndExecute(
        data: Data,
        filename: String,
        afterUpload: @escaping (String) async throws -> Void
    ) async throws -> String {
        ""
    }

    func subscribeToTopics(deviceId: String, clientId: String, topics: [String]) async throws {
        state.withLock {
            $0.append(SubscribeCall(deviceId: deviceId, clientId: clientId, topics: topics))
        }
    }

    func unsubscribeFromTopics(clientId: String, topics: [String]) async throws {}

    func unregisterInstallation(clientId: String) async throws {}

    func renewAssetsBatch(assetKeys: [String]) async throws -> AssetRenewalResult {
        AssetRenewalResult(renewed: assetKeys.count, failed: 0, expiredKeys: [])
    }

    func getPresignedUploadURL(filename: String, contentType: String) async throws -> (uploadURL: String, assetURL: String) {
        ("https://example.com/upload/\(filename)", "https://example.com/assets/\(filename)")
    }

    func requestAgentJoin(slug: String, instructions: String, forceErrorCode: Int?) async throws -> ConvosAPI.AgentJoinResponse {
        .init(success: true, joined: true)
    }

    func redeemInviteCode(_ code: String) async throws -> ConvosAPI.InviteCodeStatus {
        .init(code: code, name: nil, maxRedemptions: 5, redemptionCount: 0, remainingRedemptions: 5)
    }

    func fetchInviteCodeStatus(_ code: String) async throws -> ConvosAPI.InviteCodeStatus {
        .init(code: code, name: nil, maxRedemptions: 5, redemptionCount: 0, remainingRedemptions: 5)
    }

    func initiateConnection(serviceId: String, redirectUri: String) async throws -> ConnectionsAPI.InitiateResponse {
        .init(connectionRequestId: "", redirectUrl: "")
    }

    func completeConnection(connectionRequestId: String) async throws -> ConnectionsAPI.CompleteResponse {
        .init(connectionId: "", serviceId: "", serviceName: "", composioEntityId: "", composioConnectionId: "", status: "")
    }

    func listConnections() async throws -> [ConnectionsAPI.ConnectionResponse] { [] }

    func revokeConnection(connectionId: String) async throws {}
}
