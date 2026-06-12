import Combine
import CryptoKit
import Foundation
import Observation
import os

// MARK: - Image Format

/// Image format for caching
public enum ImageFormat: Sendable {
    case jpg
    case png

    var fileExtension: String {
        switch self {
        case .jpg: return ".jpg"
        case .png: return ".png"
        }
    }
}

// MARK: - Image Storage Tier

/// Controls where images are stored on disk
public enum ImageStorageTier: Sendable {
    /// LRU-evictable cache for re-fetchable images (avatars, group images, QR codes).
    /// Stored in Caches/ which iOS may purge under storage pressure.
    case cache

    /// Persistent storage for chat photo attachments that cannot be re-fetched.
    /// Stored in Application Support/ which is not purged by iOS.
    case persistent
}

// MARK: - ImageCacheable Protocol

/// Protocol for objects that can have their images cached.
public protocol ImageCacheable: Sendable {
    /// Unique identifier used for caching the image
    var imageCacheIdentifier: String { get }

    /// The current image URL for this object (nil if no image or not URL-based)
    var imageCacheURL: URL? { get }

    /// Whether the image at the URL is encrypted and requires decryption
    /// For encrypted images, loadImage() returns cached image and lets the prefetcher handle fetching
    var isEncryptedImage: Bool { get }

    /// The encryption key for decrypting the image (32-byte AES-256 key)
    var encryptionKey: Data? { get }

    /// The salt used for image encryption (32 bytes)
    var encryptionSalt: Data? { get }

    /// The nonce used for image encryption (12 bytes)
    var encryptionNonce: Data? { get }
}

extension ImageCacheable {
    public var isEncryptedImage: Bool { false }
    public var encryptionKey: Data? { nil }
    public var encryptionSalt: Data? { nil }
    public var encryptionNonce: Data? { nil }
}

// MARK: - Shared Instance

/// Container for the shared image cache instance
public enum ImageCacheContainer {
    /// The shared image cache instance. Can be set to a mock for testing.
    nonisolated(unsafe) public static var shared: any ImageCacheProtocol = {
        #if canImport(UIKit)
        return ImageCache()
        #else
        return MockImageCache()
        #endif
    }()
}

// MARK: - URL Change Event

/// Event emitted when an image URL changes for a cached identifier
public struct ImageURLChange: Sendable {
    public let identifier: String
    public let oldURL: URL?
    public let newURL: URL?
}

#if canImport(UIKit)
import SwiftUI

// MARK: - Cache Configuration

/// Configuration for image cache limits and sizes
private struct CacheConfiguration {
    /// Maximum size of disk cache in bytes (500MB)
    static let maxDiskCacheSize: Int = 500 * 1024 * 1024

    /// Maximum number of images in memory cache
    static let memoryCacheCountLimit: Int = 600

    /// Maximum total cost (in bytes) for memory cache (300MB)
    static let memoryCacheTotalCostLimit: Int = 300 * 1024 * 1024
}

// MARK: - URL Tracker

