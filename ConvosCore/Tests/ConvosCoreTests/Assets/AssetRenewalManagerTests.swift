@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("AssetRenewalManager Tests", .serialized)
struct AssetRenewalManagerTests {
    private let avatarURL = "https://example.com/avatar.bin"

    @Test("performRenewalIfNeeded skips when no stale assets")
    func testSkipsWhenNoStaleAssets() async throws {
        let fixtures = try await makeTestFixtures()
        let recentDate = Date()

        try await fixtures.dbWriter.write { db in
            try seedInbox(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try seedAvatar(db, conversationId: "convo-1", url: avatarURL, lastRenewed: recentDate)
        }

        await fixtures.manager.performRenewalIfNeeded()

        #expect(fixtures.mockAPI.renewCallCount == 0)
    }

    @Test("performRenewalIfNeeded runs when assets are stale")
    func testRunsWhenAssetsStale() async throws {
        let fixtures = try await makeTestFixtures()
        let oldDate = Date().addingTimeInterval(-20 * 24 * 60 * 60)

        try await fixtures.dbWriter.write { db in
            try seedInbox(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try seedAvatar(db, conversationId: "convo-1", url: avatarURL, lastRenewed: oldDate)
        }

        await fixtures.manager.performRenewalIfNeeded()

        #expect(fixtures.mockAPI.renewCallCount == 1)
    }

    @Test("performRenewalIfNeeded runs for assets never renewed")
    func testRunsForNeverRenewedAssets() async throws {
        let fixtures = try await makeTestFixtures()

        try await fixtures.dbWriter.write { db in
            try seedInbox(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try seedAvatar(db, conversationId: "convo-1", url: avatarURL, lastRenewed: nil)
        }

        await fixtures.manager.performRenewalIfNeeded()

        #expect(fixtures.mockAPI.renewCallCount == 1)
    }

    @Test("forceRenewal always runs regardless of timestamps")
    func testForceRenewalAlwaysRuns() async throws {
        let fixtures = try await makeTestFixtures()
        let recentDate = Date()

        try await fixtures.dbWriter.write { db in
            try seedInbox(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try seedAvatar(db, conversationId: "convo-1", url: avatarURL, lastRenewed: recentDate)
        }

        _ = await fixtures.manager.forceRenewal()

        #expect(fixtures.mockAPI.renewCallCount == 1)
    }

    @Test("renewSingleAsset records timestamp in database on success")
    func testRenewSingleAssetRecordsTimestamp() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 1, failed: 0, expiredKeys: [])

        try await fixtures.dbWriter.write { db in
            try seedInbox(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try seedAvatar(db, conversationId: "convo-1", url: avatarURL, lastRenewed: nil)
        }

        let asset = RenewableAsset.profileAvatar(
            url: avatarURL,
            conversationId: "convo-1",
            inboxId: "inbox-1",
            lastRenewed: nil
        )

        let result = await fixtures.manager.renewSingleAsset(asset)

        #expect(result?.renewed == 1)

        let avatar = try await fixtures.dbWriter.read { db in
            try DBProfileAvatar.fetchOne(db, inboxId: "inbox-1", conversationId: "convo-1")
        }
        #expect(avatar?.lastRenewed != nil)
    }

    @Test("renewSingleAsset does not record timestamp on failure")
    func testRenewSingleAssetNoTimestampOnFailure() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 0, failed: 1, expiredKeys: [])

        try await fixtures.dbWriter.write { db in
            try seedInbox(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try seedAvatar(db, conversationId: "convo-1", url: avatarURL, lastRenewed: nil)
        }

        let asset = RenewableAsset.profileAvatar(
            url: avatarURL,
            conversationId: "convo-1",
            inboxId: "inbox-1",
            lastRenewed: nil
        )

        _ = await fixtures.manager.renewSingleAsset(asset)

        let avatar = try await fixtures.dbWriter.read { db in
            try DBProfileAvatar.fetchOne(db, inboxId: "inbox-1", conversationId: "convo-1")
        }
        #expect(avatar?.lastRenewed == nil)
    }

    @Test("renewSingleAsset handles expired asset by clearing URL")
    func testRenewSingleAssetHandlesExpired() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 0, failed: 1, expiredKeys: ["avatar.bin"])

        try await fixtures.dbWriter.write { db in
            try seedInbox(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try seedAvatar(db, conversationId: "convo-1", url: avatarURL, lastRenewed: nil)
        }

        let asset = RenewableAsset.profileAvatar(
            url: avatarURL,
            conversationId: "convo-1",
            inboxId: "inbox-1",
            lastRenewed: nil
        )

        let result = await fixtures.manager.renewSingleAsset(asset)

        #expect(result?.expiredKeys.contains("avatar.bin") == true)

        let avatar = try await fixtures.dbWriter.read { db in
            try DBProfileAvatar.fetchOne(db, inboxId: "inbox-1", conversationId: "convo-1")
        }
        #expect(avatar?.url == nil)
    }

    @Test("renewSingleAsset returns nil for asset without key")
    func testRenewSingleAssetNilForNoKey() async throws {
        let fixtures = try await makeTestFixtures()

        let asset = RenewableAsset.groupImage(url: "https://example.com", conversationId: "convo-1", lastRenewed: nil)

        let result = await fixtures.manager.renewSingleAsset(asset)

        #expect(result == nil)
        #expect(fixtures.mockAPI.renewCallCount == 0)
    }

    @Test("Batch renewal records timestamps for renewed assets")
    func testBatchRenewalRecordsTimestamps() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 2, failed: 0, expiredKeys: [])

