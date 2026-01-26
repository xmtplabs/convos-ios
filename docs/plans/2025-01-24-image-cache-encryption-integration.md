# Image Cache & Encryption Integration Fix Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the URL vs identifier cache lookup mismatch bug, simplify ImageCacheProtocol API to prevent similar issues, and add integration tests for multi-device encrypted image sync.

**Architecture:** The image cache uses a single-entry-per-object model with URL tracking. Images are cached by stable identifier (inboxId, conversationId), while URLTracker monitors URL changes to trigger view updates. EncryptedImagePrefetcher currently checks cache by URL but stores by identifier, causing missed cache hits.

**Tech Stack:** Swift, async/await, Combine publishers, XCTest, protocol-based dependency injection

---

## Task 1: Fix URL vs Identifier Mismatch in EncryptedImagePrefetcher

The bug: `filterUncachedProfiles()` checks `imageAsync(for: urlString)` but caching uses `cacheAfterUpload(for: hydratedProfile)` which stores by `profile.inboxId`. This means the cache check never finds the cached image.

**Files:**
- Modify: `ConvosCore/Sources/ConvosCore/Crypto/EncryptedImagePrefetcher.swift:43-56`

**Step 1: Update filterUncachedProfiles to check by identifier**

Replace URL-based cache check with identifier-based check:

```swift
private func filterUncachedProfiles(_ profiles: [DBMemberProfile]) async -> [DBMemberProfile] {
    var uncached: [DBMemberProfile] = []
    for profile in profiles {
        guard profile.hasValidEncryptedAvatar else {
            continue
        }

        // Check by identifier (inboxId), not URL - matches how we cache
        if await ImageCacheContainer.shared.imageAsync(for: profile.inboxId) == nil {
            uncached.append(profile)
        }
    }
    return uncached
}
```

**Step 2: Verify fix compiles**

Run: `xcodebuild build -scheme "Convos (Dev)" -destination "platform=iOS Simulator,name=iPhone 16" -derivedDataPath .derivedData 2>&1 | head -50`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add ConvosCore/Sources/ConvosCore/Crypto/EncryptedImagePrefetcher.swift
git commit -m "$(cat <<'EOF'
fix: Check cache by identifier in filterUncachedProfiles

The cache stores images by identifier (inboxId) via cacheAfterUpload,
but filterUncachedProfiles was checking by URL. This mismatch caused
the filter to always miss cached images, resulting in redundant fetches.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Add Request Deduplication for Encrypted Image Fetches

Currently, multiple concurrent prefetch requests for the same profile can cause duplicate network requests. The regular `loadImage` method has deduplication via `loadingTasksLock`, but `EncryptedImagePrefetcher` doesn't.

**Files:**
- Modify: `ConvosCore/Sources/ConvosCore/Crypto/EncryptedImagePrefetcher.swift`

**Step 1: Add in-flight task tracking**

Add actor-isolated dictionary to track in-flight fetches by inboxId:

```swift
actor EncryptedImagePrefetcher: EncryptedImagePrefetcherProtocol {
    private static let maxConcurrentDownloads: Int = 4
    private static let maxRetryAttempts: Int = 2
    private static let retryDelaySeconds: UInt64 = 1

    private var inflightFetches: [String: Task<Void, Never>] = [:]

    init() {}
```

**Step 2: Update prefetchWithRetry to deduplicate**

Wrap the fetch logic to check for and join existing tasks:

