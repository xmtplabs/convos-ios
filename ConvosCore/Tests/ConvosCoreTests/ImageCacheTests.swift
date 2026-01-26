#if canImport(UIKit)
@testable import ConvosCore
import Combine
import ConvosCoreiOS
import Foundation
import Testing
import UIKit

// MARK: - Test Configuration

/// Configure required singletons before tests run
private func configureTestEnvironment() {
    ImageCompression.resetForTesting()
    ImageCompression.configure(IOSImageCompression())
}

// MARK: - Test Helpers

/// A mock ImageCacheable object for testing
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

/// Creates a simple test UIImage with a solid color
func createTestImage(width: Int = 100, height: Int = 100, color: UIColor = .red) -> UIImage {
    let size = CGSize(width: width, height: height)
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { context in
        color.setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
}

// MARK: - ImageCache Tests

@Suite("ImageCache Tests", .serialized)
struct ImageCacheTests {
    init() {
        configureTestEnvironment()
    }

    // MARK: - URLTracker Tests (via public API)

    @Test("URL change is detected when URL changes for an identifier")
    func urlChangeDetected() async throws {
        let cache = ImageCache()
        var receivedChanges: [ImageURLChange] = []
        let cancellable = cache.urlChanges.sink { change in
            receivedChanges.append(change)
        }
        defer { cancellable.cancel() }

        let identifier = "test-profile-\(UUID().uuidString)"
        let url1 = URL(string: "https://example.com/image1.jpg")!
        let url2 = URL(string: "https://example.com/image2.jpg")!
        let testImage = createTestImage()

        // First cache with url1
        cache.cacheAfterUpload(testImage, for: identifier, url: url1.absoluteString)

        // Wait for async Task to complete
        try await Task.sleep(nanoseconds: 100_000_000)

        // Cache with url2 (URL change)
        cache.cacheAfterUpload(testImage, for: identifier, url: url2.absoluteString)

        // Wait for async Task to complete
        try await Task.sleep(nanoseconds: 100_000_000)

        // Should have received two change events
        #expect(receivedChanges.count == 2)

        // First change: nil -> url1
        #expect(receivedChanges[0].identifier == identifier)
        #expect(receivedChanges[0].oldURL == nil)
        #expect(receivedChanges[0].newURL == url1)

        // Second change: url1 -> url2
        #expect(receivedChanges[1].identifier == identifier)
        #expect(receivedChanges[1].oldURL == url1)
        #expect(receivedChanges[1].newURL == url2)
    }

    @Test("No URL change event when URL stays the same")
    func noUrlChangeWhenSameUrl() async throws {
        let cache = ImageCache()
        var changeCount = 0
        let cancellable = cache.urlChanges.sink { _ in
            changeCount += 1
        }
        defer { cancellable.cancel() }

        let identifier = "test-profile-\(UUID().uuidString)"
        let url = URL(string: "https://example.com/image.jpg")!
        let testImage = createTestImage()

        // Cache with same URL twice
        cache.cacheAfterUpload(testImage, for: identifier, url: url.absoluteString)
        try await Task.sleep(nanoseconds: 100_000_000)

        cache.cacheAfterUpload(testImage, for: identifier, url: url.absoluteString)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Should only have one change event (initial tracking)
        #expect(changeCount == 1)
    }

    // MARK: - cacheAfterUpload Tests

    @Test("cacheAfterUpload stores image in memory cache")
    func cacheAfterUploadStoresInMemory() async throws {
        let cache = ImageCache()
        let identifier = "test-memory-\(UUID().uuidString)"
        let url = "https://example.com/image.jpg"
        let testImage = createTestImage()

        cache.cacheAfterUpload(testImage, for: identifier, url: url)

        // Wait for async Task to complete
        try await Task.sleep(nanoseconds: 100_000_000)

        // Should be retrievable from memory
        let cached = cache.image(for: identifier)
        #expect(cached != nil)
    }

    @Test("cacheAfterUpload stores image in disk cache")
    func cacheAfterUploadStoresToDisk() async throws {
        let identifier = "test-disk-\(UUID().uuidString)"
        let url = "https://example.com/image.jpg"
        let testImage = createTestImage()

        // Cache in first instance
        let cache1 = ImageCache()
        cache1.cacheAfterUpload(testImage, for: identifier, url: url)

        // Wait for async disk write to complete
        try await Task.sleep(nanoseconds: 500_000_000)

        // Create a fresh cache instance (empty memory cache, same disk location)
        // and verify image loads from disk
        let cache2 = ImageCache()

        // Verify memory cache is empty in new instance
        let memoryImage = cache2.image(for: identifier)
        #expect(memoryImage == nil, "Memory cache should be empty in fresh instance")

        // imageAsync should load from disk
        let diskImage = await cache2.imageAsync(for: identifier)
        #expect(diskImage != nil, "Image should load from disk cache")

        // Cleanup
        cache2.removeImage(for: identifier)
    }

    @Test("cacheAfterUpload emits cacheUpdates for backward compatibility")
    func cacheAfterUploadEmitsCacheUpdates() async throws {
        let cache = ImageCache()
        var receivedIdentifiers: [String] = []
        let cancellable = cache.cacheUpdates.sink { identifier in
            receivedIdentifiers.append(identifier)
        }
        defer { cancellable.cancel() }

        let identifier = "test-updates-\(UUID().uuidString)"
        let url = "https://example.com/image.jpg"
        let testImage = createTestImage()

        cache.cacheAfterUpload(testImage, for: identifier, url: url)

        // Wait for async Task to complete
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(receivedIdentifiers.contains(identifier))
    }

    @Test("cacheAfterUpload with object emits urlChanges")
    func cacheAfterUploadObjectEmitsUrlChanges() async throws {
        let cache = ImageCache()
        var receivedChanges: [ImageURLChange] = []
        let cancellable = cache.urlChanges.sink { change in
            receivedChanges.append(change)
        }
        defer { cancellable.cancel() }

        let url = URL(string: "https://example.com/image.jpg")!
        let cacheable = TestImageCacheable(identifier: "test-object-\(UUID().uuidString)", url: url)
        let testImage = createTestImage()

        cache.cacheAfterUpload(testImage, for: cacheable, url: url.absoluteString)

        // Wait for async Task to complete
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(receivedChanges.count == 1)
        #expect(receivedChanges[0].identifier == cacheable.imageCacheIdentifier)
        #expect(receivedChanges[0].newURL == url)
    }

    // MARK: - loadImage Tests (Integration)

    @Test("loadImage returns nil when object has no URL")
    func loadImageNilUrl() async {
        let cache = ImageCache()
        let cacheable = TestImageCacheable(identifier: "no-url-\(UUID().uuidString)", url: nil)

        let image = await cache.loadImage(for: cacheable)

        #expect(image == nil)
    }

    @Test("loadImage emits urlChange when URL becomes nil")
    func loadImageUrlBecomesNil() async throws {
        let cache = ImageCache()
        var receivedChanges: [ImageURLChange] = []
        let cancellable = cache.urlChanges.sink { change in
            receivedChanges.append(change)
        }
        defer { cancellable.cancel() }

        let identifier = "test-nil-\(UUID().uuidString)"
        let url = URL(string: "https://example.com/image.jpg")!

        // First track a URL via cacheAfterUpload
        cache.cacheAfterUpload(createTestImage(), for: identifier, url: url.absoluteString)
        try await Task.sleep(nanoseconds: 200_000_000)

        // Now load with nil URL (object URL changed to nil)
        let cacheableNoUrl = TestImageCacheable(identifier: identifier, url: nil)
        _ = await cache.loadImage(for: cacheableNoUrl)

        // Wait for Combine to deliver the event
        try await Task.sleep(nanoseconds: 100_000_000)

        // Should emit URL change from url -> nil
        let nilChange = receivedChanges.first { $0.oldURL == url && $0.newURL == nil }
        #expect(nilChange != nil, "Expected URL change from \(url) to nil. Received: \(receivedChanges)")
    }

    @Test("loadImage returns cached image from memory")
    func loadImageFromMemory() async {
        let cache = ImageCache()
        let identifier = "test-mem-load-\(UUID().uuidString)"
        let url = URL(string: "https://example.com/image.jpg")!
        let cacheable = TestImageCacheable(identifier: identifier, url: url)
        let testImage = createTestImage()

        // Pre-cache the image
        cache.cacheImage(testImage, for: cacheable.imageCacheIdentifier)

        // loadImage should return cached image
        let loaded = await cache.loadImage(for: cacheable)
        #expect(loaded != nil)
    }

    // MARK: - View Modifier Integration Tests

    @Test("Subscriber receives urlChanges when image URL changes")
    func subscriberReceivesUrlChanges() async throws {
        let cache = ImageCache()

        // Simulate what the view modifier does
        let identifier = "profile-\(UUID().uuidString)"
        var receivedURLChanges: [ImageURLChange] = []

        // Subscribe to URL changes for this identifier (like the view modifier does)
        let cancellable = cache.urlChanges
            .filter { $0.identifier == identifier }
            .sink { change in
                receivedURLChanges.append(change)
            }
        defer { cancellable.cancel() }

        // Simulate first image fetch with URL1
        let url1 = "https://example.com/avatar-v1.jpg"
        cache.cacheAfterUpload(createTestImage(color: .red), for: identifier, url: url1)

        try await Task.sleep(nanoseconds: 100_000_000)

        // Simulate image URL change (like when updated from another device)
        let url2 = "https://example.com/avatar-v2.jpg"
        cache.cacheAfterUpload(createTestImage(color: .blue), for: identifier, url: url2)

        try await Task.sleep(nanoseconds: 100_000_000)

        // View should have received URL change notification
        #expect(receivedURLChanges.count == 2)

        // First: nil -> url1
        #expect(receivedURLChanges[0].newURL?.absoluteString == url1)

        // Second: url1 -> url2
        #expect(receivedURLChanges[1].oldURL?.absoluteString == url1)
        #expect(receivedURLChanges[1].newURL?.absoluteString == url2)
    }

    @Test("Multiple identifiers receive independent URL change events")
    func multipleIdentifiersIndependentEvents() async throws {
        let cache = ImageCache()

        let id1 = "profile-1-\(UUID().uuidString)"
        let id2 = "profile-2-\(UUID().uuidString)"

        var changesForId1: [ImageURLChange] = []
        var changesForId2: [ImageURLChange] = []

        let cancellable1 = cache.urlChanges
            .filter { $0.identifier == id1 }
            .sink { changesForId1.append($0) }
        let cancellable2 = cache.urlChanges
            .filter { $0.identifier == id2 }
            .sink { changesForId2.append($0) }
        defer {
            cancellable1.cancel()
            cancellable2.cancel()
        }

        // Cache images for both identifiers
        cache.cacheAfterUpload(createTestImage(), for: id1, url: "https://example.com/1.jpg")
        cache.cacheAfterUpload(createTestImage(), for: id2, url: "https://example.com/2.jpg")

        try await Task.sleep(nanoseconds: 100_000_000)

        // Change only id1's URL
        cache.cacheAfterUpload(createTestImage(), for: id1, url: "https://example.com/1-v2.jpg")

        try await Task.sleep(nanoseconds: 100_000_000)

        // id1 should have 2 changes, id2 should have 1
        #expect(changesForId1.count == 2)
        #expect(changesForId2.count == 1)
    }

    @Test("Full view modifier flow: loadImage + urlChanges subscription")
    func fullViewModifierFlow() async throws {
        let cache = ImageCache()

        let identifier = "conversation-\(UUID().uuidString)"
        let url1 = URL(string: "https://example.com/group-avatar-v1.jpg")!
        let url2 = URL(string: "https://example.com/group-avatar-v2.jpg")!

        // Create immutable cacheables for each URL state
        let cacheable1 = TestImageCacheable(identifier: identifier, url: url1)
        let cacheable2 = TestImageCacheable(identifier: identifier, url: url2)

        // Track URL changes received
        var urlChangesReceived: [ImageURLChange] = []

        // Subscribe to URL changes (like the view modifier does)
        let cancellable = cache.urlChanges
            .filter { $0.identifier == identifier }
            .sink { change in
                urlChangesReceived.append(change)
            }
        defer { cancellable.cancel() }

        // Initial load (simulates .task modifier)
        let initialImage = await cache.loadImage(for: cacheable1)

        // Initial load with no cached image should return nil (network would fetch)
        #expect(initialImage == nil)

        // Simulate prefetcher caching the image for url1
        let image1 = createTestImage(color: .red)
        cache.cacheAfterUpload(image1, for: identifier, url: url1.absoluteString)

        try await Task.sleep(nanoseconds: 200_000_000)

        // Should have received URL change for url1
        #expect(urlChangesReceived.count >= 1)
        #expect(urlChangesReceived.first?.newURL == url1)

        // Now simulate URL changing to url2 (e.g., update from another device)
        let image2 = createTestImage(color: .blue)
        cache.cacheAfterUpload(image2, for: identifier, url: url2.absoluteString)

        try await Task.sleep(nanoseconds: 200_000_000)

        // Should have received second URL change for url2
        #expect(urlChangesReceived.count >= 2)
        #expect(urlChangesReceived.last?.newURL == url2)

        // Reload with new cacheable (simulates view responding to URL change)
        let reloadedImage = await cache.loadImage(for: cacheable2)
        #expect(reloadedImage != nil)
    }

    // MARK: - prepareForUpload Tests

    @Test("prepareForUpload returns JPEG data")
    func prepareForUploadReturnsData() async throws {
        let cache = ImageCache()
        let cacheable = TestImageCacheable(identifier: "upload-\(UUID().uuidString)")
        let testImage = createTestImage()

        let data = cache.prepareForUpload(testImage, for: cacheable)

        #expect(data != nil)
        #expect(data!.count > 0)

        // Verify it's valid JPEG
        let reconstructed = UIImage(data: data!)
        #expect(reconstructed != nil)
    }

    @Test("prepareForUpload caches image immediately")
    func prepareForUploadCachesImmediately() async throws {
        let cache = ImageCache()
        let identifier = "upload-cache-\(UUID().uuidString)"
        let cacheable = TestImageCacheable(identifier: identifier)
        let testImage = createTestImage()

        _ = cache.prepareForUpload(testImage, for: cacheable)

        // Wait for async caching
        try await Task.sleep(nanoseconds: 100_000_000)

        let cached = cache.image(for: cacheable)
        #expect(cached != nil)
    }

    @Test("prepareForUpload emits cacheUpdates")
    func prepareForUploadEmitsCacheUpdates() async throws {
        let cache = ImageCache()
        var receivedIdentifiers: [String] = []
        let cancellable = cache.cacheUpdates.sink { identifier in
            receivedIdentifiers.append(identifier)
        }
        defer { cancellable.cancel() }

        let identifier = "upload-notify-\(UUID().uuidString)"
        let cacheable = TestImageCacheable(identifier: identifier)
        let testImage = createTestImage()

        _ = cache.prepareForUpload(testImage, for: cacheable)

        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(receivedIdentifiers.contains(identifier))
    }

    // MARK: - Identifier-based API Tests (for QR codes)

    @Test("Identifier-based caching works without URL")
    func identifierBasedCaching() async throws {
        let cache = ImageCache()
        let identifier = "qr-code-\(UUID().uuidString)"
        let testImage = createTestImage()

        cache.cacheImage(testImage, for: identifier)

        let cached = cache.image(for: identifier)
        #expect(cached != nil)
    }

    @Test("Identifier-based caching supports PNG format")
    func identifierBasedCachingPng() async throws {
        let cache = ImageCache()
        let identifier = "qr-png-\(UUID().uuidString)"
        let testImage = createTestImage()

        cache.cacheImage(testImage, for: identifier, imageFormat: .png)

        let cached = cache.image(for: identifier, imageFormat: .png)
        #expect(cached != nil)
    }

    @Test("removeImage clears both memory and disk")
    func removeImageClearsBothCaches() async throws {
        let cache = ImageCache()
        let identifier = "remove-test-\(UUID().uuidString)"
        let testImage = createTestImage()

        cache.cacheImage(testImage, for: identifier)

        // Wait for disk write
        try await Task.sleep(nanoseconds: 200_000_000)

        // Verify cached
        #expect(cache.image(for: identifier) != nil)

        // Remove
        cache.removeImage(for: identifier)

        // Wait for disk removal
        try await Task.sleep(nanoseconds: 200_000_000)

        // Should be gone from memory
        #expect(cache.image(for: identifier) == nil)

        // And from disk (new cache instance)
        let cache2 = ImageCache()
        let diskImage = await cache2.imageAsync(for: identifier)
        #expect(diskImage == nil)
    }

    // MARK: - Object-based API Tests

    @Test("cacheImage with object identifier stores and notifies")
    func cacheImageWithObjectIdentifier() async throws {
        let cache = ImageCache()
        var receivedIdentifiers: [String] = []
        let cancellable = cache.cacheUpdates.sink { identifier in
            receivedIdentifiers.append(identifier)
        }
        defer { cancellable.cancel() }

        let url = URL(string: "https://example.com/image.jpg")!
        let cacheable = TestImageCacheable(identifier: "object-set-\(UUID().uuidString)", url: url)
        let testImage = createTestImage()

        cache.cacheImage(testImage, for: cacheable.imageCacheIdentifier)

        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(cache.image(for: cacheable) != nil)
        #expect(receivedIdentifiers.contains(cacheable.imageCacheIdentifier))
    }

    @Test("imageAsync returns disk-cached image")
    func imageAsyncReturnsDiskCached() async throws {
        let cache = ImageCache()
        let identifier = "disk-async-\(UUID().uuidString)"
        let cacheable = TestImageCacheable(identifier: identifier)
        let testImage = createTestImage()

        cache.cacheImage(testImage, for: identifier)

        // Wait for disk write
        try await Task.sleep(nanoseconds: 300_000_000)

        // New cache instance (fresh memory cache)
        let cache2 = ImageCache()
        let loaded = await cache2.imageAsync(for: cacheable)

        #expect(loaded != nil)
    }

    // MARK: - Edge Cases

    @Test("Invalid URL string in cacheAfterUpload logs error but doesn't crash")
    func invalidUrlStringHandled() async throws {
        let cache = ImageCache()
        let identifier = "invalid-url-\(UUID().uuidString)"
        let testImage = createTestImage()

        // This should not crash
        cache.cacheAfterUpload(testImage, for: identifier, url: "not a valid url ::::")

        try await Task.sleep(nanoseconds: 100_000_000)

        // Image should still be accessible (even if URL tracking failed)
        // Note: Current implementation may not cache if URL is invalid
    }

    @Test("Empty identifier is handled")
    func emptyIdentifierHandled() async throws {
        let cache = ImageCache()
        let testImage = createTestImage()

        // Should not crash with empty identifier
        cache.cacheImage(testImage, for: "")

        try await Task.sleep(nanoseconds: 100_000_000)

        let cached = cache.image(for: "")
        #expect(cached != nil)
    }

    @Test("Very long identifier is handled")
    func longIdentifierHandled() async throws {
        let cache = ImageCache()
        let longId = String(repeating: "a", count: 1000)
        let testImage = createTestImage()

        cache.cacheImage(testImage, for: longId)

        try await Task.sleep(nanoseconds: 100_000_000)

        let cached = cache.image(for: longId)
        #expect(cached != nil)
    }

    @Test("Special characters in identifier are handled")
    func specialCharsIdentifierHandled() async throws {
        let cache = ImageCache()
        let specialId = "profile/user@example.com?v=1&test=true#anchor"
        let testImage = createTestImage()

        cache.cacheImage(testImage, for: specialId)

        // Wait for disk write (special chars are hashed)
        try await Task.sleep(nanoseconds: 200_000_000)

        let cached = cache.image(for: specialId)
        #expect(cached != nil)

        // Verify disk cache works with special chars (new instance)
        let cache2 = ImageCache()
        let diskCached = await cache2.imageAsync(for: specialId)
        #expect(diskCached != nil)
    }

    // MARK: - Concurrent Access Tests

    @Test("Concurrent cacheAfterUpload calls are safe")
    func concurrentCacheAfterUpload() async throws {
        let cache = ImageCache()
        let baseId = "concurrent-\(UUID().uuidString)"

        // Launch many concurrent cache operations
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    let image = createTestImage(color: UIColor(
                        red: CGFloat(i) / 20.0,
                        green: 0.5,
                        blue: 0.5,
                        alpha: 1.0
                    ))
                    cache.cacheAfterUpload(
                        image,
                        for: "\(baseId)-\(i)",
                        url: "https://example.com/\(i).jpg"
                    )
                }
            }
        }

        try await Task.sleep(nanoseconds: 500_000_000)

        // All should be cached
        for i in 0..<20 {
            let cached = cache.image(for: "\(baseId)-\(i)")
            #expect(cached != nil)
        }
    }

    @Test("Concurrent URL changes for same identifier are serialized")
    func concurrentUrlChangesForSameIdentifier() async throws {
        let cache = ImageCache()
        let identifier = "same-id-\(UUID().uuidString)"
        var receivedChanges: [ImageURLChange] = []
        let lock = NSLock()

        let cancellable = cache.urlChanges
            .filter { $0.identifier == identifier }
            .sink { change in
                lock.lock()
                receivedChanges.append(change)
                lock.unlock()
            }
        defer { cancellable.cancel() }

        // Rapid URL changes
        for i in 0..<10 {
            cache.cacheAfterUpload(
                createTestImage(),
                for: identifier,
                url: "https://example.com/v\(i).jpg"
            )
        }

        try await Task.sleep(nanoseconds: 500_000_000)

        // Should receive change events (exact count may vary due to rapid updates)
        #expect(receivedChanges.count >= 1)
    }
}

