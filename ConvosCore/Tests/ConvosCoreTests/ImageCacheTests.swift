#if canImport(UIKit)
@testable import ConvosCore
import Combine
import ConvosCoreiOS
import Foundation
import Testing
import UIKit

// MARK: - Test Configuration

private func configureTestEnvironment() {
    ImageCompression.resetForTesting()
    ImageCompression.configure(IOSImageCompression())
}

// MARK: - Test Helpers

/// A plain (unencrypted) ImageCacheable for tests.
struct TestImageCacheable: ImageCacheable, Sendable {
    let imageCacheIdentifier: String
    let imageCacheURL: URL?

    init(identifier: String, url: URL? = nil) {
        self.imageCacheIdentifier = identifier
        self.imageCacheURL = url
    }

    init(identifier: String, urlString: String?) {
        self.imageCacheIdentifier = identifier
        self.imageCacheURL = urlString.flatMap { URL(string: $0) }
    }
}

func createTestImage(width: Int = 100, height: Int = 100, color: UIColor = .red) -> UIImage {
    let size = CGSize(width: width, height: height)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
        color.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
}

private func uniqueURL() -> URL {
    URL(string: "https://example.com/\(UUID().uuidString).jpg")!
}

private let asyncSettleNanos: UInt64 = 150_000_000

// MARK: - ImageCache Tests (URL-keyed byte cache + continuity hint)

@Suite("ImageCache Tests", .serialized)
struct ImageCacheTests {
    init() {
        configureTestEnvironment()
    }

    // MARK: Byte cache keyed by URL

    @Test("cacheAfterUpload(for:url:) then image(for:) returns the image")
    func cacheThenRead() async throws {
        let cache = ImageCache()
        let url = uniqueURL()
        let object = TestImageCacheable(identifier: "id-\(UUID().uuidString)", url: url)

        cache.cacheAfterUpload(createTestImage(), for: object, url: url.absoluteString)
        try await Task.sleep(nanoseconds: asyncSettleNanos)

        #expect(cache.image(for: object) != nil)
    }

    @Test("imageAsync round-trips through disk on a fresh instance")
    func diskRoundTrip() async throws {
        let url = uniqueURL()
        let object = TestImageCacheable(identifier: "id-\(UUID().uuidString)", url: url)

        let writer = ImageCache()
        writer.cacheAfterUpload(createTestImage(), for: object, url: url.absoluteString)
        try await Task.sleep(nanoseconds: asyncSettleNanos)

        // A second instance shares the disk directory but not memory.
        let reader = ImageCache()
        #expect(await reader.imageAsync(for: object) != nil)
    }

    // MARK: No-clobber regression (the whole saga)

    @Test("same identity, two URLs are independent entries and never clobber")
    func sameIdentityTwoURLsNoClobber() async throws {
        let cache = ImageCache()
        let identifier = "inbox-\(UUID().uuidString)"
        let urlA = uniqueURL()
        let urlB = uniqueURL()
        let objectA = TestImageCacheable(identifier: identifier, url: urlA)
        let objectB = TestImageCacheable(identifier: identifier, url: urlB)

        cache.cacheAfterUpload(createTestImage(color: .red), for: objectA, url: urlA.absoluteString)
        cache.cacheAfterUpload(createTestImage(color: .blue), for: objectB, url: urlB.absoluteString)
        try await Task.sleep(nanoseconds: asyncSettleNanos)

        // Both URLs resolve to their own bytes; neither overwrote the other.
        let a = cache.image(for: objectA)
        let b = cache.image(for: objectB)
        #expect(a != nil)
        #expect(b != nil)

        // Loading A again must not change B's entry (no shared slot to clobber).
        _ = await cache.loadImage(for: objectA)
        try await Task.sleep(nanoseconds: asyncSettleNanos)
        #expect(await cache.imageAsync(for: objectB) != nil)
    }

    @Test("same URL across two objects is deduped to one entry")
    func sameURLDeduped() async throws {
        let cache = ImageCache()
        let url = uniqueURL()
        let object1 = TestImageCacheable(identifier: "id1-\(UUID().uuidString)", url: url)
        let object2 = TestImageCacheable(identifier: "id2-\(UUID().uuidString)", url: url)

        cache.cacheAfterUpload(createTestImage(), for: object1, url: url.absoluteString)
        try await Task.sleep(nanoseconds: asyncSettleNanos)

        // object2 shares the URL, so it resolves from the same byte entry.
        #expect(cache.image(for: object2) != nil)
    }

    // MARK: Continuity hint (identity-keyed, read-only)