```swift
private func prefetchWithRetry(profile: DBMemberProfile, groupKey: Data) async {
    let inboxId = profile.inboxId

    // Check if already fetching this profile
    if let existingTask = inflightFetches[inboxId] {
        await existingTask.value
        return
    }

    let task = Task<Void, Never> {
        await self.doFetch(profile: profile, groupKey: groupKey)
    }
    inflightFetches[inboxId] = task

    await task.value
    inflightFetches.removeValue(forKey: inboxId)
}

private func doFetch(profile: DBMemberProfile, groupKey: Data) async {
    guard profile.hasValidEncryptedAvatar,
          let urlString = profile.avatar,
          let url = URL(string: urlString),
          let salt = profile.avatarSalt,
          let nonce = profile.avatarNonce else {
        return
    }

    var lastError: Error?

    for attempt in 0..<Self.maxRetryAttempts {
        do {
            let params = EncryptedImageParams(
                url: url,
                salt: salt,
                nonce: nonce,
                groupKey: groupKey
            )

            let decryptedData = try await EncryptedImageLoader.loadAndDecrypt(params: params)

            guard let image = ImageType(data: decryptedData) else {
                throw NSError(
                    domain: "EncryptedImagePrefetcher",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create image from decrypted data"]
                )
            }
            let hydratedProfile = profile.hydrateProfile()
            ImageCacheContainer.shared.cacheAfterUpload(image, for: hydratedProfile, url: urlString)
            Log.info("Prefetched encrypted profile image for: \(profile.inboxId)")
            return
        } catch {
            lastError = error
            if attempt < Self.maxRetryAttempts - 1 {
                try? await Task.sleep(nanoseconds: Self.retryDelaySeconds * 1_000_000_000)
            }
        }
    }

    if let error = lastError {
        Log.error("Failed to prefetch encrypted profile image after \(Self.maxRetryAttempts) attempts: \(error)")
    }
}
```

**Step 3: Verify fix compiles**

Run: `xcodebuild build -scheme "Convos (Dev)" -destination "platform=iOS Simulator,name=iPhone 16" -derivedDataPath .derivedData 2>&1 | head -50`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add ConvosCore/Sources/ConvosCore/Crypto/EncryptedImagePrefetcher.swift
git commit -m "$(cat <<'EOF'
feat: Add request deduplication for encrypted image prefetch

Multiple concurrent requests for the same profile now share a single
network request via actor-isolated task tracking. This prevents
redundant downloads when the same profile is prefetched from multiple
conversations simultaneously.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Simplify ImageCacheProtocol API

The current protocol has 20+ methods with overlapping purposes. This complexity led to the URL/identifier bug. Simplify to a clear, minimal API.

**Current API categories:**
- Object-based: `loadImage`, `image(for object:)`, `imageAsync(for object:)`, `setImage(for object:)`, `removeImage(for object:)`
- Identifier-based: `image(for identifier:)`, `imageAsync(for identifier:)`, `cacheImage(for identifier:)`, `removeImage(for identifier:)`
- URL-based: `image(for url:)`, `imageAsync(for url:)`, `setImage(for url:)`
- Upload support: `prepareForUpload`, `cacheAfterUpload` (two overloads), `resizeCacheAndGetData` (two overloads)

**Simplification strategy:**
1. Remove URL-based methods (not needed with URL tracking)
2. Keep object-based as primary API
3. Keep identifier-based for QR codes and internal use
4. Consolidate upload methods

**Files:**
- Modify: `ConvosCore/Sources/ConvosCore/Image Cache/ImageCacheProtocol.swift`
- Modify: `ConvosCore/Sources/ConvosCore/Image Cache/ImageCache.swift`
- Modify: `ConvosCore/Sources/ConvosCore/Image Cache/MockImageCache.swift`

**Step 1: Define simplified protocol**

