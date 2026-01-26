#if canImport(UIKit)
@testable import ConvosCore
import Combine
import ConvosCoreiOS
import Foundation
import Testing
import UIKit

@Suite("EncryptedImageSyncTests", .serialized)
struct EncryptedImageSyncTests {
    let groupKey: Data = Data(repeating: 0x01, count: 32)
    let salt: Data = Data(repeating: 0x02, count: 32)
    let nonce: Data = Data(repeating: 0x03, count: 12)

    init() {
        ImageCompression.resetForTesting()
        ImageCompression.configure(IOSImageCompression())
    }

    @Test("Device B receives Alice's profile photo when joining group")
    func testDeviceBReceivesAliceProfileOnJoin() async throws {
        let testCache = ImageCache()
        let originalShared = ImageCacheContainer.shared
        ImageCacheContainer.shared = testCache
        defer { ImageCacheContainer.shared = originalShared }

        let mockLoader = MockEncryptedImageLoader()
        let prefetcher = EncryptedImagePrefetcher(loader: mockLoader)

        let uniqueId = UUID().uuidString
        let aliceAvatarURL = URL(string: "https://cdn.example.com/avatars/alice-\(uniqueId).enc")!
        let aliceImageData = createSyncTestImageData()
        mockLoader.stub(url: aliceAvatarURL, with: aliceImageData)

        let aliceProfile = DBMemberProfile(
            conversationId: "group-\(uniqueId)",
            inboxId: "alice-\(uniqueId)",
            name: "Alice",
            avatar: aliceAvatarURL.absoluteString,
            avatarSalt: salt,
            avatarNonce: nonce
        )

        await prefetcher.prefetchProfileImages(profiles: [aliceProfile], groupKey: groupKey)

        #expect(mockLoader.loadCalls.count == 1)
        #expect(mockLoader.loadCalls[0].url == aliceAvatarURL)
        #expect(mockLoader.loadCalls[0].salt == salt)
        #expect(mockLoader.loadCalls[0].nonce == nonce)
        #expect(mockLoader.loadCalls[0].groupKey == groupKey)
    }

    @Test("Device B receives group photo when joining")
    func testDeviceBReceivesGroupPhotoOnJoin() async throws {
        let testCache = ImageCache()
        let originalShared = ImageCacheContainer.shared
        ImageCacheContainer.shared = testCache
        defer { ImageCacheContainer.shared = originalShared }

        let mockLoader = MockEncryptedImageLoader()
        let prefetcher = EncryptedImagePrefetcher(loader: mockLoader)

        let uniqueId = UUID().uuidString
        let bobAvatarURL = URL(string: "https://cdn.example.com/avatars/bob-\(uniqueId).enc")!
        let charlieAvatarURL = URL(string: "https://cdn.example.com/avatars/charlie-\(uniqueId).enc")!
        let bobImageData = createSyncTestImageData(color: .blue)
        let charlieImageData = createSyncTestImageData(color: .green)

        mockLoader.stub(url: bobAvatarURL, with: bobImageData)
        mockLoader.stub(url: charlieAvatarURL, with: charlieImageData)

        let profiles = [
            DBMemberProfile(
                conversationId: "group-\(uniqueId)",
                inboxId: "bob-\(uniqueId)",
                name: "Bob",
                avatar: bobAvatarURL.absoluteString,
                avatarSalt: salt,
                avatarNonce: nonce
            ),
            DBMemberProfile(
                conversationId: "group-\(uniqueId)",
                inboxId: "charlie-\(uniqueId)",
                name: "Charlie",
                avatar: charlieAvatarURL.absoluteString,
                avatarSalt: salt,
                avatarNonce: nonce
            )
        ]

        await prefetcher.prefetchProfileImages(profiles: profiles, groupKey: groupKey)

        #expect(mockLoader.loadCalls.count == 2)

        let fetchedURLs = Set(mockLoader.loadCalls.map { $0.url })
        #expect(fetchedURLs.contains(bobAvatarURL))
        #expect(fetchedURLs.contains(charlieAvatarURL))
    }

