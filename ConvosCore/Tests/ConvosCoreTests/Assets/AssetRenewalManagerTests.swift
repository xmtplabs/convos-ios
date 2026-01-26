@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("AssetRenewalManager Tests", .serialized)
struct AssetRenewalManagerTests {
    @Test("performRenewalIfNeeded skips when interval not reached")
    func testSkipsWhenNotDue() async throws {
        let fixtures = try await makeTestFixtures()
        UserDefaults.standard.set(Date(), forKey: "assetRenewalLastDate")
        defer { clearUserDefaults() }

        await fixtures.manager.performRenewalIfNeeded()

        #expect(fixtures.mockAPI.renewCallCount == 0)
    }

    @Test("performRenewalIfNeeded runs when interval reached")
    func testRunsWhenDue() async throws {
        let fixtures = try await makeTestFixtures()
        let oldDate = Date().addingTimeInterval(-20 * 24 * 60 * 60)
        UserDefaults.standard.set(oldDate, forKey: "assetRenewalLastDate")
        defer { clearUserDefaults() }

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

        await fixtures.manager.performRenewalIfNeeded()

        #expect(fixtures.mockAPI.renewCallCount == 1)
    }

    @Test("performRenewalIfNeeded runs on first launch")
    func testRunsOnFirstLaunch() async throws {
        let fixtures = try await makeTestFixtures()
        UserDefaults.standard.removeObject(forKey: "assetRenewalLastDate")
        defer { clearUserDefaults() }

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

        await fixtures.manager.performRenewalIfNeeded()

        #expect(fixtures.mockAPI.renewCallCount == 1)
    }

    @Test("forceRenewal always runs")
    func testForceRenewalAlwaysRuns() async throws {
        let fixtures = try await makeTestFixtures()
        UserDefaults.standard.set(Date(), forKey: "assetRenewalLastDate")
        defer { clearUserDefaults() }

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

        _ = await fixtures.manager.forceRenewal()

        #expect(fixtures.mockAPI.renewCallCount == 1)
    }

