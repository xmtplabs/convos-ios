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

        await handler.handleExpiredAsset(asset)

        #expect(await deferredFlag.wasDeferred == true)

        let profile = try await dbManager.dbWriter.read { db in
            try DBMemberProfile.fetchOne(db, conversationId: "convo-1", inboxId: "inbox-1")
        }
        #expect(profile?.avatar == avatarURL)
    }
}

private actor DeferredFlag {
    private(set) var wasDeferred: Bool = false

    func markDeferred() {
        wasDeferred = true
    }
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
