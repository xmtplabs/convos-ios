@testable import ConvosCore
import Foundation
import GRDB
import Testing

@Suite("AssetRenewalURLCollector Tests", .serialized)
struct AssetRenewalURLCollectorTests {
    @Test("Collects profile avatars with valid URLs")
    func testCollectsProfileAvatars() async throws {
        let fixtures = try await makeTestFixtures()
        let avatarURL = "https://example.com/avatar123.bin"

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                name: "Test User",
                avatar: avatarURL
            ).insert(db)
        }

        let collector = AssetRenewalURLCollector(databaseReader: fixtures.dbReader)
        let assets = try collector.collectRenewableAssets()

        #expect(assets.count == 1)
        if case let .profileAvatar(url, conversationId, inboxId, _) = assets.first {
            #expect(url == avatarURL)
            #expect(conversationId == "convo-1")
            #expect(inboxId == "inbox-1")
        } else {
            Issue.record("Expected profileAvatar asset")
        }
    }

    @Test("Collects group images with valid URLs")
    func testCollectsGroupImages() async throws {
        let fixtures = try await makeTestFixtures()
        let groupImageURL = "https://example.com/group123.bin"

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try makeDBConversation(
                id: "convo-1",
                inboxId: "inbox-1",
                clientId: "client-1",
                kind: .group,
                imageURL: groupImageURL
            ).insert(db)
        }

        let collector = AssetRenewalURLCollector(databaseReader: fixtures.dbReader)
        let assets = try collector.collectRenewableAssets()

        #expect(assets.count == 1)
        if case let .groupImage(url, conversationId, _) = assets.first {
            #expect(url == groupImageURL)
            #expect(conversationId == "convo-1")
        } else {
            Issue.record("Expected groupImage asset")
        }
    }

    @Test("Filters out invalid URLs (emojis)")
    func testFiltersInvalidURLs() async throws {
        let fixtures = try await makeTestFixtures()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try makeDBConversation(
                id: "convo-1",
                inboxId: "inbox-1",
                clientId: "client-1",
                kind: .group,
                imageURL: "🎉"
            ).insert(db)
        }

        let collector = AssetRenewalURLCollector(databaseReader: fixtures.dbReader)
        let assets = try collector.collectRenewableAssets()

        #expect(assets.isEmpty)
    }

    @Test("Filters out non-HTTP URLs")
    func testFiltersNonHTTPURLs() async throws {
        let fixtures = try await makeTestFixtures()

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try makeDBConversation(
                id: "convo-1",
                inboxId: "inbox-1",
                clientId: "client-1",
                kind: .group,
                imageURL: "file:///local/path.png"
            ).insert(db)
        }

        let collector = AssetRenewalURLCollector(databaseReader: fixtures.dbReader)
        let assets = try collector.collectRenewableAssets()

        #expect(assets.isEmpty)
    }

    @Test("Deduplicates URLs")
    func testDeduplicatesURLs() async throws {
        let fixtures = try await makeTestFixtures()
        let sharedURL = "https://example.com/shared.bin"

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeDBConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try makeDBConversation(id: "convo-2", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                name: "User 1",
                avatar: sharedURL
            ).insert(db)
            try DBMemberProfile(
                conversationId: "convo-2",
                inboxId: "inbox-1",
                name: "User 2",
                avatar: sharedURL
            ).insert(db)
        }

        let collector = AssetRenewalURLCollector(databaseReader: fixtures.dbReader)
        let assets = try collector.collectRenewableAssets()

        #expect(assets.count == 1)
    }

    @Test("Returns empty when no inboxes")
    func testReturnsEmptyWhenNoInboxes() async throws {
        let fixtures = try await makeTestFixtures()

        let collector = AssetRenewalURLCollector(databaseReader: fixtures.dbReader)
        let assets = try collector.collectRenewableAssets()

        #expect(assets.isEmpty)
    }

    @Test("Only collects own profile avatars")
    func testOnlyCollectsOwnAvatars() async throws {
        let fixtures = try await makeTestFixtures()
        let myAvatarURL = "https://example.com/my-avatar.bin"
        let otherAvatarURL = "https://example.com/other-avatar.bin"

        try await fixtures.dbWriter.write { db in
            try DBInbox(inboxId: "my-inbox", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "my-inbox").insert(db)
            try DBMember(inboxId: "other-inbox").insert(db)
            try makeDBConversation(id: "convo-1", inboxId: "my-inbox", clientId: "client-1").insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "my-inbox",
                name: "Me",
                avatar: myAvatarURL
            ).insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "other-inbox",
                name: "Other",
                avatar: otherAvatarURL
            ).insert(db)
        }

        let collector = AssetRenewalURLCollector(databaseReader: fixtures.dbReader)
        let assets = try collector.collectRenewableAssets()

        #expect(assets.count == 1)
        if case let .profileAvatar(url, _, inboxId, _) = assets.first {
            #expect(url == myAvatarURL)
            #expect(inboxId == "my-inbox")
        } else {
            Issue.record("Expected profileAvatar asset")
        }
    }

    @Test("Extracts key from URL path")
    func testKeyExtraction() {
        let asset = RenewableAsset.profileAvatar(
            url: "https://example.com/abc123.bin",
            conversationId: "convo-1",
            inboxId: "inbox-1",
            lastRenewed: nil
        )

        #expect(asset.key == "abc123.bin")
    }

    @Test("Key is nil for URL without path")
    func testKeyNilForInvalidURL() {
        // URL with only "/" path (count == 1) should return nil
        let asset = RenewableAsset.groupImage(url: "https://example.com", conversationId: "convo-1", lastRenewed: nil)
        #expect(asset.key == nil)
    }
}

private extension AssetRenewalURLCollectorTests {
    struct TestFixtures {
        let dbWriter: any DatabaseWriter
        let dbReader: any DatabaseReader
    }

    func makeTestFixtures() async throws -> TestFixtures {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        return TestFixtures(dbWriter: dbManager.dbWriter, dbReader: dbManager.dbReader)
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
            imageLastRenewed: imageLastRenewed,
            isUnused: false
        )
    }
}