/// Thread-safe tracker for identifier → URL mapping.
///
/// State is durable across launches via per-entry sidecar files
/// (`<sha256(identifier)>.url`) co-located with the disk-cached image.
/// In-memory `trackedURLs` is a hot-path cache populated lazily on first
/// access for an identifier — peek/track/url consult disk only when the
/// in-memory map misses, so steady-state operations stay pure-memory.
///
/// The previous in-memory-only implementation treated a missing entry as
/// `(changed: true)` on cold launch and forced a network round trip even
/// when the disk cache had a perfectly valid image — that's the source
/// of the "avatars missing for a second on launch" regression. With
/// sidecars restored on demand, cold launch knows what URL each cached
/// image came from and can answer truthfully.
private actor URLTracker {
    private var trackedURLs: [String: URL] = [:]
    private let sidecarDirectory: URL?
    private let fileManager: FileManager

    init(sidecarDirectory: URL?, fileManager: FileManager = .default) {
        self.sidecarDirectory = sidecarDirectory
        self.fileManager = fileManager
    }

    /// Track a URL for an identifier, returning whether it changed.
    func track(_ url: URL?, for identifier: String) -> (changed: Bool, oldURL: URL?) {
        let oldURL = loadIntoMemoryIfNeeded(for: identifier)
        guard url != oldURL else {
            return (changed: false, oldURL: oldURL)
        }
        if let url {
            trackedURLs[identifier] = url
            writeSidecar(url: url, for: identifier)
        } else {
            trackedURLs.removeValue(forKey: identifier)
            deleteSidecar(for: identifier)
        }
        return (changed: true, oldURL: oldURL)
    }

    /// Get the currently tracked URL for an identifier.
    func url(for identifier: String) -> URL? {
        loadIntoMemoryIfNeeded(for: identifier)
    }

    /// Check whether a URL would be considered changed without committing
    /// the new URL to the tracker.
    ///
    /// Returns `(changed: false, oldURL: nil)` when both the requested url
    /// and the tracked oldURL are nil — same nil-equals-nil semantic as
    /// `track`'s `guard url != oldURL` short-circuit. With sidecars, cold
    /// launches for previously-cached entries hit `(changed: false, oldURL: <url>)`
    /// and callers can serve the disk image without a network round trip.
    /// Genuinely-unknown identifiers asked about a non-nil url return
    /// `(changed: true, oldURL: nil)` — caller should fetch.
    func peek(_ url: URL?, for identifier: String) -> (changed: Bool, oldURL: URL?) {
        let oldURL = loadIntoMemoryIfNeeded(for: identifier)
        return (changed: url != oldURL, oldURL: oldURL)
    }

    /// Remove tracking for an identifier (in-memory and on-disk sidecar).
    func remove(for identifier: String) {
        trackedURLs.removeValue(forKey: identifier)
        deleteSidecar(for: identifier)
    }

    // MARK: - Sidecar Persistence

    /// Returns the in-memory URL for `identifier`, restoring it from the
    /// on-disk sidecar lazily if necessary. Returns `nil` only when
    /// neither memory nor disk knows the URL.
    private func loadIntoMemoryIfNeeded(for identifier: String) -> URL? {
        if let cached = trackedURLs[identifier] {
            return cached
        }
        guard let restored = readSidecar(for: identifier) else {
            return nil
        }
        trackedURLs[identifier] = restored
        return restored
    }

    private func sidecarFileURL(for identifier: String) -> URL? {
        guard let sidecarDirectory else { return nil }
        let data = Data(identifier.utf8)
        let hashData = data.sha256Hash()
        let hashString = hashData.map { String(format: "%02x", $0) }.joined()
        return sidecarDirectory.appendingPathComponent(hashString + ".url")
    }

    private func readSidecar(for identifier: String) -> URL? {
        guard let sidecarURL = sidecarFileURL(for: identifier),
              let data = try? Data(contentsOf: sidecarURL),
              let urlString = String(data: data, encoding: .utf8) else {
            return nil
        }
        return URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func writeSidecar(url: URL, for identifier: String) {
        guard let sidecarURL = sidecarFileURL(for: identifier) else { return }
        try? url.absoluteString.write(to: sidecarURL, atomically: true, encoding: .utf8)
    }

    private func deleteSidecar(for identifier: String) {
        guard let sidecarURL = sidecarFileURL(for: identifier) else { return }
        try? fileManager.removeItem(at: sidecarURL)
    }
}

// MARK: - Generic Image Cache

/// Smart reactive image cache that stores images for any ImageCacheable object with instant updates.
/// Supports three-tier caching: memory → disk → network
/// When a new image is uploaded for an object, all views showing that object update instantly.
///
/// @unchecked Sendable: Thread safety is ensured through:
/// - NSCache: Internally thread-safe for all operations
/// - diskCacheQueue: Serial DispatchQueue serializing all disk I/O
/// - cleanupLock: OSAllocatedUnfairLock coordinating cleanup task scheduling
/// - urlTracker: Actor isolation for URL tracking
/// - loadingTasksLock: OSAllocatedUnfairLock for network request deduplication
/// - cacheUpdateSubject/urlChangeSubject: Combine subjects are thread-safe for send/subscribe
/// All properties are immutable after init except for cleanup task coordination.
@Observable
public final class ImageCache: ImageCacheProtocol, @unchecked Sendable {
    public static var shared: any ImageCacheProtocol { ImageCacheContainer.shared }

    private let cache: NSCache<NSString, UIImage>

    // Disk cache properties
    private let diskCacheURL: URL
    private let persistentCacheURL: URL
    private let diskCacheQueue: DispatchQueue
    private let fileManager: FileManager
    private let maxDiskCacheSize: Int = CacheConfiguration.maxDiskCacheSize

    // Cleanup coordination
    private let cleanupLock: OSAllocatedUnfairLock<Task<Void, Never>?> = OSAllocatedUnfairLock(initialState: nil)

    // URL tracking for detecting URL changes. Sidecar directory is wired
    // in init() once diskCacheURL has been computed.
    private let urlTracker: URLTracker

    // Network request deduplication: tracks in-flight loading tasks by URL
    private let loadingTasksLock: OSAllocatedUnfairLock<[URL: Task<UIImage?, Never>]> = OSAllocatedUnfairLock(initialState: [:])

    /// Publisher for specific cache updates by identifier (kept for backward compatibility)
    private let cacheUpdateSubject: PassthroughSubject<String, Never> = PassthroughSubject<String, Never>()

    /// Publisher for URL change events
    private let urlChangeSubject: PassthroughSubject<ImageURLChange, Never> = PassthroughSubject<ImageURLChange, Never>()

    /// Publisher that emits when a specific cached image is updated (backward compatibility)
    public var cacheUpdates: AnyPublisher<String, Never> {
        cacheUpdateSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    /// Publisher that emits when an image URL changes for an identifier.
    ///
    /// - Important: **For testing only.** Do not use this for UI observation.
    ///   Use `cacheUpdates` instead, which emits when an image is cached and ready to display.
    ///   `urlChanges` only indicates the URL tracker was updated, not that the new image is available.
    internal var urlChanges: AnyPublisher<ImageURLChange, Never> {
        urlChangeSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    /// Check if the URL might have changed for an identifier (without updating tracker)
    /// Used by prefetcher to detect if it needs to re-fetch encrypted images
    /// Returns true if:
    /// - The URL differs from the tracked URL (actual change)
    /// - OR no URL is tracked for this identifier (cold start - need to verify)
    public func hasURLChanged(_ url: String?, for identifier: String) async -> Bool {
        guard let urlString = url, let parsedURL = URL(string: urlString) else {
            // URL is nil, changed if we had a previous URL
            return await urlTracker.url(for: identifier) != nil
        }
        let peek = await urlTracker.peek(parsedURL, for: identifier)
        return peek.changed  // Now includes cold start case since peek() returns changed:true when no entry exists
    }

    init() {
        cache = NSCache<NSString, UIImage>()
        cache.countLimit = CacheConfiguration.memoryCacheCountLimit
        cache.totalCostLimit = CacheConfiguration.memoryCacheTotalCostLimit

        // Setup disk cache
        fileManager = FileManager.default
        diskCacheQueue = DispatchQueue(label: "com.convos.imagecache.disk", qos: .utility)

        // Create evictable disk cache directory (Caches/ - iOS may purge under storage pressure)
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskCacheURL = cacheDir.appendingPathComponent("ImageCache", isDirectory: true)

        // Create persistent photo store (Application Support/ - not purged by iOS)
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        persistentCacheURL = appSupportDir.appendingPathComponent("PhotoStore", isDirectory: true)

        for dir in [diskCacheURL, persistentCacheURL] {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                Log.error("Failed to create directory \(dir.lastPathComponent): \(error)")
            }
        }

        // Co-locate URL sidecars in the same directory as the cached images
        // so eviction and removal stay in lockstep.
        urlTracker = URLTracker(sidecarDirectory: diskCacheURL, fileManager: fileManager)

        // Clean up disk cache on init if needed
        scheduleCleanupIfNeeded()
    }

    // MARK: - Primary API: Load with URL Tracking

    /// Load image for an ImageCacheable object, using its URL for fetching
    /// This is the primary API - handles memory → disk → network with URL tracking
    /// - Parameter object: The ImageCacheable object to load an image for
    /// - Returns: The loaded image, or nil if no URL or loading failed
    public func loadImage(for object: any ImageCacheable) async -> UIImage? {
        let identifier = object.imageCacheIdentifier

        guard let url = object.imageCacheURL else {
            // URL is nil - return cached image if available, don't clear
            // (Image might be locally staged for upload, or caller should use removeImage() explicitly)
            return await loadImageFromCache(identifier: identifier, source: "loadImage (nil URL)")
        }

        // Cache-first for both encrypted and unencrypted: serve any cached
        // image immediately and refresh in the background only when the URL
        // has drifted. The only path that blocks on the network is a true
        // cold cache (no memory, no disk). With sidecar-backed URL tracking
        // (see URLTracker), cold launches on previously-cached identifiers
        // report `changed: false` and don't schedule any refresh at all.
        let peek = await urlTracker.peek(url, for: identifier)

        if let memoryImage = cache.object(forKey: identifier as NSString) {
            if peek.changed {
                scheduleBackgroundRefresh(for: object, url: url, identifier: identifier)
            }
            return memoryImage
        }
        if let diskImage = await loadImageFromDisk(identifier: identifier, imageFormat: .jpg) {
            cacheImageInMemory(diskImage, key: identifier, cache: cache, logContext: "loadImage (from disk)")
            if peek.changed {
                scheduleBackgroundRefresh(for: object, url: url, identifier: identifier)
            }
            return diskImage
        }

        // Cold path: nothing in memory or on disk. Block on the network so
        // the caller gets the image rather than a placeholder. Interactive
        // priority: the UI is waiting on this fetch, so it must not queue
        // behind background sync's prefetch burst.
        if object.isEncryptedImage {
            return await fetchEncryptedImageInline(for: object, url: url, identifier: identifier, priority: .interactive)
        }
        if let networkImage = await fetchImageFromNetwork(url: url, identifier: identifier) {
            _ = await urlTracker.track(url, for: identifier)
            return networkImage
        }
        return nil
    }

    /// Fire-and-forget refresh used when a cache hit was served but the URL
    /// has drifted. Inline fetch helpers handle their own deduplication
    /// (loadingTasksLock for network, EncryptedImageLoader internally) and
    /// commit the new URL on success, so the new bytes propagate via
    /// `cacheUpdates`/`urlChanges` once the fetch completes — no UI delay.
    private func scheduleBackgroundRefresh(for object: any ImageCacheable, url: URL, identifier: String) {
        Task.detached(priority: .background) {
            if object.isEncryptedImage {
                _ = await self.fetchEncryptedImageInline(for: object, url: url, identifier: identifier, priority: .background)
                return
            }
            if await self.fetchImageFromNetwork(url: url, identifier: identifier) != nil {
                _ = await self.urlTracker.track(url, for: identifier)
            }
        }
    }

    private func loadImageFromCache(identifier: String, source: String) async -> UIImage? {
        if let memoryImage = cache.object(forKey: identifier as NSString) {
            return memoryImage
        }
        if let diskImage = await loadImageFromDisk(identifier: identifier, imageFormat: .jpg) {
            cacheImageInMemory(diskImage, key: identifier, cache: cache, logContext: source)
            return diskImage
        }
        return nil
    }

    // MARK: - Upload Support Methods

    /// Prepare an image for upload by resizing/compressing and caching it
    /// Call this before uploading to get the data, then call `cacheAfterUpload` when you know the final URL
    /// - Parameters:
    ///   - image: The original UIImage to prepare
    ///   - object: The ImageCacheable object this image is for
    /// - Returns: JPEG data ready for upload, or nil if compression fails
    public func prepareForUpload(_ image: UIImage, for object: any ImageCacheable) -> Data? {
        prepareForUpload(image, forIdentifier: object.imageCacheIdentifier)
    }

    /// Identifier-based variant of `prepareForUpload(_:for:)` for callers
    /// whose write key differs from the object's read identifier (see
    /// `Conversation.imageCacheWriteIdentifier`).
    public func prepareForUpload(_ image: UIImage, forIdentifier identifier: String) -> Data? {
        // Immediately set the cache so there is no delay showing in the UI
        cache.setObject(image, forKey: identifier as NSString, cost: memoryCost(for: image))

        // Resize and compress to JPEG
        guard let jpegData = ImageCompression.resizeAndCompressToJPEG(image, compressionQuality: 0.8) else {
            Log.error("Failed to prepare image for upload: \(identifier)")
            cache.removeObject(forKey: identifier as NSString)
            return nil
        }

        // Cache the resized image immediately (before upload completes)
        Task {
            guard let resizedImage = UIImage(data: jpegData) else {
                Log.error("Failed to create UIImage from compressed data: \(identifier)")
                return
            }

            let cost = memoryCost(for: resizedImage)
            cache.setObject(resizedImage, forKey: identifier as NSString, cost: cost)
            Log.debug("Cached image before upload: \(identifier)")

            // Save to disk
            await saveDataToDisk(jpegData, identifier: identifier, imageFormat: .jpg)

            // Notify
            cacheUpdateSubject.send(identifier)
        }

        return jpegData
    }

    /// Cache an image after upload completes, updating URL tracking
    /// Call this after upload succeeds with the final URL from the server
    ///
    /// - Note: This method does NOT save to disk because `prepareForUpload` already saved
    ///   the correctly compressed data. Re-compressing here would cause quality loss.
    ///
    /// - Parameters:
    ///   - image: The uploaded image (should already be cached from prepareForUpload)
    ///   - object: The ImageCacheable object this image is for
    ///   - url: The final URL where the image was uploaded
    public func cacheAfterUpload(_ image: UIImage, for object: any ImageCacheable, url: String) {
        let identifier = object.imageCacheIdentifier

        // Update URL tracking with the new URL
        Task {
            // Track URL (but don't fail if invalid - still cache the image)
            if let newURL = URL(string: url) {
                let tracking = await urlTracker.track(newURL, for: identifier)
                if tracking.changed {
                    urlChangeSubject.send(ImageURLChange(identifier: identifier, oldURL: tracking.oldURL, newURL: newURL))
                }
            } else {
                Log.error("Invalid URL for cacheAfterUpload: \(url), caching without URL tracking")
            }

            // Always cache and notify (even if URL was invalid)
            let cost = memoryCost(for: image)
            cache.setObject(image, forKey: identifier as NSString, cost: cost)

            cacheUpdateSubject.send(identifier)
            Log.debug("Updated URL tracking after upload: \(identifier) -> \(url)")
        }
    }

    /// Cache an image after fetching/decrypting, updating URL tracking
    /// Used by prefetchers that fetch encrypted images and need to emit urlChanges
    /// - Parameters:
    ///   - image: The decrypted image to cache
    ///   - identifier: The stable identifier for this image (e.g., conversationId, inboxId)
    ///   - url: The URL the image was fetched from (used for URL tracking)
    public func cacheAfterUpload(_ image: UIImage, for identifier: String, url: String) {
        // Update URL tracking with the new URL
        Task {
            // Track URL (but don't fail if invalid - still cache the image)
            if let newURL = URL(string: url) {
                let tracking = await urlTracker.track(newURL, for: identifier)
                if tracking.changed {
                    urlChangeSubject.send(ImageURLChange(identifier: identifier, oldURL: tracking.oldURL, newURL: newURL))
                    Log.debug("URL changed for \(identifier): \(tracking.oldURL?.absoluteString ?? "nil") -> \(url)")
                }
            } else {
                Log.error("Invalid URL for cacheAfterUpload: \(url), caching without URL tracking")
            }

            // Cache in memory
            let cost = memoryCost(for: image)
            cache.setObject(image, forKey: identifier as NSString, cost: cost)

            // Save to disk (force overwrite since we have a new image for this identifier)
            guard let jpegData = ImageCompression.resizeAndCompressToJPEG(image, compressionQuality: 0.8) else {
                Log.error("Failed to convert image to JPEG for disk cache: \(identifier)")
                cacheUpdateSubject.send(identifier)
                return
            }
            await saveDataToDisk(jpegData, identifier: identifier, imageFormat: .jpg, forceOverwrite: true)

            cacheUpdateSubject.send(identifier)
            Log.debug("Cached image after fetch: \(identifier) -> \(url)")
        }
    }

    /// Cache pre-compressed image data after fetching/decrypting
    /// Use this when you already have JPEG data to avoid re-compression quality loss
    /// - Parameters:
    ///   - imageData: Pre-compressed JPEG data
    ///   - identifier: The stable identifier for this image
    ///   - url: The URL the image was fetched from (used for URL tracking)
    public func cacheAfterUpload(_ imageData: Data, for identifier: String, url: String) {
        Task {
            // Track URL (but don't fail if invalid - still cache the image)
            if let newURL = URL(string: url) {
                let tracking = await urlTracker.track(newURL, for: identifier)
                if tracking.changed {
                    urlChangeSubject.send(ImageURLChange(identifier: identifier, oldURL: tracking.oldURL, newURL: newURL))
                }
            } else {
                Log.error("Invalid URL for cacheAfterUpload: \(url), caching without URL tracking")
            }

            // Create image from data for memory cache (bounded decode:
            // the data came off the network and is sender-controlled)
            guard let image = BoundedImageDecode.image(from: imageData) else {
                Log.error("Failed to create UIImage from data: \(identifier)")
                return
            }

            let cost = memoryCost(for: image)
            cache.setObject(image, forKey: identifier as NSString, cost: cost)

            // Save data directly to disk (no re-compression)
            await saveDataToDisk(imageData, identifier: identifier, imageFormat: .jpg, forceOverwrite: true)

            cacheUpdateSubject.send(identifier)
            Log.debug("Cached image data after fetch: \(identifier) -> \(url)")
        }
    }

    /// Fetch image from network with request deduplication
    /// Multiple calls for the same URL will share a single network request
    private func fetchImageFromNetwork(url: URL, identifier: String) async -> UIImage? {
        // Check if there's already an in-flight request for this URL
        let existingTask = loadingTasksLock.withLock { tasks in
            tasks[url]
        }

        if let existingTask {
            // Wait for existing request to complete
            return await existingTask.value
        }

        // Create new loading task
        let loadingTask = Task<UIImage?, Never> {
            defer {
                // Remove task when done
                _ = loadingTasksLock.withLock { tasks in
                    tasks.removeValue(forKey: url)
                }
            }

            do {
                // Stream to a temporary file so the encoded payload is never
                // fully buffered in memory, then decode with a bounded size.
                let (tempFileURL, response) = try await URLSession.shared.download(from: url)
                defer { try? FileManager.default.removeItem(at: tempFileURL) }

                // Validate response
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    Log.error("Failed to load image from URL: \(url) - invalid response")
                    return nil
                }

                guard let image = BoundedImageDecode.image(contentsOf: tempFileURL) else {
                    Log.error("Failed to decode image from URL: \(url)")
                    return nil
                }

                // Cache by identifier (not URL) - single entry per object
                cacheImage(image, key: identifier, cache: cache, logContext: "loadImage (from network)", imageFormat: .jpg)

                // Save to disk asynchronously
                Task {
                    await saveImageToDisk(image, identifier: identifier, imageFormat: .jpg)
                }

                // Emit cache update for backward compatibility
                cacheUpdateSubject.send(identifier)

                Log.debug("Successfully loaded image from network: \(identifier)")
                return image
            } catch {
                Log.error("Failed to load image from URL: \(url) - \(error)")
                return nil
            }
        }

        // Store task for deduplication
        loadingTasksLock.withLock { tasks in
            tasks[url] = loadingTask
        }

        return await loadingTask.value
    }

    /// Fetch and decrypt an encrypted image inline if all encryption parameters are available
    /// This is used for cold start scenarios where the prefetcher hasn't run yet
    private func fetchEncryptedImageInline(
        for object: any ImageCacheable,
        url: URL,
        identifier: String,
        priority: EncryptedImageFetchPriority
    ) async -> UIImage? {
        guard let key = object.encryptionKey,
              let salt = object.encryptionSalt,
              let nonce = object.encryptionNonce else {
            Log.debug("Cannot inline decrypt - missing encryption params for: \(identifier)")
            return nil
        }

        do {
            Log.debug("Attempting inline encrypted fetch for: \(identifier)")
            let decryptedData = try await EncryptedImageLoader.loadAndDecrypt(
                url: url,
                salt: salt,
                nonce: nonce,
                groupKey: key,
                priority: priority
            )

            guard let image = BoundedImageDecode.image(from: decryptedData) else {
                Log.error("Failed to create UIImage from decrypted data: \(identifier)")
                return nil
            }

            // Cache in memory
            cacheImage(image, key: identifier, cache: cache, logContext: "inline encrypted fetch", imageFormat: .jpg)

            // Update URL tracking since we successfully fetched
            let tracking = await urlTracker.track(url, for: identifier)
            if tracking.changed {
                urlChangeSubject.send(ImageURLChange(identifier: identifier, oldURL: tracking.oldURL, newURL: url))
            }

            // Save to disk asynchronously - use decryptedData directly to avoid double compression
            Task {
                await saveDataToDisk(decryptedData, identifier: identifier, imageFormat: .jpg, forceOverwrite: true)
            }

            cacheUpdateSubject.send(identifier)
            Log.debug("Successfully loaded encrypted image inline: \(identifier)")
            return image
        } catch {
            Log.error("Failed to inline decrypt image for \(identifier): \(error)")
            return nil
        }
    }

    // MARK: - Generic Cache Methods

    /// Get cached image for any ImageCacheable object (synchronous, memory only)
    public func image(for object: any ImageCacheable) -> UIImage? {
        return cache.object(forKey: object.imageCacheIdentifier as NSString)
    }

    /// Get cached image for any ImageCacheable object (async, checks memory → disk)
    public func imageAsync(for object: any ImageCacheable) async -> UIImage? {
        let identifier = object.imageCacheIdentifier

        // Check memory first
        if let memoryImage = cache.object(forKey: identifier as NSString) {
            return memoryImage
        }

        // Check disk (default to JPEG for object-based cache)
        if let diskImage = await loadImageFromDisk(identifier: identifier, imageFormat: .jpg) {
            // Populate memory cache (image is already compressed/resized from disk)
            cacheImageInMemory(diskImage, key: identifier, cache: cache, logContext: "Object cache (from disk)")
            return diskImage
        }

        return nil
    }

    /// Remove cached image for any ImageCacheable object (removes from both memory and disk)
    public func removeImage(for object: any ImageCacheable) {
        let identifier = object.imageCacheIdentifier
        cache.removeObject(forKey: identifier as NSString)

        // Remove from disk asynchronously
        Task {
            await removeImageFromDisk(identifier: identifier)
        }

        cacheUpdateSubject.send(identifier)
    }

    // MARK: - Identifier-based Methods

    /// Get cached image by identifier (synchronous, memory only)
    public func image(for identifier: String, imageFormat: ImageFormat = .jpg) -> UIImage? {
        return cache.object(forKey: identifier as NSString)
    }

    /// Get cached image by identifier (async, checks memory → disk)
    public func imageAsync(for identifier: String, imageFormat: ImageFormat = .jpg) async -> UIImage? {
        // Check memory first
        if let memoryImage = cache.object(forKey: identifier as NSString) {
            return memoryImage
        }

        // Check disk
        if let diskImage = await loadImageFromDisk(identifier: identifier, imageFormat: imageFormat) {
            // Populate memory cache (image is already compressed/resized from disk)
            cacheImageInMemory(diskImage, key: identifier, cache: cache, logContext: "Identifier cache (from disk)")
            return diskImage
        }

        return nil
    }

    /// Cache image by identifier (saves to both memory and disk)
    public func cacheImage(_ image: UIImage, for identifier: String, imageFormat: ImageFormat = .jpg) {
        cacheImage(image, key: identifier, cache: cache, logContext: "Identifier cache", imageFormat: imageFormat)

        // Save to disk asynchronously
        Task {
            await saveImageToDisk(image, identifier: identifier, imageFormat: imageFormat)
        }

        cacheUpdateSubject.send(identifier)
    }

    /// Remove cached image by identifier (removes from both memory and disk)
    public func removeImage(for identifier: String) {
        cache.removeObject(forKey: identifier as NSString)

        // Remove from disk asynchronously
        Task {
            await removeImageFromDisk(identifier: identifier)
        }

        cacheUpdateSubject.send(identifier)
    }

    // MARK: - Persistent Storage (chat photo attachments)

    public func cacheData(_ data: Data, for identifier: String, storageTier: ImageStorageTier) {
        guard let image = BoundedImageDecode.image(from: data) else {
            Log.error("Failed to create UIImage from data for persistent cache: \(identifier)")
            return
        }
        let cost = memoryCost(for: image)
        cache.setObject(image, forKey: identifier as NSString, cost: cost)

        Task {
            await saveDataToDisk(data, identifier: identifier, storageTier: storageTier)
        }

        cacheUpdateSubject.send(identifier)
    }

    public func cacheImage(_ image: UIImage, for identifier: String, storageTier: ImageStorageTier) {
        let cost = memoryCost(for: image)
        cache.setObject(image, forKey: identifier as NSString, cost: cost)

        Task {
            await saveImageToDisk(image, identifier: identifier, storageTier: storageTier)
        }

        cacheUpdateSubject.send(identifier)
    }

    public func removePersistentImages(for identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        for identifier in identifiers {
            cache.removeObject(forKey: identifier as NSString)
        }
        Task {
            await performDiskOperation { cache in
                for identifier in identifiers {
                    for ext in [".jpg", ".png"] {
                        let fileURL = cache.persistentCacheURL.appendingPathComponent(
                            cache.sanitizedFilename(for: identifier, fileExtension: ext)
                        )
                        guard cache.fileManager.fileExists(atPath: fileURL.path) else { continue }
                        do {
                            try cache.fileManager.removeItem(at: fileURL)
                        } catch {
                            Log.error("Failed to remove persistent image: \(identifier) - \(error)")
                        }
                    }
                }
            }
        }
    }

    public func removeAllPersistentImages() {
        cache.removeAllObjects()
        Task {
            await performDiskOperation { cache in
                guard let contents = try? cache.fileManager.contentsOfDirectory(
                    at: cache.persistentCacheURL, includingPropertiesForKeys: nil
                ) else { return }
                for fileURL in contents {
                    do { try cache.fileManager.removeItem(at: fileURL) } catch {
                        Log.error("Failed to remove persistent image: \(fileURL.lastPathComponent) - \(error)")
                    }
                }
                Log.info("Removed all persistent images (\(contents.count) files)")
            }
        }
    }

    // MARK: - Disk Cache Helpers

    /// Perform an operation on the disk cache queue with proper weak self handling
    private func performDiskOperation<T: Sendable>(
        default defaultValue: T,
        _ operation: @Sendable @escaping (ImageCache) -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            diskCacheQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: defaultValue)
                    return
                }
                continuation.resume(returning: operation(self))
            }
        }
    }

    /// Perform a void operation on the disk cache queue with proper weak self handling
    private func performDiskOperation(
        _ operation: @Sendable @escaping (ImageCache) -> Void
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            diskCacheQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                operation(self)
                continuation.resume()
            }
        }
    }

    // MARK: - Disk Cache Methods

    /// Load image from disk cache
    private func loadImageFromDisk(identifier: String, imageFormat: ImageFormat) async -> UIImage? {
        let filename = sanitizedFilename(for: identifier, fileExtension: imageFormat.fileExtension)
        let persistentURL = persistentCacheURL.appendingPathComponent(filename)
        let cacheURL = diskCacheURL.appendingPathComponent(filename)

        // Only the existence checks and access-date touches run on the serial
        // disk queue; decodes run on the caller's task so concurrent loads
        // (e.g. a screenful of avatars) don't serialize their decodes behind
        // one another.
        let existingFileURLs: [URL] = await performDiskOperation(default: []) { cache in
            var existing: [URL] = []
            for fileURL in [persistentURL, cacheURL] {
                guard cache.fileManager.fileExists(atPath: fileURL.path) else { continue }
                var mutableURL = fileURL
                var resourceValues = URLResourceValues()
                resourceValues.contentAccessDate = Date()
                try? mutableURL.setResourceValues(resourceValues)
                existing.append(fileURL)
            }
            return existing
        }

        // Decode straight from the file (bounded) instead of reading the
        // encoded bytes into memory first. The bound matters here too:
        // persistent-tier files store the original sender-controlled payload.
        for fileURL in existingFileURLs {
            guard let image = BoundedImageDecode.image(contentsOf: fileURL) else {
                Log.error("Failed to decode image from disk: \(identifier)")
                continue
            }
            return image
        }
        return nil
    }

    private func directoryURL(for tier: ImageStorageTier) -> URL {
        switch tier {
        case .cache: return diskCacheURL
        case .persistent: return persistentCacheURL
        }
    }

    /// Save pre-compressed data directly to disk (avoids double compression)
    private func saveDataToDisk(
        _ data: Data,
        identifier: String,
        imageFormat: ImageFormat = .jpg,
        forceOverwrite: Bool = false,
        storageTier: ImageStorageTier = .cache
    ) async {
        let dir = directoryURL(for: storageTier)
        let fileURL = dir.appendingPathComponent(sanitizedFilename(for: identifier, fileExtension: imageFormat.fileExtension))

        await performDiskOperation { cache in
            if !forceOverwrite && cache.fileManager.fileExists(atPath: fileURL.path) {
                return
            }

            do {
                try data.write(to: fileURL, options: .atomic)
                if storageTier == .cache {
                    cache.scheduleCleanupIfNeeded()
                }
            } catch {
                Log.error("Failed to save image data to disk: \(identifier) - \(error)")
            }
        }
    }

    /// Save image to disk
    private func saveImageToDisk(
        _ image: UIImage,
        identifier: String,
        imageFormat: ImageFormat = .jpg,
        forceOverwrite: Bool = false,
        storageTier: ImageStorageTier = .cache
    ) async {
        await performDiskOperation { cache in
            let dir = cache.directoryURL(for: storageTier)
            let fileURL = dir.appendingPathComponent(cache.sanitizedFilename(for: identifier, fileExtension: imageFormat.fileExtension))

            if !forceOverwrite && cache.fileManager.fileExists(atPath: fileURL.path) {
                return
            }

            let data: Data? = switch imageFormat {
            case .png: ImageCompression.resizeAndCompressToPNG(image)
            case .jpg: ImageCompression.resizeAndCompressToJPEG(image, compressionQuality: 0.8)
            }

            guard let imageData = data else {
                Log.error("Failed to resize and compress image for disk: \(identifier)")
                return
            }

            do {
                try imageData.write(to: fileURL, options: .atomic)
                if storageTier == .cache {
                    cache.scheduleCleanupIfNeeded()
                }
            } catch {
                Log.error("Failed to save image to disk: \(identifier) - \(error)")
            }
        }
    }

    /// Remove image from both disk cache and persistent store, plus the
    /// `.url` sidecar that the URL tracker writes alongside cached images.
    private func removeImageFromDisk(identifier: String) async {
        let filename = sanitizedFilename(for: identifier, fileExtension: ".jpg")
        let pngFilename = sanitizedFilename(for: identifier, fileExtension: ".png")
        let sidecarFilename = sanitizedFilename(for: identifier, fileExtension: ".url")

        await performDiskOperation { cache in
            let urls = [
                cache.diskCacheURL.appendingPathComponent(filename),
                cache.diskCacheURL.appendingPathComponent(pngFilename),
                cache.diskCacheURL.appendingPathComponent(sidecarFilename),
                cache.persistentCacheURL.appendingPathComponent(filename),
                cache.persistentCacheURL.appendingPathComponent(pngFilename),
            ]
            for url in urls where cache.fileManager.fileExists(atPath: url.path) {
                do {
                    try cache.fileManager.removeItem(at: url)
                } catch {
                    if (error as NSError).code != NSFileNoSuchFileError {
                        Log.error("Failed to remove image from disk: \(url.lastPathComponent) - \(error)")
                    }
                }
            }
        }
    }

    /// Schedule cleanup if not already scheduled (coalesces multiple concurrent requests)
    private func scheduleCleanupIfNeeded() {
        _ = cleanupLock.withLock { (task: inout Task<Void, Never>?) -> Task<Void, Never>? in
            guard task == nil else { return task }

            task = Task {
                await cleanupDiskCacheIfNeeded()
                // Clear the task when done
                _ = cleanupLock.withLock { (t: inout Task<Void, Never>?) -> Task<Void, Never>? in
                    t = nil
                    return nil
                }
            }

            return task
        }
    }

    /// Clean up disk cache if it exceeds size limit (LRU - removes oldest accessed files)
    /// Processes files in batches to avoid memory pressure with large caches
    private func cleanupDiskCacheIfNeeded() async {
        struct CachedFileInfo {
            let url: URL
            let size: Int
            let date: Date
        }

        await performDiskOperation { cache in
            do {
                let resourceKeys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey]
                let fileURLs = try cache.fileManager.contentsOfDirectory(
                    at: cache.diskCacheURL,
                    includingPropertiesForKeys: resourceKeys,
                    options: .skipsHiddenFiles
                )

                // Skip .url sidecars (URLTracker metadata) from the LRU
                // accounting and eviction list. They share their hash
                // basename with an image file; pairing is enforced below by
                // co-deleting the matching .url when we evict an image, so
                // image and sidecar lifetimes stay in lockstep. Sidecars
                // are ~50 bytes and accessed less frequently than their
                // image, so including them in the LRU sort would falsely
                // mark them as oldest and split pairs.
                let evictableURLs = fileURLs.filter { $0.pathExtension != "url" }

                let batchSize = 100
                var totalSize = 0
                var batch: [CachedFileInfo] = []
                batch.reserveCapacity(batchSize)

                for i in stride(from: 0, to: evictableURLs.count, by: batchSize) {
                    let endIndex = min(i + batchSize, evictableURLs.count)
                    batch.removeAll(keepingCapacity: true)

                    for j in i..<endIndex {
                        let fileURL = evictableURLs[j]
                        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                        totalSize += resourceValues.fileSize ?? 0
                    }
                }

                if totalSize > cache.maxDiskCacheSize {
                    var oldestFiles: [CachedFileInfo] = []

                    for i in stride(from: 0, to: evictableURLs.count, by: batchSize) {
                        let endIndex = min(i + batchSize, evictableURLs.count)
                        batch.removeAll(keepingCapacity: true)

                        for j in i..<endIndex {
                            let fileURL = evictableURLs[j]
                            let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                            batch.append(CachedFileInfo(
                                url: fileURL,
                                size: resourceValues.fileSize ?? 0,
                                date: resourceValues.contentAccessDate ?? Date.distantPast
                            ))
                        }
                        oldestFiles.append(contentsOf: batch)
                    }

                    oldestFiles.sort { $0.date < $1.date }

                    var removedSize = 0
                    for file in oldestFiles {
                        guard totalSize - removedSize > cache.maxDiskCacheSize else { break }

                        do {
                            try cache.fileManager.removeItem(at: file.url)
                            // Pair: also remove the .url sidecar with the
                            // same hash basename so URLTracker doesn't
                            // hold stale URL state for an evicted image.
                            let sidecarURL = file.url
                                .deletingPathExtension()
                                .appendingPathExtension("url")
                            try? cache.fileManager.removeItem(at: sidecarURL)
                            removedSize += file.size
                            Log.debug("Removed old cached image from disk: \(file.url.lastPathComponent)")
                        } catch {
                            Log.error("Failed to remove cached image: \(file.url.lastPathComponent) - \(error)")
                        }
                    }

                    Log.debug("Disk cache cleanup: removed \(removedSize) bytes")
                }
            } catch {
                Log.error("Failed to cleanup disk cache: \(error)")
            }
        }
    }

    /// Sanitize identifier to create a valid filename
    /// - Parameters:
    ///   - identifier: The cache identifier
    ///   - extension: File extension (default: ".jpg")
    /// - Returns: Sanitized filename with extension
    private func sanitizedFilename(for identifier: String, fileExtension: String = ".jpg") -> String {
        // Use SHA256 hash for consistent, filesystem-safe filenames
        let data = Data(identifier.utf8)
        let hashData = data.sha256Hash()
        let hashString = hashData.map { String(format: "%02x", $0) }.joined()
        return hashString + fileExtension
    }

    // MARK: - Private Methods

    /// Calculates memory cost in bytes for an image based on pixel dimensions
    /// Uses CGImage pixel dimensions (not UIImage point dimensions) to account for scale factor
    /// - Parameter image: The UIImage to calculate cost for
    /// - Returns: Memory cost in bytes (width * height * 4 bytes per pixel for RGBA)
    private func memoryCost(for image: UIImage) -> Int {
        guard let cgImage = image.cgImage else {
            // Fallback to point-based calculation if CGImage is unavailable
            // Account for scale factor to get pixel dimensions (scale^2 for area)
            let scale = image.scale > 0 ? image.scale : 1.0
            return Int(image.size.width * image.size.height * scale * scale * 4)
        }
        // Use pixel dimensions (accounts for scale factor: 1x, 2x, 3x)
        return cgImage.width * cgImage.height * 4
    }

    /// Cache image in memory without compression (for images already processed, e.g., loaded from disk)
    private func cacheImageInMemory(_ image: UIImage, key: String, cache: NSCache<NSString, UIImage>, logContext: String) {
        guard image.size.width > 0 && image.size.height > 0 else {
            Log.error("Invalid image dimensions for \(logContext): \(key)")
            return
        }

        let cost = memoryCost(for: image)
        cache.setObject(image, forKey: key as NSString, cost: cost)
        Log.debug("Successfully cached image for \(logContext): \(key)")
    }

    /// Resize, compress, and cache image in memory (for new/original images)
    private func cacheImage(_ image: UIImage, key: String, cache: NSCache<NSString, UIImage>, logContext: String, imageFormat: ImageFormat = .jpg) {
        let compressedData: Data?
        switch imageFormat {
        case .png:
            compressedData = ImageCompression.resizeAndCompressToPNG(image)
        case .jpg:
            compressedData = ImageCompression.resizeAndCompressToJPEG(image, compressionQuality: 0.8)
        }

        guard let imageData = compressedData else {
            Log.error("Failed to resize and compress image for \(logContext): \(key)")
            return
        }

        guard let resizedImage = UIImage(data: imageData) else {
            Log.error("Failed to create UIImage from compressed data for \(logContext): \(key)")
            return
        }

        guard resizedImage.size.width > 0 && resizedImage.size.height > 0 else {
            Log.error("Failed to resize image for \(logContext): \(key) - invalid dimensions")
            return
        }

        let cost = memoryCost(for: resizedImage)
        cache.setObject(resizedImage, forKey: key as NSString, cost: cost)
        let formatName = imageFormat == .png ? "PNG" : "JPEG"
        Log.debug("Successfully cached resized image for \(logContext): \(key) (format: \(formatName))")
    }

    // MARK: - Testing Support

    /// Track a URL for an identifier without requiring an image.
    /// This is used by platform-independent tests to set up URL tracking state.
    /// - Parameters:
    ///   - url: The URL to track
    ///   - identifier: The identifier to associate with the URL
    internal func trackURLForTesting(_ url: URL, for identifier: String) async {
        _ = await urlTracker.track(url, for: identifier)
    }
}