        try await fixtures.dbWriter.write { db in
            try seedInbox(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try makeDBConversation(
                id: "convo-2",
                inboxId: "inbox-1",
                clientId: "client-1",
                kind: .group,
                imageURL: "https://example.com/group.bin"
            ).insert(db)
            try seedAvatar(db, conversationId: "convo-1", url: avatarURL, lastRenewed: nil)
        }

        _ = await fixtures.manager.forceRenewal()

        let avatar = try await fixtures.dbWriter.read { db in
            try DBProfileAvatar.fetchOne(db, inboxId: "inbox-1", conversationId: "convo-1")
        }
        let conversation = try await fixtures.dbWriter.read { db in
            try DBConversation.fetchOne(db, key: "convo-2")
        }
        #expect(avatar?.lastRenewed != nil)
        #expect(conversation?.imageLastRenewed != nil)
    }

    @Test("Batch renewal does not record timestamps for expired assets")
    func testBatchRenewalSkipsExpiredAssets() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 1, failed: 1, expiredKeys: ["avatar.bin"])

        try await fixtures.dbWriter.write { db in
            try seedInbox(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try makeDBConversation(
                id: "convo-2",
                inboxId: "inbox-1",
                clientId: "client-1",
                kind: .group,
                imageURL: "https://example.com/group.bin"
            ).insert(db)
            try seedAvatar(db, conversationId: "convo-1", url: avatarURL, lastRenewed: nil)
        }

        _ = await fixtures.manager.forceRenewal()

        let avatar = try await fixtures.dbWriter.read { db in
            try DBProfileAvatar.fetchOne(db, inboxId: "inbox-1", conversationId: "convo-1")
        }
        let conversation = try await fixtures.dbWriter.read { db in
            try DBConversation.fetchOne(db, key: "convo-2")
        }
        #expect(avatar?.lastRenewed == nil)
        #expect(conversation?.imageLastRenewed != nil)
    }

    @Test("Batch renewal handles API error gracefully")
    func testBatchRenewalHandlesApiError() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewHandler = { _ in
            throw NSError(domain: "Test", code: 1)
        }

        try await fixtures.dbWriter.write { db in
            try seedInbox(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try seedAvatar(db, conversationId: "convo-1", url: avatarURL, lastRenewed: nil)
        }

        let result = await fixtures.manager.forceRenewal()

        #expect(fixtures.mockAPI.renewCallCount == 1)
        #expect(result?.failed == 1)
        #expect(result?.renewed == 0)
    }

    @Test("Records renewal for all avatar slots with same URL")
    func testRecordsRenewalForAllProfilesWithSameURL() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 1, failed: 0, expiredKeys: [])
        let sharedAvatarURL = "https://example.com/shared-avatar.bin"

        try await fixtures.dbWriter.write { db in
            try seedInbox(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try makeDBConversation(id: "convo-2", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try makeDBConversation(id: "convo-3", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try seedAvatar(db, conversationId: "convo-1", url: sharedAvatarURL, lastRenewed: nil)
            try seedAvatar(db, conversationId: "convo-2", url: sharedAvatarURL, lastRenewed: nil)
            try seedAvatar(db, conversationId: "convo-3", url: sharedAvatarURL, lastRenewed: nil)
        }

        _ = await fixtures.manager.forceRenewal()

        #expect(fixtures.mockAPI.renewCallCount == 1)

        let avatars = try await fixtures.dbWriter.read { db in
            try DBProfileAvatar
                .filter(DBProfileAvatar.Columns.url == sharedAvatarURL)
                .fetchAll(db)
        }
        #expect(avatars.count == 3)
        for avatar in avatars {
            #expect(avatar.lastRenewed != nil)
        }
    }

    @Test("Prevents concurrent renewals via actor isolation")
    func testPreventsConcurrentRenewals() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 1, failed: 0, expiredKeys: [])

        try await fixtures.dbWriter.write { db in
            try seedInbox(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try seedAvatar(db, conversationId: "convo-1", url: avatarURL, lastRenewed: nil)
        }

        async let renewal1: Void = fixtures.manager.performRenewalIfNeeded()
        async let renewal2: Void = fixtures.manager.performRenewalIfNeeded()
        async let renewal3: Void = fixtures.manager.performRenewalIfNeeded()

        _ = await (renewal1, renewal2, renewal3)

        #expect(fixtures.mockAPI.renewCallCount == 1)
    }
}

