@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("AssetRenewalManager Tests", .serialized)
struct AssetRenewalManagerTests {
    @Test("performRenewalIfNeeded skips when no stale assets")
    func testSkipsWhenNoStaleAssets() async throws {
        let fixtures = try await makeTestFixtures()
        let recentDate = Date()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                name: "Test",
                avatar: "https://example.com/avatar.bin",
                avatarLastRenewed: recentDate
            ).insert(db)
        }

        await fixtures.manager.performRenewalIfNeeded()

        #expect(fixtures.mockAPI.renewCallCount == 0)
    }

    @Test("performRenewalIfNeeded runs when assets are stale")
    func testRunsWhenAssetsStale() async throws {
        let fixtures = try await makeTestFixtures()
        let oldDate = Date().addingTimeInterval(-20 * 24 * 60 * 60)

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                name: "Test",
                avatar: "https://example.com/avatar.bin",
                avatarLastRenewed: oldDate
            ).insert(db)
        }

        await fixtures.manager.performRenewalIfNeeded()

        #expect(fixtures.mockAPI.renewCallCount == 1)
    }

    @Test("performRenewalIfNeeded runs for assets never renewed")
    func testRunsForNeverRenewedAssets() async throws {
        let fixtures = try await makeTestFixtures()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                name: "Test",
                avatar: "https://example.com/avatar.bin",
                avatarLastRenewed: nil
            ).insert(db)
        }

        await fixtures.manager.performRenewalIfNeeded()

        #expect(fixtures.mockAPI.renewCallCount == 1)
    }

    @Test("forceRenewal always runs regardless of timestamps")
    func testForceRenewalAlwaysRuns() async throws {
        let fixtures = try await makeTestFixtures()
        let recentDate = Date()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                name: "Test",
                avatar: "https://example.com/avatar.bin",
                avatarLastRenewed: recentDate
            ).insert(db)
        }

        _ = await fixtures.manager.forceRenewal()

        #expect(fixtures.mockAPI.renewCallCount == 1)
    }

    @Test("renewSingleAsset records timestamp in database on success")
    func testRenewSingleAssetRecordsTimestamp() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 1, failed: 0, expiredKeys: [])

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                name: "Test",
                avatar: "https://example.com/avatar.bin",
                avatarLastRenewed: nil
            ).insert(db)
        }

        let asset = RenewableAsset.profileAvatar(
            url: "https://example.com/avatar.bin",
            conversationId: "convo-1",
            inboxId: "inbox-1",
            lastRenewed: nil
        )

        let result = await fixtures.manager.renewSingleAsset(asset)

        #expect(result?.renewed == 1)

        let profile = try await fixtures.dbWriter.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: "convo-1", inboxId: "inbox-1")
        }
        #expect(profile?.avatarLastRenewed != nil)
    }

    @Test("renewSingleAsset does not record timestamp on failure")
    func testRenewSingleAssetNoTimestampOnFailure() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 0, failed: 1, expiredKeys: [])

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                name: "Test",
                avatar: "https://example.com/avatar.bin",
                avatarLastRenewed: nil
            ).insert(db)
        }

        let asset = RenewableAsset.profileAvatar(
            url: "https://example.com/avatar.bin",
            conversationId: "convo-1",
            inboxId: "inbox-1",
            lastRenewed: nil
        )

        _ = await fixtures.manager.renewSingleAsset(asset)

        let profile = try await fixtures.dbWriter.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: "convo-1", inboxId: "inbox-1")
        }
        #expect(profile?.avatarLastRenewed == nil)
    }

    @Test("renewSingleAsset handles expired asset by clearing URL")
    func testRenewSingleAssetHandlesExpired() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 0, failed: 1, expiredKeys: ["avatar.bin"])

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                name: "Test",
                avatar: "https://example.com/avatar.bin"
            ).insert(db)
        }

        let asset = RenewableAsset.profileAvatar(
            url: "https://example.com/avatar.bin",
            conversationId: "convo-1",
            inboxId: "inbox-1",
            lastRenewed: nil
        )

        let result = await fixtures.manager.renewSingleAsset(asset)

        #expect(result?.expiredKeys.contains("avatar.bin") == true)

        let profile = try await fixtures.dbWriter.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: "convo-1", inboxId: "inbox-1")
        }
        #expect(profile?.avatar == nil)
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
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try makeDBConversation(
                id: "convo-2",
                inboxId: "inbox-1",
                clientId: "client-1",
                kind: .group,
                imageURL: "https://example.com/group.bin"
            ).insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                name: "Test",
                avatar: "https://example.com/avatar.bin",
                avatarLastRenewed: nil
            ).insert(db)
        }

        _ = await fixtures.manager.forceRenewal()

        let profile = try await fixtures.dbWriter.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: "convo-1", inboxId: "inbox-1")
        }
        let conversation = try await fixtures.dbWriter.read { db in
            try DBConversation.fetchOne(db, key: "convo-2")
        }
        #expect(profile?.avatarLastRenewed != nil)
        #expect(conversation?.imageLastRenewed != nil)
    }

    @Test("Batch renewal does not record timestamps for expired assets")
    func testBatchRenewalSkipsExpiredAssets() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 1, failed: 1, expiredKeys: ["avatar.bin"])

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try makeDBConversation(
                id: "convo-2",
                inboxId: "inbox-1",
                clientId: "client-1",
                kind: .group,
                imageURL: "https://example.com/group.bin"
            ).insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                name: "Test",
                avatar: "https://example.com/avatar.bin",
                avatarLastRenewed: nil
            ).insert(db)
        }

        _ = await fixtures.manager.forceRenewal()

        let profile = try await fixtures.dbWriter.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: "convo-1", inboxId: "inbox-1")
        }
        let conversation = try await fixtures.dbWriter.read { db in
            try DBConversation.fetchOne(db, key: "convo-2")
        }
        #expect(profile?.avatarLastRenewed == nil)
        #expect(conversation?.imageLastRenewed != nil)
    }

    @Test("Batch renewal handles API error gracefully")
    func testBatchRenewalHandlesApiError() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewHandler = { _ in
            throw NSError(domain: "Test", code: 1)
        }

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                name: "Test",
                avatar: "https://example.com/avatar.bin",
                avatarLastRenewed: nil
            ).insert(db)
        }

        let result = await fixtures.manager.forceRenewal()

        #expect(fixtures.mockAPI.renewCallCount == 1)
        #expect(result?.failed == 1)
        #expect(result?.renewed == 0)
    }

    @Test("Records renewal for all profiles with same URL")
    func testRecordsRenewalForAllProfilesWithSameURL() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 1, failed: 0, expiredKeys: [])
        let sharedAvatarURL = "https://example.com/shared-avatar.bin"

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try makeDBConversation(id: "convo-2", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try makeDBConversation(id: "convo-3", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                name: "Me in convo 1",
                avatar: sharedAvatarURL,
                avatarLastRenewed: nil
            ).insert(db)
            try DBMemberProfile(
                conversationId: "convo-2",
                inboxId: "inbox-1",
                name: "Me in convo 2",
                avatar: sharedAvatarURL,
                avatarLastRenewed: nil
            ).insert(db)
            try DBMemberProfile(
                conversationId: "convo-3",
                inboxId: "inbox-1",
                name: "Me in convo 3",
                avatar: sharedAvatarURL,
                avatarLastRenewed: nil
            ).insert(db)
        }

        _ = await fixtures.manager.forceRenewal()

        #expect(fixtures.mockAPI.renewCallCount == 1)

        let profiles = try await fixtures.dbWriter.read { db in
            try DBMemberProfile
                .filter(DBMemberProfile.Columns.avatar == sharedAvatarURL)
                .fetchAll(db)
        }
        #expect(profiles.count == 3)
        for profile in profiles {
            #expect(profile.avatarLastRenewed != nil)
        }
    }

    @Test("Prevents concurrent renewals via actor isolation")
    func testPreventsConcurrentRenewals() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 1, failed: 0, expiredKeys: [])

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                name: "Test",
                avatar: "https://example.com/avatar.bin",
                avatarLastRenewed: nil
            ).insert(db)
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
            inboxId: inboxId,
            clientId: clientId,
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
            imageLastRenewed: imageLastRenewed
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
        URLRequest(url: URL(string: "https://example.com")!)
    }

    func registerDevice(deviceId: String, pushToken: String?) async throws {}
    func authenticate(appCheckToken: String, retryCount: Int) async throws -> String { "token" }
    func uploadAttachment(data: Data, filename: String, contentType: String, acl: String) async throws -> String { "" }
    func uploadAttachmentAndExecute(data: Data, filename: String, afterUpload: @escaping (String) async throws -> Void) async throws -> String { "" }
    func subscribeToTopics(deviceId: String, clientId: String, topics: [String]) async throws {}
    func unsubscribeFromTopics(clientId: String, topics: [String]) async throws {}
    func unregisterInstallation(clientId: String) async throws {}
}