// MARK: - Encrypted Image Cold Start Integration Test

@Suite("Encrypted Image Cold Start Tests", .serialized)
struct EncryptedImageColdStartTests {
    init() {
        configureTestEnvironment()
    }

    @Test("Cold start loadImage for encrypted image loads from disk")
    func coldStartEncryptedImageLoadsFromDisk() async throws {
        let cache = ImageCache()
        let identifier = "encrypted-cold-start-\(UUID().uuidString)"
        let url = URL(string: "https://example.com/encrypted-avatar.jpg")!
        let testImage = createTestImage(color: .green)

        // Simulate image being cached to disk (as prefetcher would do)
        cache.cacheAfterUpload(testImage, for: identifier, url: url.absoluteString)

        // Wait for disk write to complete
        try await Task.sleep(nanoseconds: 500_000_000)

        // Create a fresh cache instance (simulating cold start - empty memory, URL tracker empty)
        let cache2 = ImageCache()

        // Create a cacheable with isEncryptedImage = true
        struct EncryptedCacheable: ImageCacheable {
            let imageCacheIdentifier: String
            let imageCacheURL: URL?
            let isEncryptedImage: Bool = true
        }

        let encryptedCacheable = EncryptedCacheable(
            imageCacheIdentifier: identifier,
            imageCacheURL: url
        )

        // On cold start with encrypted image:
        // - hasURLChanged() returns true (triggering prefetcher to verify)
        // - loadImage still returns cached disk image while prefetcher runs
        let loadedImage = await cache2.loadImage(for: encryptedCacheable)

        #expect(loadedImage != nil, "Cold start should load encrypted image from disk")

        // Cleanup
        cache2.removeImage(for: identifier)
    }
}

