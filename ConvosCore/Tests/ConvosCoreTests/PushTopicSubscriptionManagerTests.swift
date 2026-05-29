@testable import ConvosCore
import Foundation
import os.lock
import Testing
@preconcurrency import XMTPiOS

@Suite("Push Topic Subscription Manager Tests")
struct PushTopicSubscriptionManagerTests {
    @Test("Subscribes group and welcome topics")
    func subscribesGroupAndWelcomeTopics() async throws {
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

        await manager.subscribeToGroupAndWelcome(
            conversationId: "group-1",
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "test"
        )

        let calls = apiClient.subscribeCalls
        #expect(calls.count == 1)
        #expect(calls.first?.deviceId == "device-1")
        #expect(calls.first?.clientId == "client-1")
        #expect(calls.first?.topics == [
            "group-1".xmtpGroupTopicFormat,
            "test-installation-id".xmtpWelcomeTopicFormat,
        ])
    }

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

    @Test("Reconciles welcome, group, and invite DM topics with deduplication")
    func reconcilesPushTopics() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let apiClient = RecordingPushAPIClient()
        let conversationLister = RecordingPushConversationLister(
            groupIds: ["group-1", "shared-conversation"],
            dmIds: ["dm-1", "shared-conversation"]
        )
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1"),
            conversationLister: conversationLister
        )

        await manager.reconcilePushTopics(
            params: SyncClientParams(
                client: client,
                apiClient: apiClient,
                consentStates: [.allowed]
            ),
            context: "test"
        )

        let groupCalls = conversationLister.groupCalls
        let dmCalls = conversationLister.dmCalls
        #expect(groupCalls.count == 1)
        #expect(groupCalls.first?.consentStateRawValues == ["allowed"])
        #expect(groupCalls.first?.usesLastActivityOrder == true)
        #expect(dmCalls.count == 1)
        #expect(dmCalls.first?.consentStateRawValues == ["unknown", "allowed"])
        #expect(dmCalls.first?.usesLastActivityOrder == true)

        let calls = apiClient.subscribeCalls
        #expect(calls.count == 1)
        #expect(calls.first?.topics == [
            "test-installation-id".xmtpWelcomeTopicFormat,
            "group-1".xmtpGroupTopicFormat,
            "shared-conversation".xmtpGroupTopicFormat,
            "dm-1".xmtpGroupTopicFormat,
        ])
    }

    @Test("Subscribe failure is swallowed so callers don't surface it")
    func subscribeFailureIsSwallowed() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let apiClient = ThrowingPushAPIClient()
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1")
        )

        // Caller must not propagate; this would fail compilation if the manager
        // started rethrowing. The QAEvent emission for the failure is exercised
        // by integration tests where ConvosLog is wired up.
        await manager.subscribeToGroupAndWelcome(
            conversationId: "group-1",
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "test"
        )

        #expect(apiClient.subscribeCallCount == 1)
    }

    @Test("Reconcile cache hit skips the wire on identical topic set")
    func reconcileCacheHitSkipsTheWire() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let apiClient = RecordingPushAPIClient()
        let conversationLister = RecordingPushConversationLister(
            groupIds: ["group-1"],
            dmIds: ["dm-1"]
        )
        let cache = isolatedCache()
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1"),
            conversationLister: conversationLister,
            cache: cache,
            pushTokenProvider: { "fake-apns-token" }
        )

        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "first"
        )
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "second"
        )

        // First reconcile hits the wire and primes the cache; the second sees
        // an identical hash and short-circuits before the API call.
        #expect(apiClient.subscribeCalls.count == 1)
    }

    @Test("Reconcile cache miss sends when topic set changes between calls")
    func reconcileCacheMissSends() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let apiClient = RecordingPushAPIClient()
        let conversationLister = RecordingPushConversationLister(
            groupIds: ["group-1"],
            dmIds: []
        )
        let cache = isolatedCache()
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1"),
            conversationLister: conversationLister,
            cache: cache,
            pushTokenProvider: { "fake-apns-token" }
        )

        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "first"
        )
        conversationLister.setGroupIds(["group-1", "group-2"])
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "second"
        )

        // Set grew between reconciles -> hash differs -> the second call must
        // hit the wire so the new topic actually gets subscribed.
        #expect(apiClient.subscribeCalls.count == 2)
        #expect(apiClient.subscribeCalls.last?.topics.contains("group-2".xmtpGroupTopicFormat) == true)
    }

    @Test("Reconcile failure does not write to cache so the next reconcile retries")
    func reconcileFailureSkipsCacheWrite() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let failingAPI = ThrowingPushAPIClient()
        let recoveryAPI = RecordingPushAPIClient()
        let conversationLister = RecordingPushConversationLister(
            groupIds: ["group-1"],
            dmIds: []
        )
        let cache = isolatedCache()
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1"),
            conversationLister: conversationLister,
            cache: cache,
            pushTokenProvider: { "fake-apns-token" }
        )

        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: failingAPI),
            context: "fail"
        )
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: recoveryAPI),
            context: "retry"
        )

        // Iron-rule regression: a failure on the first call must leave the
        // cache untouched so the second call re-attempts the wire even
        // though the desired topic set is unchanged.
        #expect(failingAPI.subscribeCallCount == 1)
        #expect(recoveryAPI.subscribeCalls.count == 1)
    }

    @Test("Reconcile sends when APNS token changes even if topic set is identical")
    func reconcileSendsWhenTokenChanges() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let apiClient = RecordingPushAPIClient()
        let conversationLister = RecordingPushConversationLister(
            groupIds: ["group-1"],
            dmIds: []
        )
        let cache = isolatedCache()
        let tokenBox = TokenBox(value: "token-A")
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1"),
            conversationLister: conversationLister,
            cache: cache,
            pushTokenProvider: { tokenBox.read() }
        )

        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "token-A"
        )
        tokenBox.set("token-B")
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "token-B"
        )

        // Cache key includes the token hash, so rotating the token produces a
        // miss and a fresh wire call - which is exactly what we need to keep
        // XMTP server's deliveryMechanism aligned with the device's APNS state.
        #expect(apiClient.subscribeCalls.count == 2)
    }

    @Test("Reconcile does NOT write the cache when backend returns remoteApplied:false")
    func reconcileSkipsCacheOnRemoteAppliedFalse() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let apiClient = SkippedRemoteApplyPushAPIClient(skippedReason: "no_push_token")
        let conversationLister = RecordingPushConversationLister(groupIds: ["group-1"], dmIds: [])
        let cache = isolatedCache()
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1"),
            conversationLister: conversationLister,
            cache: cache,
            pushTokenProvider: { "fake-apns-token" }
        )

        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "first"
        )
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "second"
        )

        // Codex D16 regression: HTTP 200 with remoteApplied:false (e.g. backend
        // sees no_push_token / disabled / idempotency-skip) MUST NOT prime the
        // iOS cache. Otherwise iOS would silently debounce future reconciles
        // even though XMTP server never got the subscribe. Both calls should
        // hit the wire because the cache never got written on the first.
        #expect(apiClient.subscribeCallCount == 2)
    }

    @Test("clearCache forces the next reconcile to hit the wire")
    func clearCacheForcesWire() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let apiClient = RecordingPushAPIClient()
        let conversationLister = RecordingPushConversationLister(
            groupIds: ["group-1"],
            dmIds: []
        )
        let cache = isolatedCache()
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1"),
            conversationLister: conversationLister,
            cache: cache,
            pushTokenProvider: { "fake-apns-token" }
        )

        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "first"
        )
        await manager.clearCache()
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "after-clear"
        )

        // Explicit clear is the escape hatch for "Delete all data" / sign-out.
        // Without it the second call would short-circuit on the cache hit.
        #expect(apiClient.subscribeCalls.count == 2)
    }

    @Test("Reconcile still subscribes available topics when one listing fails")
    func reconcileSubscribesAvailableTopicsWhenListingFails() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let apiClient = RecordingPushAPIClient()
        let conversationLister = RecordingPushConversationLister(
            groupIds: [],
            dmIds: ["dm-1"],
            groupShouldFail: true
        )
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1"),
            conversationLister: conversationLister
        )

        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "test"
        )

        let calls = apiClient.subscribeCalls
        #expect(calls.count == 1)
        #expect(calls.first?.topics == [
            "test-installation-id".xmtpWelcomeTopicFormat,
            "dm-1".xmtpGroupTopicFormat,
        ])
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

    private let state: OSAllocatedUnfairLock<State> = OSAllocatedUnfairLock(initialState: State())

    var subscribeCalls: [SubscribeCall] {
        state.withLock { $0.subscribeCalls }
    }

    var unsubscribeCalls: [UnsubscribeCall] {
        state.withLock { $0.unsubscribeCalls }
    }

    func request(for path: String, method: String, queryParameters: [String: String]?) throws -> URLRequest {
        guard let url = URL(string: "https://example.com") else {
            throw URLError(.badURL)
        }
        return URLRequest(url: url)
    }

    func registerDevice(deviceId: String, pushToken: String?) async throws {
    }

    func authenticate(appCheckToken: String, retryCount: Int) async throws -> String {
        "token"
    }

    func authenticateWithSIWE(appCheckToken: String, signing: BackendAuthSigningContext) async throws -> String {
        "siwe-token"
    }

    func updateSIWESigningContext(_ context: BackendAuthSigningContext?) {}

    func accountAuthCheck(jwt: String?) async throws -> ConvosAPI.AuthCheckResponse {
        .init(success: jwt != nil)
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

    func subscribeToTopics(
        deviceId: String,
        clientId: String,
        topics: [String],
        options: ConvosAPI.SubscribeOptions
    ) async throws -> ConvosAPI.SubscribeResponse {
        state.withLock {
            $0.subscribeCalls.append(SubscribeCall(deviceId: deviceId, clientId: clientId, topics: topics))
        }
        return .init(
            ok: true, remoteApplied: true,
            snapshot: .init(hash: "mock", count: topics.count, lastSubscribeAt: ""),
            skipped: nil
        )
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

    func requestAgentJoin(slug: String, templateId: String?, forceErrorCode: Int?) async throws -> ConvosAPI.AgentJoinResponse {
        .init(success: true, joined: true)
    }

    func initiateCloudConnection(serviceId: String, redirectUri: String) async throws -> CloudConnectionsAPI.InitiateResponse {
        .init(connectionRequestId: "", redirectUrl: "")
    }

    func completeCloudConnection(connectionRequestId: String) async throws -> CloudConnectionsAPI.CompleteResponse {
        .init(connectionId: "", serviceId: "", serviceName: "", composioEntityId: "", composioConnectionId: "", status: "")
    }

    func listCloudConnections() async throws -> [CloudConnectionsAPI.ConnectionResponse] {
        []
    }

    func revokeCloudConnection(connectionId: String) async throws {
    }
}

private enum PushTopicListError: Error {
    case failed
}

private enum ThrowingPushAPIClientError: Error {
    case subscribeFailure
    case unsubscribeFailure
}

private final class ThrowingPushAPIClient: ConvosAPIClientProtocol, @unchecked Sendable {
    private let counter: OSAllocatedUnfairLock<Int> = OSAllocatedUnfairLock(initialState: 0)

    var subscribeCallCount: Int { counter.withLock { $0 } }

    func request(for path: String, method: String, queryParameters: [String: String]?) throws -> URLRequest {
        guard let url = URL(string: "https://example.com") else {
            throw URLError(.badURL)
        }
        return URLRequest(url: url)
    }

    func registerDevice(deviceId: String, pushToken: String?) async throws {}

    func authenticate(appCheckToken: String, retryCount: Int) async throws -> String { "token" }
    func authenticateWithSIWE(appCheckToken: String, signing: BackendAuthSigningContext) async throws -> String { "siwe-token" }
    func updateSIWESigningContext(_ context: BackendAuthSigningContext?) {}
    func accountAuthCheck(jwt: String?) async throws -> ConvosAPI.AuthCheckResponse { .init(success: jwt != nil) }

    func uploadAttachment(data: Data, filename: String, contentType: String, acl: String) async throws -> String { "" }

    func uploadAttachmentAndExecute(
        data: Data,
        filename: String,
        afterUpload: @escaping (String) async throws -> Void
    ) async throws -> String { "" }

    func subscribeToTopics(
        deviceId: String,
        clientId: String,
        topics: [String],
        options: ConvosAPI.SubscribeOptions
    ) async throws -> ConvosAPI.SubscribeResponse {
        counter.withLock { $0 += 1 }
        throw ThrowingPushAPIClientError.subscribeFailure
    }

    func unsubscribeFromTopics(clientId: String, topics: [String]) async throws {
        throw ThrowingPushAPIClientError.unsubscribeFailure
    }

    func unregisterInstallation(clientId: String) async throws {}

    func renewAssetsBatch(assetKeys: [String]) async throws -> AssetRenewalResult {
        AssetRenewalResult(renewed: assetKeys.count, failed: 0, expiredKeys: [])
    }

    func getPresignedUploadURL(filename: String, contentType: String) async throws -> (uploadURL: String, assetURL: String) {
        ("https://example.com/upload/\(filename)", "https://example.com/assets/\(filename)")
    }

    func requestAgentJoin(slug: String, templateId: String?, forceErrorCode: Int?) async throws -> ConvosAPI.AgentJoinResponse {
        .init(success: true, joined: true)
    }

    func initiateCloudConnection(serviceId: String, redirectUri: String) async throws -> CloudConnectionsAPI.InitiateResponse {
        .init(connectionRequestId: "", redirectUrl: "")
    }

    func completeCloudConnection(connectionRequestId: String) async throws -> CloudConnectionsAPI.CompleteResponse {
        .init(connectionId: "", serviceId: "", serviceName: "", composioEntityId: "", composioConnectionId: "", status: "")
    }

    func listCloudConnections() async throws -> [CloudConnectionsAPI.ConnectionResponse] { [] }

    func revokeCloudConnection(connectionId: String) async throws {}
}

private final class RecordingPushConversationLister: PushTopicConversationListing, @unchecked Sendable {
    struct ListCall: Sendable {
        let consentStateRawValues: [String]?
        let usesLastActivityOrder: Bool
    }

    private struct State: Sendable {
        var groupIds: [String]
        var dmIds: [String]
        var groupShouldFail: Bool
        var dmShouldFail: Bool
        var groupCalls: [ListCall] = []
        var dmCalls: [ListCall] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(
        groupIds: [String],
        dmIds: [String],
        groupShouldFail: Bool = false,
        dmShouldFail: Bool = false
    ) {
        state = OSAllocatedUnfairLock(
            initialState: State(
                groupIds: groupIds,
                dmIds: dmIds,
                groupShouldFail: groupShouldFail,
                dmShouldFail: dmShouldFail
            )
        )
    }

    var groupCalls: [ListCall] {
        state.withLock { $0.groupCalls }
    }

    var dmCalls: [ListCall] {
        state.withLock { $0.dmCalls }
    }

    func setGroupIds(_ ids: [String]) {
        state.withLock { $0.groupIds = ids }
    }

    func listGroupConversationIds(
        params _: SyncClientParams,
        consentStates: [ConsentState]?,
        orderBy: ConversationsOrderBy
    ) throws -> [String] {
        let call = ListCall(
            consentStateRawValues: consentStates?.map(\.rawValue),
            usesLastActivityOrder: usesLastActivityOrder(orderBy)
        )
        return try state.withLock {
            $0.groupCalls.append(call)
            if $0.groupShouldFail {
                throw PushTopicListError.failed
            }
            return $0.groupIds
        }
    }

    func listInviteDMConversationIds(
        params _: SyncClientParams,
        consentStates: [ConsentState]?,
        orderBy: ConversationsOrderBy
    ) throws -> [String] {
        let call = ListCall(
            consentStateRawValues: consentStates?.map(\.rawValue),
            usesLastActivityOrder: usesLastActivityOrder(orderBy)
        )
        return try state.withLock {
            $0.dmCalls.append(call)
            if $0.dmShouldFail {
                throw PushTopicListError.failed
            }
            return $0.dmIds
        }
    }

    private func usesLastActivityOrder(_ orderBy: ConversationsOrderBy) -> Bool {
        guard case .lastActivity = orderBy else { return false }
        return true
    }
}

/// Returns a cache backed by a freshly-named UserDefaults suite so tests can
/// run concurrently without bleeding state into each other (or into the
/// host process's standard UserDefaults).
private func isolatedCache() -> PushTopicSubscriptionCache {
    let suiteName = "PushTopicSubscriptionCacheTests.\(UUID().uuidString)"
    // Force-unwrap is intentional: a UserDefaults suite for a unique UUID
    // cannot collide with another suite or fail allocation in practice. If
    // this ever returns nil the cache tests would silently corrupt
    // `.standard`; abort instead.
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fatalError("Failed to allocate UserDefaults suite \(suiteName) for test")
    }
    return PushTopicSubscriptionCache(userDefaults: defaults)
}

/// Thread-safe mutable string container for swapping the APNS token between
/// reconcile calls. Closure-captured by the test, mutated by `.set(...)`,
/// read by the manager's `pushTokenProvider`.
private final class TokenBox: @unchecked Sendable {
    private let state: OSAllocatedUnfairLock<String?>

    init(value: String?) {
        state = OSAllocatedUnfairLock(initialState: value)
    }

    func read() -> String? {
        state.withLock { $0 }
    }

    func set(_ value: String?) {
        state.withLock { $0 = value }
    }
}

/// Mock API client that returns a 200 with `remoteApplied: false` and a
/// caller-supplied `skipped` reason (Stack 2 D16). Used to assert that iOS
/// does NOT prime the local hash cache when the backend tells us nothing
/// was actually applied at XMTP — the previous "any 200 = success" contract
/// silently broke push delivery for the no_push_token / disabled paths.
private final class SkippedRemoteApplyPushAPIClient: ConvosAPIClientProtocol, @unchecked Sendable {
    private let skippedReason: String
    private let counter: OSAllocatedUnfairLock<Int> = OSAllocatedUnfairLock(initialState: 0)

    var subscribeCallCount: Int { counter.withLock { $0 } }

    init(skippedReason: String) {
        self.skippedReason = skippedReason
    }

    func request(for path: String, method: String, queryParameters: [String: String]?) throws -> URLRequest {
        guard let url = URL(string: "https://example.com") else { throw URLError(.badURL) }
        return URLRequest(url: url)
    }

    func registerDevice(deviceId: String, pushToken: String?) async throws {}
    func authenticate(appCheckToken: String, retryCount: Int) async throws -> String { "token" }
    func authenticateWithSIWE(appCheckToken: String, signing: BackendAuthSigningContext) async throws -> String { "siwe-token" }
    func updateSIWESigningContext(_ context: BackendAuthSigningContext?) {}
    func accountAuthCheck(jwt: String?) async throws -> ConvosAPI.AuthCheckResponse { .init(success: jwt != nil) }
    func uploadAttachment(data: Data, filename: String, contentType: String, acl: String) async throws -> String { "" }
    func uploadAttachmentAndExecute(
        data: Data,
        filename: String,
        afterUpload: @escaping (String) async throws -> Void
    ) async throws -> String { "" }

    func subscribeToTopics(
        deviceId: String,
        clientId: String,
        topics: [String],
        options: ConvosAPI.SubscribeOptions
    ) async throws -> ConvosAPI.SubscribeResponse {
        counter.withLock { $0 += 1 }
        return ConvosAPI.SubscribeResponse(
            ok: true,
            remoteApplied: false,
            snapshot: ConvosAPI.SubscribeResponse.Snapshot(
                hash: "mock", count: topics.count, lastSubscribeAt: ""
            ),
            skipped: skippedReason
        )
    }

    func unsubscribeFromTopics(clientId: String, topics: [String]) async throws {}
    func unregisterInstallation(clientId: String) async throws {}
    func renewAssetsBatch(assetKeys: [String]) async throws -> AssetRenewalResult {
        AssetRenewalResult(renewed: assetKeys.count, failed: 0, expiredKeys: [])
    }
    func getPresignedUploadURL(filename: String, contentType: String) async throws -> (uploadURL: String, assetURL: String) {
        ("https://example.com/upload/\(filename)", "https://example.com/assets/\(filename)")
    }
    func requestAgentJoin(slug: String, templateId: String?, forceErrorCode: Int?) async throws -> ConvosAPI.AgentJoinResponse {
        .init(success: true, joined: true)
    }
    func initiateCloudConnection(serviceId: String, redirectUri: String) async throws -> CloudConnectionsAPI.InitiateResponse {
        .init(connectionRequestId: "", redirectUrl: "")
    }
    func completeCloudConnection(connectionRequestId: String) async throws -> CloudConnectionsAPI.CompleteResponse {
        .init(connectionId: "", serviceId: "", serviceName: "", composioEntityId: "", composioConnectionId: "", status: "")
    }
    func listCloudConnections() async throws -> [CloudConnectionsAPI.ConnectionResponse] { [] }
    func revokeCloudConnection(connectionId: String) async throws {}
}
