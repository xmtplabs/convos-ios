@testable import ConvosCore
import Foundation
import os.lock
import Testing

@Suite("Push Topic Subscription Manager Tests")
struct PushTopicSubscriptionManagerTests {
    @Test("Subscribes invite DM topic with extension device identifier")
    func subscribesInviteDMTopic() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let apiClient = RecordingPushAPIClient()
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1")
        )

        await manager.subscribeToInviteDMTopic(
            conversationId: "dm-1",
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "test"
        )

        let calls = apiClient.subscribeCalls
        #expect(calls.count == 1)
        #expect(calls.first?.deviceId == "device-1")
        #expect(calls.first?.clientId == "client-1")
        #expect(calls.first?.topics == ["dm-1".xmtpGroupTopicFormat])
    }

    @Test("Unsubscribes malicious invite DM topic")
    func unsubscribesInviteDMTopic() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let apiClient = RecordingPushAPIClient()
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1")
        )

        await manager.unsubscribeFromInviteDMTopic(
            conversationId: "dm-1",
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "test"
        )

        let calls = apiClient.unsubscribeCalls
        #expect(calls.count == 1)
        #expect(calls.first?.clientId == "client-1")
        #expect(calls.first?.topics == ["dm-1".xmtpGroupTopicFormat])
    }

    @Test("Skips subscription when stored identity does not match client")
    func skipsSubscriptionForIdentityMismatch() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "other-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let apiClient = RecordingPushAPIClient()
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1")
        )

        await manager.subscribeToInviteDMTopic(
            conversationId: "dm-1",
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "test"
        )

        #expect(apiClient.subscribeCalls.isEmpty)
    }
}

private final class RecordingPushAPIClient: ConvosAPIClientProtocol, @unchecked Sendable {
    struct SubscribeCall: Equatable {
        let deviceId: String
        let clientId: String
        let topics: [String]
    }

    struct UnsubscribeCall: Equatable {
        let clientId: String
        let topics: [String]
    }

    private struct State {
        var subscribeCalls: [SubscribeCall] = []
        var unsubscribeCalls: [UnsubscribeCall] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var subscribeCalls: [SubscribeCall] {
        state.withLock { $0.subscribeCalls }
    }

    var unsubscribeCalls: [UnsubscribeCall] {
        state.withLock { $0.unsubscribeCalls }
    }

    func request(for path: String, method: String, queryParameters: [String: String]?) throws -> URLRequest {
        URLRequest(url: URL(string: "https://example.com")!)
    }

    func registerDevice(deviceId: String, pushToken: String?) async throws {
    }

    func authenticate(appCheckToken: String, retryCount: Int) async throws -> String {
        "token"
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
            $0.subscribeCalls.append(SubscribeCall(deviceId: deviceId, clientId: clientId, topics: topics))
        }
    }

    func unsubscribeFromTopics(clientId: String, topics: [String]) async throws {
        state.withLock {
            $0.unsubscribeCalls.append(UnsubscribeCall(clientId: clientId, topics: topics))
        }
    }

    func unregisterInstallation(clientId: String) async throws {
    }

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

    func listConnections() async throws -> [ConnectionsAPI.ConnectionResponse] {
        []
    }

    func revokeConnection(connectionId: String) async throws {
    }
}