```swift
public protocol ImageCacheProtocol: AnyObject, Sendable {
    // MARK: - Primary API (object-based with URL tracking)

    /// Load image for object, fetching from network if needed
    func loadImage(for object: any ImageCacheable) async -> ImageType?

    /// Get cached image synchronously (memory only)
    func image(for object: any ImageCacheable) -> ImageType?

    /// Get cached image asynchronously (memory + disk)
    func imageAsync(for object: any ImageCacheable) async -> ImageType?

    /// Remove cached image for object
    func removeImage(for object: any ImageCacheable)

    // MARK: - Upload Support

    /// Prepare image for upload (resize/compress, cache, return data)
    func prepareForUpload(_ image: ImageType, for object: any ImageCacheable) -> Data?

    /// Update URL tracking after upload completes
    func cacheAfterUpload(_ image: ImageType, for object: any ImageCacheable, url: String)

    /// Cache image after prefetch (identifier-based for encrypted images)
    func cacheAfterUpload(_ image: ImageType, for identifier: String, url: String)

    // MARK: - Identifier-based (for QR codes, generated images)

    /// Get cached image by identifier (memory only)
    func image(for identifier: String, imageFormat: ImageFormat) -> ImageType?

    /// Get cached image by identifier (memory + disk)
    func imageAsync(for identifier: String, imageFormat: ImageFormat) async -> ImageType?

    /// Cache image by identifier
    func cacheImage(_ image: ImageType, for identifier: String, imageFormat: ImageFormat)

    /// Remove cached image by identifier
    func removeImage(for identifier: String)

    // MARK: - Observation

    /// Publisher for URL changes (fires when object's image URL changes)
    var urlChanges: AnyPublisher<ImageURLChange, Never> { get }

    /// Publisher for cache updates (backward compatibility)
    var cacheUpdates: AnyPublisher<String, Never> { get }
}
```

**Step 2: Remove deprecated URL-based methods from ImageCache**

Remove these methods from ImageCache.swift:
- `image(for url: URL) -> ImageType?`
- `imageAsync(for url: URL) async -> ImageType?`
- `setImage(_ image: ImageType, for url: String)`

Also remove:
- `resizeCacheAndGetData` (both overloads) - use `prepareForUpload` instead
- `setImage(_ image: ImageType, for object: any ImageCacheable)` - use `cacheAfterUpload` instead

**Step 3: Update MockImageCache**

```swift
#if os(macOS)
import AppKit
import Combine
import Foundation

public final class MockImageCache: ImageCacheProtocol, @unchecked Sendable {
    private var storage: [String: NSImage] = [:]
    private var trackedURLs: [String: URL] = [:]
    private let cacheUpdateSubject = PassthroughSubject<String, Never>()
    private let urlChangeSubject = PassthroughSubject<ImageURLChange, Never>()

    public var cacheUpdates: AnyPublisher<String, Never> {
        cacheUpdateSubject.eraseToAnyPublisher()
    }

    public var urlChanges: AnyPublisher<ImageURLChange, Never> {
        urlChangeSubject.eraseToAnyPublisher()
    }

    public init() {}

    // MARK: - Primary API

    public func loadImage(for object: any ImageCacheable) async -> NSImage? {
        storage[object.imageCacheIdentifier]
    }

    public func image(for object: any ImageCacheable) -> NSImage? {
        storage[object.imageCacheIdentifier]
    }

    public func imageAsync(for object: any ImageCacheable) async -> NSImage? {
        storage[object.imageCacheIdentifier]
    }

    public func removeImage(for object: any ImageCacheable) {
        storage.removeValue(forKey: object.imageCacheIdentifier)
        trackedURLs.removeValue(forKey: object.imageCacheIdentifier)
    }

    // MARK: - Upload Support

    public func prepareForUpload(_ image: NSImage, for object: any ImageCacheable) -> Data? {
        storage[object.imageCacheIdentifier] = image
        cacheUpdateSubject.send(object.imageCacheIdentifier)
        return image.tiffRepresentation
    }

    public func cacheAfterUpload(_ image: NSImage, for object: any ImageCacheable, url: String) {
        let identifier = object.imageCacheIdentifier
        storage[identifier] = image
        if let newURL = URL(string: url) {
            let oldURL = trackedURLs[identifier]
            trackedURLs[identifier] = newURL
            if oldURL != newURL {
                urlChangeSubject.send(ImageURLChange(identifier: identifier, oldURL: oldURL, newURL: newURL))
            }
        }
        cacheUpdateSubject.send(identifier)
    }

    public func cacheAfterUpload(_ image: NSImage, for identifier: String, url: String) {
        storage[identifier] = image
        if let newURL = URL(string: url) {
            let oldURL = trackedURLs[identifier]
            trackedURLs[identifier] = newURL
            if oldURL != newURL {
                urlChangeSubject.send(ImageURLChange(identifier: identifier, oldURL: oldURL, newURL: newURL))
            }
        }
        cacheUpdateSubject.send(identifier)
    }

    // MARK: - Identifier-based

    public func image(for identifier: String, imageFormat: ImageFormat = .jpg) -> NSImage? {
        storage[identifier]
    }

    public func imageAsync(for identifier: String, imageFormat: ImageFormat = .jpg) async -> NSImage? {
        storage[identifier]
    }

    public func cacheImage(_ image: NSImage, for identifier: String, imageFormat: ImageFormat = .jpg) {
        storage[identifier] = image
        cacheUpdateSubject.send(identifier)
    }

    public func removeImage(for identifier: String) {
        storage.removeValue(forKey: identifier)
        trackedURLs.removeValue(forKey: identifier)
    }
}
#endif
```