    @Test("continuity hint bridges an object whose current URL is not cached")
    func continuityHintBridges() async throws {
        let cache = ImageCache()
        let identifier = "inbox-\(UUID().uuidString)"
        let cachedURL = uniqueURL()
        let cachedObject = TestImageCacheable(identifier: identifier, url: cachedURL)

        // Cache an image for the identity (writes hint with persist: true).
        cache.cacheAfterUpload(createTestImage(), for: cachedObject, url: cachedURL.absoluteString)
        try await Task.sleep(nanoseconds: asyncSettleNanos)

        // A new object for the same identity with a different, uncached URL:
        // the byte cache misses, but the continuity hint bridges it.
        let freshURL = uniqueURL()
        let freshObject = TestImageCacheable(identifier: identifier, url: freshURL)

        #expect(cache.image(for: freshObject) != nil)               // sync memory hint
        #expect(await cache.continuityImage(for: freshObject) != nil) // memory/disk hint
    }

    @Test("continuity hint survives a fresh instance via disk")
    func continuityHintDiskBacked() async throws {
        let identifier = "inbox-\(UUID().uuidString)"
        let url = uniqueURL()
        let object = TestImageCacheable(identifier: identifier, url: url)

        let writer = ImageCache()
        writer.cacheAfterUpload(createTestImage(), for: object, url: url.absoluteString)
        try await Task.sleep(nanoseconds: asyncSettleNanos)

        // Fresh instance: a different uncached URL still bridges from the disk hint.
        let reader = ImageCache()
        let freshObject = TestImageCacheable(identifier: identifier, url: uniqueURL())
        #expect(await reader.continuityImage(for: freshObject) != nil)
    }

    @Test("nil URL shows a staged pre-upload image, else nothing; never a stale continuity hint")
    func nilURLStagedVersusCleared() async throws {
        let cache = ImageCache()

        // Staged pre-upload (nil URL): the explicitly staged image shows.
        let stagedId = "inbox-\(UUID().uuidString)"
        let stagedObject = TestImageCacheable(identifier: stagedId, url: nil)
        _ = cache.prepareForUpload(createTestImage(), for: stagedObject)
        try await Task.sleep(nanoseconds: asyncSettleNanos)
        #expect(cache.image(for: stagedObject) != nil)
        #expect(await cache.continuityImage(for: stagedObject) != nil)

        // Cleared/never-set (nil URL) with a continuity hint from a prior real
        // URL must show NOTHING - the hint is not consulted on a nil URL.
        let clearedId = "inbox-\(UUID().uuidString)"
        let url = uniqueURL()
        let withAvatar = TestImageCacheable(identifier: clearedId, url: url)
        cache.cacheAfterUpload(createTestImage(), for: withAvatar, url: url.absoluteString)
        try await Task.sleep(nanoseconds: asyncSettleNanos)
        let clearedObject = TestImageCacheable(identifier: clearedId, url: nil)
        #expect(cache.image(for: clearedObject) == nil)
        #expect(await cache.continuityImage(for: clearedObject) == nil)
    }

    @Test("removeImage clears the byte entry and the continuity hint")
    func removeClearsByteAndHint() async throws {
        let cache = ImageCache()
        let identifier = "inbox-\(UUID().uuidString)"
        let url = uniqueURL()
        let object = TestImageCacheable(identifier: identifier, url: url)

        cache.cacheAfterUpload(createTestImage(), for: object, url: url.absoluteString)
        try await Task.sleep(nanoseconds: asyncSettleNanos)
        #expect(cache.image(for: object) != nil)

        cache.removeImage(for: object)
        try await Task.sleep(nanoseconds: asyncSettleNanos)

        #expect(cache.image(for: object) == nil)
        #expect(await cache.continuityImage(for: object) == nil)
    }

    // MARK: Notifications

    @Test("cacheUpdates emits the URL key on cacheAfterUpload")
    func cacheUpdatesEmitsURLKey() async throws {
        let cache = ImageCache()
        let url = uniqueURL()
        let object = TestImageCacheable(identifier: "id-\(UUID().uuidString)", url: url)

        var received: [String] = []
        let cancellable = cache.cacheUpdates.sink { received.append($0) }
        defer { cancellable.cancel() }

        cache.cacheAfterUpload(createTestImage(), for: object, url: url.absoluteString)
        try await Task.sleep(nanoseconds: asyncSettleNanos)

        #expect(received.contains(url.absoluteString))
    }

    @Test("cacheUpdates emits the identity key on prepareForUpload")
    func cacheUpdatesEmitsIdentityOnStage() async throws {
        let cache = ImageCache()
        let identifier = "inbox-\(UUID().uuidString)"
        let object = TestImageCacheable(identifier: identifier, url: nil)

        var received: [String] = []
        let cancellable = cache.cacheUpdates.sink { received.append($0) }
        defer { cancellable.cancel() }

        _ = cache.prepareForUpload(createTestImage(), for: object)
        try await Task.sleep(nanoseconds: asyncSettleNanos)

        #expect(received.contains(identifier))
    }

    // MARK: Identifier-keyed path (QR codes / generated images) is unchanged

