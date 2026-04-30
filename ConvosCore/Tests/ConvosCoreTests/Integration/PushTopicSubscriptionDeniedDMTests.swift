@testable import ConvosCore
import Foundation
import os.lock
import Testing
@preconcurrency import XMTPiOS

/// Integration tests for `PushTopicSubscriptionManager`'s denied-DM filter,
/// run against a local XMTP node (`./dev/up`). The filter cannot be exercised
/// in pure unit tests because `XMTPiOS.Conversation.consentState()` requires
/// real MLS state.
@Suite("Push Topic Subscription Denied DM Tests", .serialized)
struct PushTopicSubscriptionDeniedDMTests {
    private func createClient() async throws -> Client {
        var keyBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &keyBytes)
        let dbKey = Data(keyBytes)
        let options = ClientOptions(
            api: .init(env: .local, appVersion: "convos-tests/1.0.0"),
            codecs: [TextCodec()],
            dbEncryptionKey: dbKey
        )
        return try await Client.createInMemory(
            account: try PrivateKey.generate(),
            options: options
        )
    }

    @Test("Skips subscribing to a DM the user has manually denied")
    func skipsDeniedDmOnSubscribe() async throws {
        let creatorClient = try await createClient()
        let joinerClient = try await createClient()
        defer {
            try? creatorClient.deleteLocalDatabase()
            try? joinerClient.deleteLocalDatabase()
        }

        let dm = try await joinerClient.conversations.findOrCreateDm(
            with: creatorClient.inboxId
        )
        try await dm.send(encodedContent: TextCodec().encode(content: "ping"))

        _ = try await creatorClient.conversations.syncAllConversations(consentStates: nil)

        let creatorDms = try creatorClient.conversations.listDms(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityBeforeNs: nil,
            lastActivityAfterNs: nil,
            limit: nil,
            consentStates: nil,
            orderBy: .lastActivity
        )
        let creatorDm = try #require(creatorDms.first { $0.id == dm.id })
        try await creatorDm.updateConsentState(state: .denied)

        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(
            inboxId: creatorClient.inboxId,
            clientId: "client-1",
            keys: keys
        )
        let apiClient = ThrowawayPushAPIClient()
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1")
        )

        await manager.subscribeToInviteDMTopics(
            conversationIds: [dm.id],
            params: SyncClientParams(client: creatorClient, apiClient: apiClient),
            context: "denied-dm-test"
        )

        #expect(apiClient.subscribeCalls.isEmpty, "Manager must not call subscribeToTopics for a denied DM")
    }

    @Test("Subscribes a DM that has not been denied")
    func subscribesAllowedDmOnSubscribe() async throws {
        let creatorClient = try await createClient()
        let joinerClient = try await createClient()
        defer {
            try? creatorClient.deleteLocalDatabase()
            try? joinerClient.deleteLocalDatabase()
        }

        let dm = try await joinerClient.conversations.findOrCreateDm(
            with: creatorClient.inboxId
        )
        try await dm.send(encodedContent: TextCodec().encode(content: "ping"))

        _ = try await creatorClient.conversations.syncAllConversations(consentStates: nil)

        let creatorDms = try creatorClient.conversations.listDms(
            createdAfterNs: nil,
            createdBeforeNs: nil,
            lastActivityBeforeNs: nil,
            lastActivityAfterNs: nil,
            limit: nil,
            consentStates: nil,
            orderBy: .lastActivity
        )
        let creatorDm = try #require(creatorDms.first { $0.id == dm.id })
        try await creatorDm.updateConsentState(state: .allowed)

        let identityStore = MockKeychainIdentityStore()
        let keys = try await identityStore.generateKeys()
        _ = try await identityStore.save(
            inboxId: creatorClient.inboxId,
            clientId: "client-1",
            keys: keys
        )
        let apiClient = ThrowawayPushAPIClient()
        let manager = PushTopicSubscriptionManager(
            identityStore: identityStore,
            deviceInfoProvider: MockDeviceInfoProvider(deviceIdentifier: "device-1")
        )

        await manager.subscribeToInviteDMTopics(
            conversationIds: [dm.id],
            params: SyncClientParams(client: creatorClient, apiClient: apiClient),
            context: "allowed-dm-test"
        )

        #expect(apiClient.subscribeCalls.count == 1)
        #expect(apiClient.subscribeCalls.first?.topics == [dm.id.xmtpGroupTopicFormat])
    }
}

private final class ThrowawayPushAPIClient: ConvosAPIClientProtocol, @unchecked Sendable {
    struct SubscribeCall: Equatable {
        let deviceId: String
        let clientId: String
        let topics: [String]
    }

    private let lock = OSAllocatedUnfairLock(initialState: [SubscribeCall]())

    var subscribeCalls: [SubscribeCall] {
        lock.withLock { $0 }
    }

    func request(for path: String, method: String, queryParameters: [String: String]?) throws -> URLRequest {
        URLRequest(url: URL(string: "https://example.com")!)
    }

    func registerDevice(deviceId: String, pushToken: String?) async throws {}

    func authenticate(appCheckToken: String, retryCount: Int) async throws -> String { "token" }

    func uploadAttachment(data: Data, filename: String, contentType: String, acl: String) async throws -> String { "" }

    func uploadAttachmentAndExecute(
        data: Data,
        filename: String,
        afterUpload: @escaping (String) async throws -> Void
    ) async throws -> String { "" }

    func subscribeToTopics(deviceId: String, clientId: String, topics: [String]) async throws {
        lock.withLock {
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