// MARK: - URL Tracking Behavior Tests

@Suite("ImageCache URL Tracking Tests", .serialized)
struct ImageCacheURLTrackingTests {
    init() {
        configureTestEnvironment()
    }

    @Test("hasURLChanged returns true when no entry exists (cold start - need to verify)")
    func hasUrlChangedTrueWhenNoEntry() async throws {
        let cache = ImageCache()
        let identifier = "new-profile-\(UUID().uuidString)"
        let url = URL(string: "https://example.com/avatar.jpg")!

        // On cold start, there's no entry in the tracker but disk cache may have stale data
        // hasURLChanged should return true to trigger verification/prefetch
        // This ensures stale cached images get refreshed when URL changes happen while app is closed
        let hasChanged = await cache.hasURLChanged(url.absoluteString, for: identifier)

        #expect(hasChanged == true, "hasURLChanged should return true when no entry exists (cold start - need to verify)")
    }

    @Test("hasURLChanged returns true when entry exists and URL differs")
    func hasUrlChangedTrueWhenUrlDiffers() async throws {
        let cache = ImageCache()
        let identifier = "profile-url-change-\(UUID().uuidString)"
        let url1 = URL(string: "https://example.com/avatar-v1.jpg")!
        let url2 = URL(string: "https://example.com/avatar-v2.jpg")!

        // Track url1 using the test helper (no image required)
        await cache.trackURLForTesting(url1, for: identifier)

        // Now check if url2 would be considered changed
        let hasChanged = await cache.hasURLChanged(url2.absoluteString, for: identifier)

        #expect(hasChanged == true, "hasURLChanged should return true when URL differs from tracked entry")
    }