**Step 4: Update call sites**

Search for removed method usages and update:
- `setImage(for url:)` → `cacheAfterUpload` with identifier
- `resizeCacheAndGetData` → `prepareForUpload`
- `setImage(for object:)` → `cacheAfterUpload`

**Step 5: Verify all changes compile**

Run: `xcodebuild build -scheme "Convos (Dev)" -destination "platform=iOS Simulator,name=iPhone 16" -derivedDataPath .derivedData 2>&1 | head -100`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add ConvosCore/Sources/ConvosCore/Image\ Cache/
git commit -m "$(cat <<'EOF'
refactor: Simplify ImageCacheProtocol API

Remove URL-based methods and consolidate upload support:
- Remove image(for url:), imageAsync(for url:), setImage(for url:)
- Remove resizeCacheAndGetData (use prepareForUpload instead)
- Remove setImage(for object:) (use cacheAfterUpload instead)

The simplified API has clear categories:
1. Primary: loadImage, image, imageAsync, removeImage (object-based)
2. Upload: prepareForUpload, cacheAfterUpload
3. Identifier: for QR codes and internal use
4. Observation: urlChanges, cacheUpdates

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Create Mock EncryptedImageLoader for Testing

To test the encrypted image sync flow without real S3 uploads, we need a mock loader.

**Files:**
- Create: `ConvosCore/Sources/ConvosCore/Crypto/EncryptedImageLoaderProtocol.swift`
- Modify: `ConvosCore/Sources/ConvosCore/Crypto/EncryptedImageLoader.swift`
- Create: `ConvosCore/Tests/ConvosCoreTests/Crypto/MockEncryptedImageLoader.swift`

**Step 1: Extract protocol from EncryptedImageLoader**

```swift
// EncryptedImageLoaderProtocol.swift
import Foundation

public protocol EncryptedImageLoaderProtocol: Sendable {
    func loadAndDecrypt(params: EncryptedImageParams) async throws -> Data
}
```

**Step 2: Make EncryptedImageLoader conform to protocol**

```swift
// EncryptedImageLoader.swift additions
extension EncryptedImageLoader: EncryptedImageLoaderProtocol {
    public static let shared: any EncryptedImageLoaderProtocol = EncryptedImageLoader()

    private init() {}

    public func loadAndDecrypt(params: EncryptedImageParams) async throws -> Data {
        Self.loadAndDecrypt(params: params)
    }
}
```

**Step 3: Create MockEncryptedImageLoader**

```swift
// MockEncryptedImageLoader.swift
import Foundation
@testable import ConvosCore

final class MockEncryptedImageLoader: EncryptedImageLoaderProtocol, @unchecked Sendable {
    private var stubbedImages: [URL: Data] = [:]
    private(set) var loadCalls: [EncryptedImageParams] = []

    func stub(url: URL, with imageData: Data) {
        stubbedImages[url] = imageData
    }

    func loadAndDecrypt(params: EncryptedImageParams) async throws -> Data {
        loadCalls.append(params)

        guard let data = stubbedImages[params.url] else {
            throw URLError(.fileDoesNotExist)
        }

        return data
    }
}
```