    @Test("Device A sees Device B's profile change via URL change event")
    func testDeviceASeesDeviceBProfileChange() async throws {
        let cache = ImageCache()
        var receivedChanges: [ImageURLChange] = []
        let cancellable = cache.urlChanges
            .filter { $0.identifier == "bob-inbox-id" }
            .sink { change in
                receivedChanges.append(change)
            }
        defer { cancellable.cancel() }

        let oldAvatarURL = "https://cdn.example.com/avatars/bob-v1.enc"
        let newAvatarURL = "https://cdn.example.com/avatars/bob-v2.enc"

        cache.cacheAfterUpload(createSyncTestImage(color: .blue), for: "bob-inbox-id", url: oldAvatarURL)
        try await Task.sleep(nanoseconds: 100_000_000)

        cache.cacheAfterUpload(createSyncTestImage(color: .red), for: "bob-inbox-id", url: newAvatarURL)
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(receivedChanges.count == 2)
        #expect(receivedChanges[0].newURL?.absoluteString == oldAvatarURL)
        #expect(receivedChanges[1].oldURL?.absoluteString == oldAvatarURL)
        #expect(receivedChanges[1].newURL?.absoluteString == newAvatarURL)
    }

    @Test("Already cached profile is not re-fetched from network")
    func testAlreadyCachedProfileNotRefetched() async throws {
        let testCache = ImageCache()
        let originalShared = ImageCacheContainer.shared
        ImageCacheContainer.shared = testCache
        defer { ImageCacheContainer.shared = originalShared }

        let aliceInboxId = "alice-cached-\(UUID().uuidString)"
        let aliceAvatarURL = URL(string: "https://cdn.example.com/avatars/alice-cached.enc")!

        testCache.cacheImage(createSyncTestImage(color: .red), for: aliceInboxId)

        try await Task.sleep(nanoseconds: 100_000_000)

        let cachedImage = await testCache.imageAsync(for: aliceInboxId)
        #expect(cachedImage != nil)

        let mockLoader = MockEncryptedImageLoader()
        mockLoader.stub(url: aliceAvatarURL, with: createSyncTestImageData())
        let prefetcher = EncryptedImagePrefetcher(loader: mockLoader)

        let aliceProfile = DBMemberProfile(
            conversationId: "group-789",
            inboxId: aliceInboxId,
            name: "Alice",
            avatar: aliceAvatarURL.absoluteString,
            avatarSalt: salt,
            avatarNonce: nonce
        )

        await prefetcher.prefetchProfileImages(profiles: [aliceProfile], groupKey: groupKey)

        #expect(mockLoader.loadCalls.isEmpty, "Should not fetch already-cached profile")
    }

    @Test("Concurrent prefetch requests for same profile are deduplicated within a single call")
    func testConcurrentPrefetchesAreDeduplicated() async throws {
        let testCache = ImageCache()
        let originalShared = ImageCacheContainer.shared
        ImageCacheContainer.shared = testCache
        defer { ImageCacheContainer.shared = originalShared }

        let mockLoader = MockEncryptedImageLoader()
        let prefetcher = EncryptedImagePrefetcher(loader: mockLoader)

        let uniqueInboxId = "concurrent-test-\(UUID().uuidString)"
        let avatarURL = URL(string: "https://cdn.example.com/avatars/concurrent.enc")!
        mockLoader.stub(url: avatarURL, with: createSyncTestImageData())

        let profile = DBMemberProfile(
            conversationId: "group-concurrent",
            inboxId: uniqueInboxId,
            name: "Concurrent User",
            avatar: avatarURL.absoluteString,
            avatarSalt: salt,
            avatarNonce: nonce
        )

        let duplicateProfiles = Array(repeating: profile, count: 5)

        await prefetcher.prefetchProfileImages(profiles: duplicateProfiles, groupKey: groupKey)

        #expect(mockLoader.loadCalls.count == 1, "Should only fetch once for duplicate profiles in same call")
    }
}

private func createSyncTestImage(width: Int = 100, height: Int = 100, color: UIColor = .red) -> UIImage {
    let size = CGSize(width: width, height: height)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
        color.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
}

private func createSyncTestImageData(color: UIColor = .red) -> Data {
    let image = createSyncTestImage(color: color)
    return image.jpegData(compressionQuality: 0.8) ?? Data()
}
#endif