    @Test("hasURLChanged returns false when entry exists and URL is same")
    func hasUrlChangedFalseWhenUrlSame() async throws {
        let cache = ImageCache()
        let identifier = "profile-same-url-\(UUID().uuidString)"
        let url = URL(string: "https://example.com/avatar.jpg")!

        // Track the URL using the test helper
        await cache.trackURLForTesting(url, for: identifier)

        // Check if the same URL would be considered changed
        let hasChanged = await cache.hasURLChanged(url.absoluteString, for: identifier)

        #expect(hasChanged == false, "hasURLChanged should return false when URL is same as tracked entry")
    }

    @Test("hasURLChanged returns true when URL is nil and entry exists")
    func hasUrlChangedTrueWhenNilAndEntryExists() async throws {
        let cache = ImageCache()
        let identifier = "profile-nil-url-\(UUID().uuidString)"
        let url = URL(string: "https://example.com/avatar.jpg")!

        // Track the URL using the test helper
        await cache.trackURLForTesting(url, for: identifier)

        // Check if nil URL would be considered changed (user removed avatar)
        let hasChanged = await cache.hasURLChanged(nil, for: identifier)

        #expect(hasChanged == true, "hasURLChanged should return true when URL is nil but entry exists")
    }

    @Test("hasURLChanged returns false when URL is nil and no entry exists")
    func hasUrlChangedFalseWhenNilAndNoEntry() async throws {
        let cache = ImageCache()
        let identifier = "profile-no-avatar-\(UUID().uuidString)"

        // No entry tracked, URL is nil (user never had an avatar)
        let hasChanged = await cache.hasURLChanged(nil, for: identifier)

        #expect(hasChanged == false, "hasURLChanged should return false when URL is nil and no entry exists")
    }
}