**Step 4: Update EncryptedImagePrefetcher to accept loader**

```swift
actor EncryptedImagePrefetcher: EncryptedImagePrefetcherProtocol {
    private let loader: any EncryptedImageLoaderProtocol

    init(loader: any EncryptedImageLoaderProtocol = EncryptedImageLoader.shared) {
        self.loader = loader
    }

    // Use self.loader.loadAndDecrypt instead of EncryptedImageLoader.loadAndDecrypt
}
```

**Step 5: Verify changes compile**

Run: `xcodebuild build -scheme "Convos (Dev)" -destination "platform=iOS Simulator,name=iPhone 16" -derivedDataPath .derivedData 2>&1 | head -50`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add ConvosCore/Sources/ConvosCore/Crypto/
git commit -m "$(cat <<'EOF'
feat: Add EncryptedImageLoaderProtocol for testing

Extract protocol from EncryptedImageLoader to enable dependency
injection in tests. EncryptedImagePrefetcher now accepts a loader
parameter, defaulting to the real implementation.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Write Integration Tests for Multi-Device Sync

Test the complete flow: Device A creates group with photos → Device B joins and receives photos → Both devices update photos and see each other's changes.

**Files:**
- Create: `ConvosCore/Tests/ConvosCoreTests/Integration/EncryptedImageSyncTests.swift`

**Step 1: Create test file with setup**

```swift
import XCTest
@testable import ConvosCore

final class EncryptedImageSyncTests: XCTestCase {
    var mockImageCache: MockImageCache!
    var mockLoader: MockEncryptedImageLoader!
    var prefetcher: EncryptedImagePrefetcher!

    // Test image data
    let aliceProfileData = Data(repeating: 0xAA, count: 100)
    let bobProfileData = Data(repeating: 0xBB, count: 100)
    let groupImageData = Data(repeating: 0xCC, count: 100)
    let updatedAliceData = Data(repeating: 0xDD, count: 100)
    let updatedGroupData = Data(repeating: 0xEE, count: 100)

    // Test encryption parameters
    let groupKey = Data(repeating: 0x01, count: 32)
    let salt = Data(repeating: 0x02, count: 32)
    let nonce = Data(repeating: 0x03, count: 12)

    override func setUp() {
        super.setUp()
        mockImageCache = MockImageCache()
        mockLoader = MockEncryptedImageLoader()
        prefetcher = EncryptedImagePrefetcher(loader: mockLoader)

        // Replace shared cache with mock
        ImageCacheContainer.shared = mockImageCache
    }

    override func tearDown() {
        ImageCacheContainer.shared = ImageCache()
        super.tearDown()
    }
}
```

**Step 2: Test Device B receives Device A's profile photo on join**

```swift
func testDeviceBReceivesAliceProfileOnJoin() async {
    // Given: Device A (Alice) created group with profile photo
    let aliceInboxId = "alice-inbox-id"
    let aliceAvatarURL = URL(string: "https://example.com/alice-avatar.jpg")!

    mockLoader.stub(url: aliceAvatarURL, with: aliceProfileData)

    let aliceProfile = DBMemberProfile(
        conversationId: "test-conversation",
        inboxId: aliceInboxId,
        name: "Alice",
        avatar: aliceAvatarURL.absoluteString,
        avatarSalt: salt,
        avatarNonce: nonce
    )

    // When: Device B joins and prefetches member profiles
    await prefetcher.prefetchProfileImages(
        profiles: [aliceProfile],
        groupKey: groupKey
    )

    // Then: Alice's profile image is cached by identifier
    let cachedImage = await mockImageCache.imageAsync(for: aliceInboxId)
    XCTAssertNotNil(cachedImage, "Alice's profile should be cached")

    // And: Only one network request was made
    XCTAssertEqual(mockLoader.loadCalls.count, 1)
    XCTAssertEqual(mockLoader.loadCalls.first?.url, aliceAvatarURL)
}
```

