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

    @Test("Unsubscribes group topic on leave/removal")
    func unsubscribesGroupTopic() async throws {
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

        await manager.unsubscribeFromGroupTopic(
            conversationId: "group-1",
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "leave"
        )

        let calls = apiClient.unsubscribeCalls
        #expect(calls.count == 1)
        #expect(calls.first?.clientId == "client-1")
        // Same topic derivation reconcile uses for groups, so it diffs cleanly.
        #expect(calls.first?.topics == ["group-1".xmtpGroupTopicFormat])
    }

    @Test("Group-topic unsubscribe removes it from the mirror so reconcile re-adds it on rejoin")
    func groupUnsubscribeUpdatesMirror() async throws {
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

        // Establish mirror = {welcome, group-1} via a full reconcile.
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "seed"
        )
        #expect(apiClient.subscribeCalls.count == 1)

        // Unsubscribe the group topic -> mirror becomes {welcome}.
        await manager.unsubscribeFromGroupTopic(
            conversationId: "group-1",
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "leave"
        )
        #expect(apiClient.unsubscribeCalls.count == 1)
        #expect(apiClient.unsubscribeCalls.last?.topics == ["group-1".xmtpGroupTopicFormat])

        // Reconcile again: group-1 is still in the listing but no longer in the
        // mirror, so it must be re-added as a delta -> proves removeTopics ran.
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "reconcile-after-leave"
        )
        #expect(apiClient.subscribeCalls.count == 2)
        #expect(apiClient.subscribeCalls.last?.topics == ["group-1".xmtpGroupTopicFormat])
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

    // MARK: - Batched delta reconcile (>100 topics, mirror, partial failure)

    @Test("Reconcile splits a >100 topic desired set into multiple <=100 batches")
    func reconcileChunksLargeDesiredSet() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let apiClient = RecordingPushAPIClient()
        // 120 groups + welcome = 121 desired topics -> 2 batches (100 + 21).
        let groupIds = (0..<120).map { "group-\($0)" }
        let conversationLister = RecordingPushConversationLister(groupIds: groupIds, dmIds: [])
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1"),
            conversationLister: conversationLister
        )

        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "large"
        )

        let calls = apiClient.subscribeCalls
        #expect(calls.count == 2)
        // Every batch must respect the 100-topic-per-request backend cap.
        #expect(calls.allSatisfy { $0.topics.count <= 100 })
        #expect(calls.first?.topics.count == 100)
        #expect(calls.last?.topics.count == 21)
        // No topic dropped or duplicated across the batches.
        let delivered = Set(calls.flatMap(\.topics))
        var expected = Set(groupIds.map(\.xmtpGroupTopicFormat))
        expected.insert("test-installation-id".xmtpWelcomeTopicFormat)
        #expect(delivered == expected)
    }

    @Test("Cold-start nil mirror triggers a full chunked additive re-subscribe")
    func reconcileColdStartFullChunkedResubscribe() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let apiClient = RecordingPushAPIClient()
        let groupIds = (0..<150).map { "group-\($0)" }
        let conversationLister = RecordingPushConversationLister(groupIds: groupIds, dmIds: [])
        let cache = isolatedCache()
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1"),
            conversationLister: conversationLister,
            cache: cache,
            pushTokenProvider: { "fake-apns-token" }
        )

        // Cold start: mirror is nil, so toAdd is the FULL desired set, chunked.
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "cold"
        )

        let calls = apiClient.subscribeCalls
        // 151 desired topics -> 2 chunks (100 + 51); no unsubscribe on cold start.
        #expect(calls.count == 2)
        #expect(calls.allSatisfy { $0.topics.count <= 100 })
        #expect(apiClient.unsubscribeCalls.isEmpty)
        let delivered = Set(calls.flatMap(\.topics))
        var expected = Set(groupIds.map(\.xmtpGroupTopicFormat))
        expected.insert("test-installation-id".xmtpWelcomeTopicFormat)
        #expect(delivered == expected)

        // Mirror now equals desired -> a second reconcile is a pure no-op.
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "warm"
        )
        #expect(apiClient.subscribeCalls.count == 2)
    }

    @Test("Reconcile delta sends additive subscribe for adds and unsubscribe for removes")
    func reconcileDeltaAddAndRemove() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let apiClient = RecordingPushAPIClient()
        let conversationLister = RecordingPushConversationLister(
            groupIds: ["group-1", "group-2"],
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

        // First reconcile establishes the mirror = {welcome, group-1, group-2}.
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "first"
        )
        #expect(apiClient.subscribeCalls.count == 1)

        // group-1 leaves, group-3 joins. Desired = {welcome, group-2, group-3}.
        conversationLister.setGroupIds(["group-2", "group-3"])
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "delta"
        )

        // Exactly one additive subscribe for the single add (group-3)...
        #expect(apiClient.subscribeCalls.count == 2)
        #expect(apiClient.subscribeCalls.last?.topics == ["group-3".xmtpGroupTopicFormat])
        // ...and exactly one unsubscribe for the single removal (group-1).
        #expect(apiClient.unsubscribeCalls.count == 1)
        #expect(apiClient.unsubscribeCalls.last?.topics == ["group-1".xmtpGroupTopicFormat])
    }

    @Test("Partial batch failure leaves the mirror stale so the next reconcile re-converges")
    func reconcilePartialFailureLeavesMirrorStale() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        // Fail the very first subscribe batch only; later batches/calls succeed.
        let apiClient = PartialFailurePushAPIClient(failFirstNSubscribeCalls: 1)
        let groupIds = (0..<120).map { "group-\($0)" }
        let conversationLister = RecordingPushConversationLister(groupIds: groupIds, dmIds: [])
        let cache = isolatedCache()
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1"),
            conversationLister: conversationLister,
            cache: cache,
            pushTokenProvider: { "fake-apns-token" }
        )

        // First reconcile: 2 chunks, the first throws -> allSucceeded == false
        // -> mirror NOT persisted even though chunk 2 landed.
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "partial-fail"
        )
        #expect(apiClient.subscribeCalls.count == 2)

        // Second reconcile: mirror is still nil, so the FULL desired set is
        // re-sent (additive + idempotent makes re-subscribing landed topics
        // harmless), this time with no failures -> mirror finally persists.
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "reconverge"
        )
        #expect(apiClient.subscribeCalls.count == 4)

        // Third reconcile: mirror now matches desired -> pure no-op.
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "settled"
        )
        #expect(apiClient.subscribeCalls.count == 4)

        // Every desired topic was delivered across the converging passes.
        let delivered = Set(apiClient.subscribeCalls.flatMap(\.topics))
        var expected = Set(groupIds.map(\.xmtpGroupTopicFormat))
        expected.insert("test-installation-id".xmtpWelcomeTopicFormat)
        #expect(expected.isSubset(of: delivered))
    }

    @Test("Per-conversation subscribe folds the topic into the mirror")
    func perConversationSubscribeUpdatesMirror() async throws {
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

        // Join group-1 incrementally -> mirror should now hold welcome + group-1.
        await manager.subscribeToGroupAndWelcome(
            conversationId: "group-1",
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "join"
        )
        #expect(apiClient.subscribeCalls.count == 1)

        // A reconcile whose desired set is exactly {welcome, group-1} must be a
        // no-op: the per-conversation path already recorded both in the mirror.
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "reconcile-after-join"
        )
        #expect(apiClient.subscribeCalls.count == 1)
        #expect(apiClient.unsubscribeCalls.isEmpty)
    }

    @Test("Per-conversation invite-DM unsubscribe removes the topic from the mirror")
    func perConversationUnsubscribeUpdatesMirror() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let apiClient = RecordingPushAPIClient()
        // Reconcile desires the invite DM, so after unsubscribe (which removes
        // it from the mirror) a reconcile with the same DM still in the desired
        // set must re-add it -> proves the mirror was actually mutated.
        let conversationLister = RecordingPushConversationLister(
            groupIds: [],
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

        // Establish mirror = {welcome, dm-1} via a full reconcile.
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "seed"
        )
        #expect(apiClient.subscribeCalls.count == 1)

        // Unsubscribe the invite DM -> mirror becomes {welcome}.
        await manager.unsubscribeFromInviteDMTopic(
            conversationId: "dm-1",
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "reject"
        )
        #expect(apiClient.unsubscribeCalls.count == 1)
        #expect(apiClient.unsubscribeCalls.last?.topics == ["dm-1".xmtpGroupTopicFormat])

        // Reconcile again: dm-1 is still desired but no longer in the mirror,
        // so it must be re-added as a delta (proving removeTopics mutated it).
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "reconcile-after-reject"
        )
        #expect(apiClient.subscribeCalls.count == 2)
        #expect(apiClient.subscribeCalls.last?.topics == ["dm-1".xmtpGroupTopicFormat])
    }

    @Test("Degraded listing never unsubscribes applied topics or shrinks the mirror")
    func reconcileDegradedListingDoesNotRemoveAppliedTopics() async throws {
        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(inboxId: "test-inbox-id", clientId: "client-1", keys: keys)

        let client = TestableMockClient()
        client.inboxId = "test-inbox-id"
        let apiClient = RecordingPushAPIClient()
        let conversationLister = RecordingPushConversationLister(
            groupIds: ["group-1", "group-2"],
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

        // Establish mirror = {welcome, group-1, group-2}.
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "seed"
        )
        #expect(apiClient.subscribeCalls.count == 1)

        // Group listing now fails transiently -> desired is DEGRADED (welcome
        // only). A naive delta would unsubscribe group-1/group-2; it must not.
        conversationLister.setGroupShouldFail(true)
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "degraded"
        )
        // No unsubscribe issued from the incomplete desired set.
        #expect(apiClient.unsubscribeCalls.isEmpty)

        // Listing recovers; mirror was left stale so this pass is a clean no-op
        // (still {welcome, group-1, group-2}) -> no new wire calls at all.
        conversationLister.setGroupShouldFail(false)
        await manager.reconcilePushTopics(
            params: SyncClientParams(client: client, apiClient: apiClient),
            context: "recovered"
        )
        #expect(apiClient.unsubscribeCalls.isEmpty)
        // The only subscribe call ever made was the initial seed: the degraded
        // pass re-sent nothing new (welcome already applied) and the recovered
        // pass matched the mirror exactly.
        #expect(apiClient.subscribeCalls.count == 1)
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

    func subscribeToTopics(deviceId: String, clientId: String, topics: [String]) async throws {
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

/// Records every subscribe/unsubscribe call (one per batch) but throws on the
/// first `failFirstNSubscribeCalls` subscribe invocations. Used to prove that a
/// partially-failed multi-batch reconcile does not persist the applied-topic
/// mirror, so the next reconcile re-sends the full desired set.
private final class PartialFailurePushAPIClient: ConvosAPIClientProtocol, @unchecked Sendable {
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
        var remainingFailures: Int
    }

    private let state: OSAllocatedUnfairLock<State>

    init(failFirstNSubscribeCalls: Int) {
        state = OSAllocatedUnfairLock(initialState: State(remainingFailures: failFirstNSubscribeCalls))
    }

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

    func subscribeToTopics(deviceId: String, clientId: String, topics: [String]) async throws {
        let shouldFail: Bool = state.withLock {
            $0.subscribeCalls.append(SubscribeCall(deviceId: deviceId, clientId: clientId, topics: topics))
            if $0.remainingFailures > 0 {
                $0.remainingFailures -= 1
                return true
            }
            return false
        }
        if shouldFail {
            throw ThrowingPushAPIClientError.subscribeFailure
        }
    }

    func unsubscribeFromTopics(clientId: String, topics: [String]) async throws {
        state.withLock {
            $0.unsubscribeCalls.append(UnsubscribeCall(clientId: clientId, topics: topics))
        }
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

    func setGroupShouldFail(_ shouldFail: Bool) {
        state.withLock { $0.groupShouldFail = shouldFail }
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