    @Test("identifier-keyed cache/read/remove still works")
    func identifierPath() async throws {
        let cache = ImageCache()
        let identifier = "qr-\(UUID().uuidString)"

        cache.cacheImage(createTestImage(), for: identifier, imageFormat: .png)
        try await Task.sleep(nanoseconds: asyncSettleNanos)
        #expect(cache.image(for: identifier, imageFormat: .png) != nil)

        cache.removeImage(for: identifier)
        try await Task.sleep(nanoseconds: asyncSettleNanos)
        #expect(cache.image(for: identifier, imageFormat: .png) == nil)
    }

    // MARK: Persistent tier (chat photo attachments) is unchanged

    @Test("persistent tier caches and reads by identifier")
    func persistentTier() async throws {
        let identifier = "attachment-\(UUID().uuidString)"
        guard let data = ImageCompression.resizeAndCompressToJPEG(createTestImage(), compressionQuality: 0.8) else {
            Issue.record("Failed to compress test image")
            return
        }

        let writer = ImageCache()
        writer.cacheData(data, for: identifier, storageTier: .persistent)
        try await Task.sleep(nanoseconds: asyncSettleNanos)

        let reader = ImageCache()
        #expect(await reader.imageAsync(for: identifier) != nil)

        reader.removePersistentImages(for: [identifier])
    }

    // MARK: URL probe (group-image prefetch dedup)

    @Test("imageAsync(forURL:) hits the bytes cacheAfterUpload wrote, enabling dedup")
    func urlProbeFindsCachedBytes() async throws {
        let cache = ImageCache()
        let identifier = "conversation-\(UUID().uuidString)"
        let url = uniqueURL()

        guard let data = ImageCompression.resizeAndCompressToJPEG(createTestImage(), compressionQuality: 0.8) else {
            Issue.record("Failed to compress test image")
            return
        }

        // The encrypted-group-image prefetch writes by identifier + URL, then a
        // later run dedups by probing the URL. A miss here means re-download.
        cache.cacheAfterUpload(data, for: identifier, url: url.absoluteString)
        try await Task.sleep(nanoseconds: asyncSettleNanos)

        #expect(await cache.imageAsync(forURL: url.absoluteString) != nil)
        #expect(await cache.imageAsync(forURL: uniqueURL().absoluteString) == nil)
    }

    // MARK: Delete-all reset clears the continuity hint

    @Test("removeAllPersistentImages wipes the byte cache and continuity hint, in memory and on disk")
    func removeAllClearsContinuityHint() async throws {
        let identifier = "inbox-\(UUID().uuidString)"
        let url = uniqueURL()
        let object = TestImageCacheable(identifier: identifier, url: url)

        let cache = ImageCache()
        // Writes the URL-keyed byte cache and the continuity hint (persist: true).
        cache.cacheAfterUpload(createTestImage(), for: object, url: url.absoluteString)
        try await Task.sleep(nanoseconds: asyncSettleNanos)

        // A fresh object for the same identity with an uncached URL bridges via
        // the hint before the wipe.
        let freshObject = TestImageCacheable(identifier: identifier, url: uniqueURL())
        #expect(await cache.continuityImage(for: freshObject) != nil)

        cache.removeAllPersistentImages()
        try await Task.sleep(nanoseconds: asyncSettleNanos)

        // In-memory hint is gone, and a new instance finds nothing on disk -
        // neither the continuity hint nor the URL-keyed byte cache survive.
        #expect(await cache.continuityImage(for: freshObject) == nil)
        let reader = ImageCache()
        #expect(await reader.continuityImage(for: freshObject) == nil)
        #expect(await reader.imageAsync(forURL: url.absoluteString) == nil)
    }

    // MARK: Staged image is cleared once the upload is cached

    @Test("cacheAfterUpload clears the staged image so a later nil URL shows nothing")
    func cacheAfterUploadClearsStaged() async throws {
        let cache = ImageCache()
        let identifier = "inbox-\(UUID().uuidString)"

        // Stage a pre-upload image (no URL yet): a nil-URL object shows it.
        let staging = TestImageCacheable(identifier: identifier, url: nil)
        _ = cache.prepareForUpload(createTestImage(), for: staging)
        try await Task.sleep(nanoseconds: asyncSettleNanos)
        #expect(cache.image(for: staging) != nil)

        // Upload completes under a real URL; the staged image is now superseded.
        let url = uniqueURL()
        let uploaded = TestImageCacheable(identifier: identifier, url: url)
        cache.cacheAfterUpload(createTestImage(), for: uploaded, url: url.absoluteString)
        try await Task.sleep(nanoseconds: asyncSettleNanos)

        // A subsequent nil-URL object for the same identity must fall through to
        // the placeholder (nil), not the stale staged upload.
        #expect(cache.image(for: staging) == nil)
    }
}
#endif