**Step 3: Test Device B receives group photo on join**

```swift
func testDeviceBReceivesGroupPhotoOnJoin() async {
    // Given: Device A created group with group photo
    let conversationId = "test-conversation"
    let groupImageURL = URL(string: "https://example.com/group-image.jpg")!

    mockLoader.stub(url: groupImageURL, with: groupImageData)

    // When: Device B prefetches group image
    // (This would be called by ConversationWriter.prefetchEncryptedGroupImage)
    let params = EncryptedImageParams(
        url: groupImageURL,
        salt: salt,
        nonce: nonce,
        groupKey: groupKey
    )

    let decryptedData = try! await mockLoader.loadAndDecrypt(params: params)
    let image = ImageType(data: decryptedData)!
    mockImageCache.cacheAfterUpload(image, for: conversationId, url: groupImageURL.absoluteString)

    // Then: Group image is cached by conversationId
    let cachedImage = await mockImageCache.imageAsync(for: conversationId)
    XCTAssertNotNil(cachedImage, "Group image should be cached")
}
```

**Step 4: Test Device A sees Device B's profile photo change**

```swift
func testDeviceASeesDeviceBProfileChange() async {
    // Given: Bob is already in the group with an old avatar
    let bobInboxId = "bob-inbox-id"
    let oldBobAvatarURL = URL(string: "https://example.com/bob-old.jpg")!
    let newBobAvatarURL = URL(string: "https://example.com/bob-new.jpg")!

    // Old image was cached
    let oldImage = ImageType(data: bobProfileData)!
    mockImageCache.cacheAfterUpload(oldImage, for: bobInboxId, url: oldBobAvatarURL.absoluteString)

    // New image stub
    let newBobData = Data(repeating: 0xFF, count: 100)
    mockLoader.stub(url: newBobAvatarURL, with: newBobData)

    // Subscribe to URL changes
    var urlChanges: [ImageURLChange] = []
    let cancellable = mockImageCache.urlChanges.sink { change in
        urlChanges.append(change)
    }

    // When: Bob updates his profile photo (Device B sends update)
    let bobProfile = DBMemberProfile(
        conversationId: "test-conversation",
        inboxId: bobInboxId,
        name: "Bob",
        avatar: newBobAvatarURL.absoluteString,
        avatarSalt: salt,
        avatarNonce: nonce
    )

    await prefetcher.prefetchProfileImages(
        profiles: [bobProfile],
        groupKey: groupKey
    )

    // Then: URL change was emitted
    XCTAssertEqual(urlChanges.count, 1)
    XCTAssertEqual(urlChanges.first?.identifier, bobInboxId)
    XCTAssertEqual(urlChanges.first?.oldURL, oldBobAvatarURL)
    XCTAssertEqual(urlChanges.first?.newURL, newBobAvatarURL)

    cancellable.cancel()
}
```

**Step 5: Test profile image not refetched when already cached**

```swift
func testAlreadyCachedProfileNotRefetched() async {
    // Given: Alice's profile is already cached
    let aliceInboxId = "alice-inbox-id"
    let aliceAvatarURL = URL(string: "https://example.com/alice-avatar.jpg")!

    let cachedImage = ImageType(data: aliceProfileData)!
    mockImageCache.cacheAfterUpload(cachedImage, for: aliceInboxId, url: aliceAvatarURL.absoluteString)

    let aliceProfile = DBMemberProfile(
        conversationId: "test-conversation",
        inboxId: aliceInboxId,
        name: "Alice",
        avatar: aliceAvatarURL.absoluteString,
        avatarSalt: salt,
        avatarNonce: nonce
    )

    // When: Prefetch is called again
    await prefetcher.prefetchProfileImages(
        profiles: [aliceProfile],
        groupKey: groupKey
    )

    // Then: No network request was made (image was found in cache by identifier)
    XCTAssertEqual(mockLoader.loadCalls.count, 0, "Should not refetch already cached image")
}
```

