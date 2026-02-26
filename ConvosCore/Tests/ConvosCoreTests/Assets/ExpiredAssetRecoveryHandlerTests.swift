@testable import ConvosCore
import Combine
import Foundation
import GRDB
import Testing

#if os(macOS)
import AppKit

@Suite("ExpiredAssetRecoveryHandler Tests", .serialized)
struct ExpiredAssetRecoveryHandlerTests {
    @Test("Defers recovery when cache exists but writers are unavailable")
    func testDefersRecoveryWhenWritersUnavailable() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let deferredFlag = DeferredFlag()
        let avatarURL = "https://example.com/avatar.bin"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                name: "Test",
                avatar: avatarURL,
                avatarLastRenewed: nil
            ).insert(db)
        }

        let cache = TestImageCache(imagesByIdentifier: [avatarURL: NSImage(size: .init(width: 1, height: 1))])
        let handler = ExpiredAssetRecoveryHandler(
            databaseWriter: dbManager.dbWriter,
            imageCache: cache,
            onRecoveryDeferred: { _ in
                await deferredFlag.markDeferred()
            }
        )

        let asset = RenewableAsset.profileAvatar(
            url: avatarURL,
            conversationId: "convo-1",
            inboxId: "inbox-1",
            lastRenewed: nil
        )

        let result = await handler.handleExpiredAsset(asset)

        #expect(result == .deferred)
        #expect(await deferredFlag.wasDeferred == true)

        let profile = try await dbManager.dbWriter.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: "convo-1", inboxId: "inbox-1")
        }
        #expect(profile?.avatar == avatarURL)
    }

    @Test("Recovers profile avatar when cache and profile writer are available")
    func testRecoversProfileAvatarWhenWriterAvailable() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let avatarURL = "https://example.com/avatar-recover.bin"
        let profileWriter = TestMyProfileWriter()

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1").insert(db)
            try DBMemberProfile(
                conversationId: "convo-1",
                inboxId: "inbox-1",
                name: "Test",
                avatar: avatarURL,
                avatarLastRenewed: nil
            ).insert(db)
        }

        let cache = TestImageCache(imagesByIdentifier: [avatarURL: NSImage(size: .init(width: 2, height: 2))])
        let handler = ExpiredAssetRecoveryHandler(
            databaseWriter: dbManager.dbWriter,
            imageCache: cache,
            myProfileWriter: profileWriter
        )

        let asset = RenewableAsset.profileAvatar(
            url: avatarURL,
            conversationId: "convo-1",
            inboxId: "inbox-1",
            lastRenewed: nil
        )

        let result = await handler.handleExpiredAsset(asset)

        #expect(result == .recovered)
        #expect(await profileWriter.updatedConversationIds == ["convo-1"])
    }

    @Test("Clears group image when writer exists but target conversation cannot be loaded")
    func testClearsGroupImageWhenConversationMissing() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let imageURL = "https://example.com/group-image.bin"
        let conversationWriter = TestConversationMetadataWriter()

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1")
                .with(imageURLString: imageURL, imageSalt: Data([1]), imageNonce: Data([2]), imageEncryptionKey: Data([3]))
                .insert(db)
        }

        let cache = TestImageCache(imagesByIdentifier: [imageURL: NSImage(size: .init(width: 3, height: 3))])
        let handler = ExpiredAssetRecoveryHandler(
            databaseWriter: dbManager.dbWriter,
            imageCache: cache,
            conversationMetadataWriter: conversationWriter
        )

        let asset = RenewableAsset.groupImage(
            url: imageURL,
            conversationId: "missing-conversation",
            lastRenewed: nil
        )

        let result = await handler.handleExpiredAsset(asset)

        #expect(result == .cleared)
        #expect(await conversationWriter.updateImageCount == 0)

        let conversation = try await dbManager.dbWriter.read { db in
            try DBConversation.fetchOne(db, key: "convo-1")
        }
        #expect(conversation?.imageURLString == nil)
        #expect(conversation?.imageSalt == nil)
        #expect(conversation?.imageNonce == nil)
        #expect(conversation?.imageEncryptionKey == nil)
    }

    @Test("Defers group image recovery when cache exists but conversation metadata writer is unavailable")
    func testDefersGroupImageRecoveryWhenWriterUnavailable() async throws {
        let dbManager = MockDatabaseManager.makeTestDatabase()
        let deferredFlag = DeferredFlag()
        let imageURL = "https://example.com/group-deferred.bin"

        try await dbManager.dbWriter.write { db in
            try DBInbox(inboxId: "inbox-1", clientId: "client-1", createdAt: Date()).insert(db)
            try DBMember(inboxId: "inbox-1").insert(db)
            try makeConversation(id: "convo-1", inboxId: "inbox-1", clientId: "client-1")
                .with(imageURLString: imageURL, imageSalt: Data([1]), imageNonce: Data([2]), imageEncryptionKey: Data([3]))
                .insert(db)
        }

        let cache = TestImageCache(imagesByIdentifier: [imageURL: NSImage(size: .init(width: 4, height: 4))])
        let handler = ExpiredAssetRecoveryHandler(
            databaseWriter: dbManager.dbWriter,
            imageCache: cache,
            onRecoveryDeferred: { _ in
                await deferredFlag.markDeferred()
            }
        )

        let asset = RenewableAsset.groupImage(
            url: imageURL,
            conversationId: "convo-1",
            lastRenewed: nil
        )

        let result = await handler.handleExpiredAsset(asset)

        #expect(result == .deferred)
        #expect(await deferredFlag.wasDeferred == true)

        let conversation = try await dbManager.dbWriter.read { db in
            try DBConversation.fetchOne(db, key: "convo-1")
        }
        #expect(conversation?.imageURLString == imageURL)
    }
}