    @Test("renewSingleAsset records per-asset date on success")
    func testRenewSingleAssetRecordsDate() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 1, failed: 0, expiredKeys: [])
        defer { clearUserDefaults() }

        let asset = RenewableAsset.profileAvatar(
            url: "https://example.com/avatar.bin",
            conversationId: "convo-1",
            inboxId: "inbox-1"
        )

        let result = await fixtures.manager.renewSingleAsset(asset)

        #expect(result?.renewed == 1)
        #expect(AssetRenewalManager.lastRenewalDate(for: "avatar.bin") != nil)
    }

    @Test("renewSingleAsset does not record date on failure")
    func testRenewSingleAssetNoDateOnFailure() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 0, failed: 1, expiredKeys: [])
        defer { clearUserDefaults() }

        let asset = RenewableAsset.profileAvatar(
            url: "https://example.com/avatar.bin",
            conversationId: "convo-1",
            inboxId: "inbox-1"
        )

        _ = await fixtures.manager.renewSingleAsset(asset)

        #expect(AssetRenewalManager.lastRenewalDate(for: "avatar.bin") == nil)
    }

    @Test("renewSingleAsset handles expired asset by clearing URL")
    func testRenewSingleAssetHandlesExpired() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 0, failed: 1, expiredKeys: ["avatar.bin"])
        defer { clearUserDefaults() }

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
            inboxId: "inbox-1"
        )

        let result = await fixtures.manager.renewSingleAsset(asset)

        #expect(result?.expiredKeys.contains("avatar.bin") == true)

        let profile = try await fixtures.dbReader.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: "convo-1", inboxId: "inbox-1")
        }
        #expect(profile?.avatar == nil)
    }

    @Test("renewSingleAsset returns nil for asset without key")
    func testRenewSingleAssetNilForNoKey() async throws {
        let fixtures = try await makeTestFixtures()

        // URL with path "/" (count == 1) has nil key
        let asset = RenewableAsset.groupImage(url: "https://example.com", conversationId: "convo-1")

        let result = await fixtures.manager.renewSingleAsset(asset)

        #expect(result == nil)
        #expect(fixtures.mockAPI.renewCallCount == 0)
    }

    @Test("lastRenewalDate returns nil for unknown key")
    func testLastRenewalDateNilForUnknown() {
        clearUserDefaults()
        #expect(AssetRenewalManager.lastRenewalDate(for: "unknown-key") == nil)
    }

    @Test("nextRenewalDate returns nil for unknown key")
    func testNextRenewalDateNilForUnknown() {
        clearUserDefaults()
        #expect(AssetRenewalManager.nextRenewalDate(for: "unknown-key") == nil)
    }

    @Test("nextRenewalDate calculates correctly")
    func testNextRenewalDateCalculation() {
        clearUserDefaults()
        defer { clearUserDefaults() }

        let now = Date()
        var dict: [String: Any] = [:]
        dict["test-key"] = now.timeIntervalSince1970
        UserDefaults.standard.set(dict, forKey: "assetRenewalPerAssetDates")

        let nextDate = AssetRenewalManager.nextRenewalDate(for: "test-key")

        #expect(nextDate != nil)
        let expectedNext = now.addingTimeInterval(15 * 24 * 60 * 60)
        let diff = abs(nextDate!.timeIntervalSince(expectedNext))
        #expect(diff < 1)
    }

    @Test("Batch renewal records per-asset dates for renewed keys")
    func testBatchRenewalRecordsPerAssetDates() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 2, failed: 0, expiredKeys: [])
        UserDefaults.standard.removeObject(forKey: "assetRenewalLastDate")
        defer { clearUserDefaults() }

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
                avatar: "https://example.com/avatar.bin"
            ).insert(db)
        }

        _ = await fixtures.manager.forceRenewal()

        #expect(AssetRenewalManager.lastRenewalDate(for: "avatar.bin") != nil)
        #expect(AssetRenewalManager.lastRenewalDate(for: "group.bin") != nil)
    }

    @Test("Batch renewal does not record dates for expired keys")
    func testBatchRenewalSkipsExpiredKeys() async throws {
        let fixtures = try await makeTestFixtures()
        fixtures.mockAPI.renewResult = AssetRenewalResult(renewed: 1, failed: 1, expiredKeys: ["avatar.bin"])
        UserDefaults.standard.removeObject(forKey: "assetRenewalLastDate")
        defer { clearUserDefaults() }

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
                avatar: "https://example.com/avatar.bin"
            ).insert(db)
        }

        _ = await fixtures.manager.forceRenewal()

        #expect(AssetRenewalManager.lastRenewalDate(for: "avatar.bin") == nil)
        #expect(AssetRenewalManager.lastRenewalDate(for: "group.bin") != nil)
    }
}

private extension AssetRenewalManagerTests {
    struct TestFixtures {
        let dbWriter: any DatabaseWriter
        let dbReader: any DatabaseReader
        let mockAPI: ConfigurableMockAPIClient
        let manager: AssetRenewalManager
    }

    func makeTestFixtures() async throws -> TestFixtures {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let mockAPI = ConfigurableMockAPIClient()
        let recoveryHandler = ExpiredAssetRecoveryHandler(databaseWriter: dbManager.dbWriter)

        let manager = AssetRenewalManager(
            databaseReader: dbManager.dbReader,
            apiClient: mockAPI,
            recoveryHandler: recoveryHandler,
            renewalInterval: 15 * 24 * 60 * 60
        )

        return TestFixtures(
            dbWriter: dbManager.dbWriter,
            dbReader: dbManager.dbReader,
            mockAPI: mockAPI,
            manager: manager
        )
    }

    func clearUserDefaults() {
        UserDefaults.standard.removeObject(forKey: "assetRenewalLastDate")
        UserDefaults.standard.removeObject(forKey: "assetRenewalPerAssetDates")
    }

    func makeDBConversation(
        id: String,
        inboxId: String,
        clientId: String,
        kind: ConversationKind = .dm,
        imageURL: String? = nil
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
            isLocked: false
        )
    }
}

final class ConfigurableMockAPIClient: ConvosAPIClientProtocol, @unchecked Sendable {
    var renewCallCount: Int = 0
    var renewResult: AssetRenewalResult = AssetRenewalResult(renewed: 0, failed: 0, expiredKeys: [])
    var shouldThrow: Bool = false

    func renewAssetsBatch(assetKeys: [String]) async throws -> AssetRenewalResult {
        renewCallCount += 1
        if shouldThrow {
            throw NSError(domain: "Test", code: 1)
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