**Step 6: Test request deduplication**

```swift
func testConcurrentPrefetchesAreDeduplicated() async {
    // Given: Alice's profile needs to be fetched
    let aliceInboxId = "alice-inbox-id"
    let aliceAvatarURL = URL(string: "https://example.com/alice-avatar.jpg")!

    mockLoader.stub(url: aliceAvatarURL, with: aliceProfileData)

    let aliceProfile = DBMemberProfile(
        conversationId: "test-conversation",
        inboxId: aliceInboxId,
        name: "Alice",
        avatar: aliceAvatarURL.absoluteString,
        avatarSalt: salt,
        avatarNonce: nonce
    )

    // When: Multiple concurrent prefetch requests are made
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<5 {
            group.addTask {
                await self.prefetcher.prefetchProfileImages(
                    profiles: [aliceProfile],
                    groupKey: self.groupKey
                )
            }
        }
    }

    // Then: Only one network request was made
    XCTAssertEqual(mockLoader.loadCalls.count, 1, "Concurrent requests should be deduplicated")
}
```

**Step 7: Run tests**

Run: `swift test --package-path ConvosCore --filter EncryptedImageSyncTests`
Expected: All tests pass

**Step 8: Commit**

```bash
git add ConvosCore/Tests/ConvosCoreTests/Integration/EncryptedImageSyncTests.swift
git add ConvosCore/Tests/ConvosCoreTests/Crypto/MockEncryptedImageLoader.swift
git commit -m "$(cat <<'EOF'
test: Add integration tests for encrypted image sync

Tests cover the multi-device sync scenario:
- Device B receives Device A's profile photo on join
- Device B receives group photo on join
- Device A sees Device B's profile photo change
- Already cached profiles are not refetched
- Concurrent prefetch requests are deduplicated

Uses MockEncryptedImageLoader to avoid real network requests.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Run Full Test Suite and Verify

**Step 1: Run all ImageCache tests**

Run: `swift test --package-path ConvosCore --filter ImageCache`
Expected: All tests pass

**Step 2: Run all EncryptedImage tests**

Run: `swift test --package-path ConvosCore --filter Encrypted`
Expected: All tests pass

**Step 3: Build full app**

Run: `xcodebuild build -scheme "Convos (Dev)" -destination "platform=iOS Simulator,name=iPhone 16" -derivedDataPath .derivedData 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 4: Run SwiftLint**

Run: `swiftlint`
Expected: No errors (warnings acceptable)

**Step 5: Final commit for any cleanup**

If any issues found, fix and commit with appropriate message.

---

## Verification Checklist

After completing all tasks:

1. [ ] `filterUncachedProfiles` checks cache by identifier (inboxId), not URL
2. [ ] Concurrent prefetch requests are deduplicated
3. [ ] ImageCacheProtocol has simplified API (no URL-based methods)
4. [ ] MockImageCache matches new protocol
5. [ ] EncryptedImageLoader has protocol for testing
6. [ ] Integration tests cover multi-device sync scenario
7. [ ] All tests pass
8. [ ] Build succeeds
9. [ ] SwiftLint passes

---

## Appendix: Files Modified Summary

| File | Action | Purpose |
|------|--------|---------|
| `EncryptedImagePrefetcher.swift` | Modify | Fix cache check, add deduplication |
| `ImageCacheProtocol.swift` | Modify | Remove URL-based methods |
| `ImageCache.swift` | Modify | Remove deprecated methods |
| `MockImageCache.swift` | Modify | Update for new protocol |
| `EncryptedImageLoaderProtocol.swift` | Create | Enable DI for testing |
| `EncryptedImageLoader.swift` | Modify | Conform to protocol |
| `MockEncryptedImageLoader.swift` | Create | Test double for loader |
| `EncryptedImageSyncTests.swift` | Create | Integration tests |