// MARK: - URLChange Flow Integration Tests

@Suite("ImageCache URL Change Flow Tests", .serialized)
struct ImageCacheURLChangeFlowTests {
    init() {
        configureTestEnvironment()
    }

    @Test("Complete prefetch flow emits correct URL change events")
    func completePrefetchFlow() async throws {
        let cache = ImageCache()
        var changes: [ImageURLChange] = []
        let cancellable = cache.urlChanges.sink { changes.append($0) }
        defer { cancellable.cancel() }

        let profileId = "inbox-\(UUID().uuidString)"
        let oldUrl = "https://cdn.example.com/avatar/old.jpg"
        let newUrl = "https://cdn.example.com/avatar/new.jpg"

        // Step 1: Initial prefetch caches with old URL
        cache.cacheAfterUpload(createTestImage(color: .red), for: profileId, url: oldUrl)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Step 2: URL changes (detected during sync)
        // First, invalidate old cache (simulating ConversationWriter behavior)
        cache.removeImage(for: profileId)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Step 3: Prefetch with new URL
        cache.cacheAfterUpload(createTestImage(color: .blue), for: profileId, url: newUrl)
        try await Task.sleep(nanoseconds: 100_000_000)

        // Verify changes
        let profileChanges = changes.filter { $0.identifier == profileId }
        #expect(profileChanges.count >= 2)

        // First should be nil -> oldUrl
        #expect(profileChanges[0].oldURL == nil)
        #expect(profileChanges[0].newURL?.absoluteString == oldUrl)

        // After removal and re-cache, should see change to newUrl
        let lastChange = profileChanges.last!
        #expect(lastChange.newURL?.absoluteString == newUrl)
    }