private actor DeferredFlag {
    private(set) var wasDeferred: Bool = false

    func markDeferred() {
        wasDeferred = true
    }
}

private actor TestMyProfileWriter: MyProfileWriterProtocol {
    private(set) var updatedConversationIds: [String] = []

    func update(displayName: String, conversationId: String) async throws {}

    func update(avatar: ImageType?, conversationId: String) async throws {
        guard avatar != nil else { return }
        updatedConversationIds.append(conversationId)
    }
}

private actor TestConversationMetadataWriter: ConversationMetadataWriterProtocol {
    private(set) var updateImageCount: Int = 0

    func updateName(_ name: String, for conversationId: String) async throws {}
    func updateDescription(_ description: String, for conversationId: String) async throws {}
    func updateImageUrl(_ imageURL: String, for conversationId: String) async throws {}
    func addMembers(_ memberInboxIds: [String], to conversationId: String) async throws {}
    func removeMembers(_ memberInboxIds: [String], from conversationId: String) async throws {}
    func promoteToAdmin(_ memberInboxId: String, in conversationId: String) async throws {}
    func demoteFromAdmin(_ memberInboxId: String, in conversationId: String) async throws {}
    func promoteToSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws {}
    func demoteFromSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws {}

    func updateImage(_ image: ImageType, for conversation: Conversation) async throws {
        updateImageCount += 1
    }

    func updateExpiresAt(_ expiresAt: Date, for conversationId: String) async throws {}
    func updateIncludeInfoInPublicPreview(_ enabled: Bool, for conversationId: String) async throws {}
    func lockConversation(for conversationId: String) async throws {}
    func unlockConversation(for conversationId: String) async throws {}
}

private final class TestImageCache: ImageCacheProtocol, @unchecked Sendable {
    private let imagesByIdentifier: [String: NSImage]

    init(imagesByIdentifier: [String: NSImage]) {
        self.imagesByIdentifier = imagesByIdentifier
    }

    func loadImage(for object: any ImageCacheable) async -> NSImage? { nil }
    func image(for object: any ImageCacheable) -> NSImage? { nil }
    func imageAsync(for object: any ImageCacheable) async -> NSImage? { nil }
    func removeImage(for object: any ImageCacheable) {}

    func prepareForUpload(_ image: NSImage, for object: any ImageCacheable) -> Data? { nil }
    func cacheAfterUpload(_ image: NSImage, for object: any ImageCacheable, url: String) {}
    func cacheAfterUpload(_ image: NSImage, for identifier: String, url: String) {}
    func cacheAfterUpload(_ imageData: Data, for identifier: String, url: String) {}

    func image(for identifier: String, imageFormat: ImageFormat) -> NSImage? {
        imagesByIdentifier[identifier]
    }

    func imageAsync(for identifier: String, imageFormat: ImageFormat) async -> NSImage? {
        imagesByIdentifier[identifier]
    }

    func cacheImage(_ image: NSImage, for identifier: String, imageFormat: ImageFormat) {}
    func removeImage(for identifier: String) {}

    func cacheData(_ data: Data, for identifier: String, storageTier: ImageStorageTier) {}
    func cacheImage(_ image: NSImage, for identifier: String, storageTier: ImageStorageTier) {}
    func removePersistentImages(for identifiers: [String]) {}
    func removeAllPersistentImages() {}

    func hasURLChanged(_ url: String?, for identifier: String) async -> Bool { false }

    var cacheUpdates: AnyPublisher<String, Never> {
        Empty().eraseToAnyPublisher()
    }
}

private func makeConversation(
    id: String,
    inboxId: String,
    clientId: String
) -> DBConversation {
    DBConversation(
        id: id,
        inboxId: inboxId,
        clientId: clientId,
        clientConversationId: id,
        inviteTag: "invite-\(id)",
        creatorId: inboxId,
        kind: .group,
        consent: .allowed,
        createdAt: Date(),
        name: nil,
        description: nil,
        imageURLString: nil,
        publicImageURLString: nil,
        includeInfoInPublicPreview: false,
        expiresAt: nil,
        debugInfo: .empty,
        isLocked: false,
        imageSalt: nil,
        imageNonce: nil,
        imageEncryptionKey: nil,
        imageLastRenewed: nil,
        isUnused: false
    )
}
#endif