private extension AssetRenewalManagerTests {
    struct TestFixtures {
        let dbWriter: any DatabaseWriter
        let mockAPI: ConfigurableMockAPIClient
        let manager: AssetRenewalManager
    }

    func makeTestFixtures() async throws -> TestFixtures {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let mockAPI = ConfigurableMockAPIClient()
        let recoveryHandler = ExpiredAssetRecoveryHandler(databaseWriter: dbManager.dbWriter)

        let manager = AssetRenewalManager(
            databaseWriter: dbManager.dbWriter,
            apiClient: mockAPI,
            recoveryHandler: recoveryHandler,
            renewalInterval: 15 * 24 * 60 * 60
        )

        return TestFixtures(
            dbWriter: dbManager.dbWriter,
            mockAPI: mockAPI,
            manager: manager
        )
    }

    func seedInbox(_ db: Database) throws {
        try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
        try DBMember(inboxId: "inbox-1").insert(db)
    }

    func seedAvatar(_ db: Database, conversationId: String, url: String, lastRenewed: Date?) throws {
        try DBProfileAvatar(
            inboxId: "inbox-1",
            conversationId: conversationId,
            url: url,
            profileSource: .profileUpdate,
            updatedAt: Date(),
            lastRenewed: lastRenewed
        ).insert(db)
    }

    func makeDBConversation(
        id: String,
        inboxId: String,
        clientId: String,
        kind: ConversationKind = .dm,
        imageURL: String? = nil,
        imageLastRenewed: Date? = nil
    ) -> DBConversation {
        DBConversation(
            id: id,
            clientConversationId: id,
            inviteTag: "invite-\(id)",
            creatorId: inboxId,
            kind: kind,
            consent: .allowed,
            createdAt: Date(),
            name: nil,
            description: nil,
            imageURLString: imageURL,
            publicImageURLString: nil,
            includeInfoInPublicPreview: false,
            expiresAt: nil,
            debugInfo: .empty,
            isLocked: false,
            imageSalt: nil,
            imageNonce: nil,
            imageEncryptionKey: nil,
            conversationEmoji: nil,
            imageLastRenewed: imageLastRenewed,
            isUnused: false,
            hasHadVerifiedAgent: false,
        )
    }
}

final class ConfigurableMockAPIClient: ConvosAPIClientProtocol, @unchecked Sendable {
    var renewCallCount: Int = 0
    var renewResult: AssetRenewalResult = AssetRenewalResult(renewed: 0, failed: 0, expiredKeys: [])
    var renewHandler: (([String]) throws -> AssetRenewalResult)?

    func renewAssetsBatch(assetKeys: [String]) async throws -> AssetRenewalResult {
        renewCallCount += 1
        if let handler = renewHandler {
            return try handler(assetKeys)
        }
        return renewResult
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
    func uploadAttachmentAndExecute(data: Data, filename: String, afterUpload: @escaping (String) async throws -> Void) async throws -> String { "" }
    func subscribeToTopics(deviceId: String, clientId: String, topics: [String]) async throws {}
    func unsubscribeFromTopics(clientId: String, topics: [String]) async throws {}
    func unregisterInstallation(clientId: String) async throws {}
    func getPresignedUploadURL(filename: String, contentType: String) async throws -> (uploadURL: String, assetURL: String) {
        ("https://example.com/upload/\(filename)", "https://example.com/assets/\(filename)")
    }
    func requestAgentJoin(slug: String, templateId: String?, forceErrorCode: Int? = nil) async throws -> ConvosAPI.AgentJoinResponse {
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