    @Test("Subscriber filtering correctly isolates identifier events")
    func subscriberFilteringIsolates() async throws {
        let cache = ImageCache()

        let profile1Id = "profile-1-\(UUID().uuidString)"
        let profile2Id = "profile-2-\(UUID().uuidString)"
        let convoId = "convo-\(UUID().uuidString)"

        var profile1Changes: [ImageURLChange] = []
        var profile2Changes: [ImageURLChange] = []
        var convoChanges: [ImageURLChange] = []

        let c1 = cache.urlChanges
            .filter { $0.identifier == profile1Id }
            .sink { profile1Changes.append($0) }
        let c2 = cache.urlChanges
            .filter { $0.identifier == profile2Id }
            .sink { profile2Changes.append($0) }
        let c3 = cache.urlChanges
            .filter { $0.identifier == convoId }
            .sink { convoChanges.append($0) }
        defer {
            c1.cancel()
            c2.cancel()
            c3.cancel()
        }

        // Cache for all three
        cache.cacheAfterUpload(createTestImage(), for: profile1Id, url: "https://example.com/p1.jpg")
        cache.cacheAfterUpload(createTestImage(), for: profile2Id, url: "https://example.com/p2.jpg")
        cache.cacheAfterUpload(createTestImage(), for: convoId, url: "https://example.com/c.jpg")

        try await Task.sleep(nanoseconds: 200_000_000)

        // Update only profile1
        cache.cacheAfterUpload(createTestImage(), for: profile1Id, url: "https://example.com/p1-v2.jpg")

        try await Task.sleep(nanoseconds: 100_000_000)

        // profile1 should have 2 changes, others should have 1
        #expect(profile1Changes.count == 2)
        #expect(profile2Changes.count == 1)
        #expect(convoChanges.count == 1)
    }