// MARK: - SwiftUI View Extension for Easy Image Cache Integration

private struct ImageCacheTaskID: Hashable {
    let identifier: String
    let url: URL?
}

public extension View {
    /// Complete image caching solution: loads image and observes URL changes
    /// Handles memory → disk → network loading with automatic URL change detection
    ///
    /// Usage:
    /// ```swift
    /// @State private var cachedImage: UIImage?
    ///
    /// Image(uiImage: cachedImage ?? placeholder)
    ///     .cachedImage(for: profile, into: $cachedImage)
    /// ```
    ///
    /// - Parameters:
    ///   - object: The ImageCacheable object to load an image for
    ///   - binding: Binding to store the loaded image
    /// - Returns: A view with image loading and observation attached
    func cachedImage(
        for object: any ImageCacheable,
        into binding: Binding<UIImage?>
    ) -> some View {
        self
            .onAppear {
                // Check memory cache synchronously for instant display (no flicker)
                binding.wrappedValue = ImageCache.shared.image(for: object)
            }
            .task(id: ImageCacheTaskID(identifier: object.imageCacheIdentifier, url: object.imageCacheURL)) {
                // Then load from disk/network if needed
                binding.wrappedValue = await ImageCache.shared.loadImage(for: object)
            }
            .onReceive(
                ImageCache.shared.cacheUpdates
                    .filter { $0 == object.imageCacheIdentifier }
            ) { _ in
                Task {
                    binding.wrappedValue = await ImageCache.shared.loadImage(for: object)
                }
            }
    }

    /// Modifier that subscribes to image cache updates for a specific ImageCacheable object
    /// (Backward compatibility - prefer `cachedImage(for:into:)` for new code)
    func cachedImage(
        for object: any ImageCacheable,
        onChange: @escaping (UIImage?) -> Void
    ) -> some View {
        self
            .onAppear {
                // Load initial cached image
                let image = ImageCache.shared.image(for: object)
                onChange(image)
            }
            .onReceive(
                ImageCache.shared.cacheUpdates
                    .filter { $0 == object.imageCacheIdentifier }
            ) { _ in
                // Update when this specific object's image changes
                let image = ImageCache.shared.image(for: object)
                onChange(image)
            }
    }
}

#endif