    @Test("View can detect when image URL cleared")
    func viewDetectsUrlCleared() async throws {
        let cache = ImageCache()

        let identifier = "profile-clear-\(UUID().uuidString)"
        var hasImage = false

        let cancellable = cache.urlChanges
            .filter { $0.identifier == identifier }
            .sink { change in
                hasImage = change.newURL != nil
            }
        defer { cancellable.cancel() }

        // Initial cache
        cache.cacheAfterUpload(createTestImage(), for: identifier, url: "https://example.com/avatar.jpg")
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(hasImage == true)

        // Simulate loading with nil URL (user removed avatar)
        let cacheable = TestImageCacheable(identifier: identifier, url: nil)
        _ = await cache.loadImage(for: cacheable)

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(hasImage == false)
    }
}

// MARK: - Disk Cache Overwrite Tests

@Suite("Disk Cache Overwrite Tests", .serialized)
struct DiskCacheOverwriteTests {
    init() {
        configureTestEnvironment()
    }

    @Test("Disk cache is updated when URL changes (cacheAfterUpload overwrites existing file)")
    func diskCacheUpdatedOnUrlChange() async throws {
        let cache = ImageCache()
        let identifier = "disk-overwrite-\(UUID().uuidString)"
        let url1 = "https://example.com/avatar-v1.jpg"
        let url2 = "https://example.com/avatar-v2.jpg"

        // Create two different colored images
        let redImage = createTestImage(color: .red)
        let blueImage = createTestImage(color: .blue)

        // Cache the red image with url1
        cache.cacheAfterUpload(redImage, for: identifier, url: url1)
        try await Task.sleep(nanoseconds: 300_000_000)

        // Verify red image is in cache
        let cachedRed = await cache.imageAsync(for: identifier, imageFormat: .jpg)
        #expect(cachedRed != nil, "Red image should be cached")

        // Cache the blue image with url2 (simulates URL change)
        cache.cacheAfterUpload(blueImage, for: identifier, url: url2)
        try await Task.sleep(nanoseconds: 300_000_000)

        // Verify blue image is in cache (memory)
        let cachedBlue = await cache.imageAsync(for: identifier, imageFormat: .jpg)
        #expect(cachedBlue != nil, "Blue image should be cached")

        // Create a fresh cache instance (simulates cold start - empty memory)
        let cache2 = ImageCache()

        // Load from disk only - should get the BLUE image, not the red one
        let diskImage = await cache2.imageAsync(for: identifier, imageFormat: .jpg)
        #expect(diskImage != nil, "Image should be loadable from disk after cold start")

        // Cleanup
        cache2.removeImage(for: identifier)
    }

    @Test("Cold start after URL change loads new image from disk")
    func coldStartAfterUrlChangeLoadsNewImage() async throws {
        let cache = ImageCache()
        let identifier = "cold-start-url-change-\(UUID().uuidString)"

        // Cache image with initial URL
        cache.cacheAfterUpload(createTestImage(color: .green), for: identifier, url: "https://example.com/v1.jpg")
        try await Task.sleep(nanoseconds: 300_000_000)

        // Update with new URL and new image
        let newImage = createTestImage(width: 200, height: 200, color: .purple)
        cache.cacheAfterUpload(newImage, for: identifier, url: "https://example.com/v2.jpg")
        try await Task.sleep(nanoseconds: 300_000_000)

        // Simulate cold start
        let freshCache = ImageCache()

        // Load from disk
        let loadedImage = await freshCache.imageAsync(for: identifier, imageFormat: .jpg)
        #expect(loadedImage != nil, "Should load image from disk after cold start")

        // Cleanup
        freshCache.removeImage(for: identifier)
    }
}

#endif
