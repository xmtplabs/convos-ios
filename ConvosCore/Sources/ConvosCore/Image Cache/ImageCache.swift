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
///
/// An object carries two keys: `imageCacheURL` (the authoritative content key -
/// the byte cache stores `url -> bytes`) and `imageCacheIdentifier` (the stable
/// identity key - used only for the read-only continuity hint). Callers pass the
/// object; the cache resolves truth by URL and continuity by identity.
public protocol ImageCacheable: Sendable {
    /// Stable identity key, used only for the continuity hint (last-shown image).
    var imageCacheIdentifier: String { get }

    /// The current image URL for this object (nil if no image or not URL-based).
    /// This is the authoritative byte-cache key.
    var imageCacheURL: URL? { get }

    /// Whether the image at the URL is encrypted and requires decryption
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

// MARK: - Generic Image Cache

/// Reactive image cache split into two responsibilities:
///
/// 1. **Authoritative byte cache** - keyed by image URL, immutable. `url -> bytes`
///    is a pure function (a URL pairs with one encryption key and decrypts to the
///    same bytes), so two URLs are two independent entries and there is no shared
///    identity slot for callers to clobber.
/// 2. **Read-only continuity hint** - `identity -> last-shown image`, disk-backed.
///    Consulted only as the placeholder while the current URL is being fetched.
///    Written when an image successfully displays/resolves for an identity. It
///    never triggers a fetch and never decides the canonical URL.
///
/// @unchecked Sendable: thread safety via NSCache (internally thread-safe), the
/// serial `diskCacheQueue`, `OSAllocatedUnfairLock`s for cleanup coordination,
/// network dedup, and the in-memory continuity hint, and the thread-safe Combine
/// subject. All other properties are immutable after init.
@Observable
public final class ImageCache: ImageCacheProtocol, @unchecked Sendable {
    public static var shared: any ImageCacheProtocol { ImageCacheContainer.shared }

    private let cache: NSCache<NSString, UIImage>

    // Disk cache directories
    private let diskCacheURL: URL
    private let persistentCacheURL: URL
    private let lastShownCacheURL: URL
    private let diskCacheQueue: DispatchQueue
    private let fileManager: FileManager
    private let maxDiskCacheSize: Int = CacheConfiguration.maxDiskCacheSize

    // Cleanup coordination
    private let cleanupLock: OSAllocatedUnfairLock<Task<Void, Never>?> = OSAllocatedUnfairLock(initialState: nil)

    // Network request deduplication: tracks in-flight loading tasks by URL
    private let loadingTasksLock: OSAllocatedUnfairLock<[URL: Task<UIImage?, Never>]> = OSAllocatedUnfairLock(initialState: [:])

    // Read-only continuity hint: identity -> last-shown image (in-memory).
    // `uncheckedState` because UIImage is not Sendable; access is serialized by
    // the lock and the surrounding @unchecked Sendable contract.
    private let lastShownLock: OSAllocatedUnfairLock<[String: UIImage]> = OSAllocatedUnfairLock(uncheckedState: [:])

    // Pending pre-upload images: identity -> staged image, for objects whose
    // imageCacheURL is still nil (e.g. an invite or avatar mid-upload). Kept
    // separate from the continuity hint so a nil URL only ever shows an
    // explicitly staged image, never a stale leftover (a cleared avatar must
    // show the placeholder, not its old picture).
    private let stagedLock: OSAllocatedUnfairLock<[String: UIImage]> = OSAllocatedUnfairLock(uncheckedState: [:])

    /// Publisher that emits a cache key when new bytes are ready for it. The key
    /// is either an image URL (byte-cache write) or an identity (continuity-hint
    /// write, e.g. pre-upload staging). Views filter on both their URL and their
    /// identity.
    private let cacheUpdateSubject: PassthroughSubject<String, Never> = PassthroughSubject<String, Never>()

    public var cacheUpdates: AnyPublisher<String, Never> {
        cacheUpdateSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    /// Publish a byte-cache update under both keys so listeners that filter on
    /// the URL (the `.cachedImage` modifier) and those that filter on the object
    /// identity (e.g. `ConversationViewModel` filtering by `imageCacheIdentifier`)
    /// both fire.
    private func publishCacheUpdate(urlKey: String, identifier: String) {
        cacheUpdateSubject.send(urlKey)
        if identifier != urlKey {
            cacheUpdateSubject.send(identifier)
        }
    }

    init() {
        cache = NSCache<NSString, UIImage>()
        cache.countLimit = CacheConfiguration.memoryCacheCountLimit
        cache.totalCostLimit = CacheConfiguration.memoryCacheTotalCostLimit

        fileManager = FileManager.default
        diskCacheQueue = DispatchQueue(label: "com.convos.imagecache.disk", qos: .utility)

        // Evictable byte cache (Caches/ - iOS may purge under storage pressure)
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskCacheURL = cacheDir.appendingPathComponent("ImageCache", isDirectory: true)

        // Continuity hints (small thumbnails, identity-keyed). Kept in a separate
        // directory so the byte-cache LRU never evicts them.
        lastShownCacheURL = cacheDir.appendingPathComponent("ImageCacheLastShown", isDirectory: true)

        // Persistent photo store (Application Support/ - not purged by iOS)
        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        persistentCacheURL = appSupportDir.appendingPathComponent("PhotoStore", isDirectory: true)

        for dir in [diskCacheURL, persistentCacheURL, lastShownCacheURL] {
            do {
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                Log.error("Failed to create directory \(dir.lastPathComponent): \(error)")
            }
        }

        scheduleCleanupIfNeeded()
    }

    // MARK: - Primary API (object-based, URL-keyed)

    /// Synchronous best-available image: the byte cache for the object's URL if
    /// present, otherwise the in-memory continuity hint for the object's identity.
    /// Used for instant display; the hint may be a slightly stale bridge.
    public func image(for object: any ImageCacheable) -> UIImage? {
        // A nil URL means "no image yet": show an explicitly staged pre-upload
        // image if one exists, but never a stale continuity hint (so a cleared
        // or never-set avatar shows the placeholder).
        guard let url = object.imageCacheURL else {
            return stagedInMemory(for: object.imageCacheIdentifier)
        }
        if let memoryImage = cache.object(forKey: url.absoluteString as NSString) {
            rememberLastShown(memoryImage, for: object.imageCacheIdentifier, persist: false)
            return memoryImage
        }
        // Non-nil URL not cached yet: bridge with the continuity hint.
        return lastShownInMemory(for: object.imageCacheIdentifier)
    }

    /// Continuity placeholder for an identity (memory hint, then disk hint).
    /// Never fetches the network. Used by the view modifier to bridge a fresh
    /// render while the authoritative URL is being resolved.
    public func continuityImage(for object: any ImageCacheable) async -> UIImage? {
        // A nil URL: show only an explicitly staged pre-upload image, never the
        // continuity hint (so a cleared avatar shows the placeholder).
        guard object.imageCacheURL != nil else {
            return stagedInMemory(for: object.imageCacheIdentifier)
        }
        if let memory = lastShownInMemory(for: object.imageCacheIdentifier) {
            return memory
        }
        return await loadLastShownFromDisk(for: object.imageCacheIdentifier)
    }

    /// Authoritative resolve: URL-keyed memory -> disk -> network/decrypt.
    public func loadImage(for object: any ImageCacheable) async -> UIImage? {
        // A nil URL: only an explicitly staged pre-upload image, nothing else.
        guard let url = object.imageCacheURL else {
            return stagedInMemory(for: object.imageCacheIdentifier)
        }
        let urlKey = url.absoluteString
        let identifier = object.imageCacheIdentifier

        if let memoryImage = cache.object(forKey: urlKey as NSString) {
            rememberLastShown(memoryImage, for: identifier, persist: false)
            return memoryImage
        }
        if let diskImage = await loadImageFromDisk(key: urlKey, imageFormat: .jpg) {
            cacheImageInMemory(diskImage, key: urlKey, cache: cache, logContext: "loadImage (from disk)")
            rememberLastShown(diskImage, for: identifier, persist: false)
            return diskImage
        }

        // Cold path: nothing in memory or on disk. Block on the network so the
        // caller gets the image rather than a placeholder.
        if object.isEncryptedImage {
            return await fetchEncryptedImageInline(for: object, url: url, urlKey: urlKey, identifier: identifier, priority: .interactive)
        }
        return await fetchImageFromNetwork(url: url, urlKey: urlKey, identifier: identifier)
    }

    /// Authoritative resolve with a placeholder bridge: the real image if it can
    /// be fetched, otherwise the continuity hint so a failed fetch keeps showing
    /// the last image instead of blanking. Use when `loadImage` is the sole image
    /// source (no `.cachedImage` modifier layering the bridge). A removed avatar
    /// (nil URL) still resolves to nil, since `continuityImage` returns only the
    /// staged image for a nil URL, not the hint.
    public func loadImageOrContinuity(for object: any ImageCacheable) async -> UIImage? {
        if let resolved = await loadImage(for: object) {
            return resolved
        }
        return await continuityImage(for: object)
    }

    /// Get cached image for an object (async, checks memory -> disk). Unlike
    /// `image(for:)` this does NOT fall back to the continuity hint - it answers
    /// "are the real bytes cached?" (used by the prefetcher).
    public func imageAsync(for object: any ImageCacheable) async -> UIImage? {
        guard let url = object.imageCacheURL else { return nil }
        let urlKey = url.absoluteString
        if let memoryImage = cache.object(forKey: urlKey as NSString) {
            return memoryImage
        }
        if let diskImage = await loadImageFromDisk(key: urlKey, imageFormat: .jpg) {
            cacheImageInMemory(diskImage, key: urlKey, cache: cache, logContext: "Object cache (from disk)")
            return diskImage
        }
        return nil
    }

    /// Probe the URL-keyed byte cache directly (memory -> disk) when you have the
    /// image URL but no `ImageCacheable` object. Matches the key `cacheAfterUpload`
    /// writes under, so a background prefetch can dedup before re-fetching. Does
    /// not fall back to the continuity hint and never touches the network.
    public func imageAsync(forURL url: String) async -> UIImage? {
        if let memoryImage = cache.object(forKey: url as NSString) {
            return memoryImage
        }
        if let diskImage = await loadImageFromDisk(key: url, imageFormat: .jpg) {
            cacheImageInMemory(diskImage, key: url, cache: cache, logContext: "URL cache (from disk)")
            return diskImage
        }
        return nil
    }

    /// Remove the byte-cache entry for the object's URL, and clear its continuity
    /// hint (explicit removal should not keep bridging to the old image).
    public func removeImage(for object: any ImageCacheable) {
        let identifier = object.imageCacheIdentifier
        if let url = object.imageCacheURL {
            let urlKey = url.absoluteString
            cache.removeObject(forKey: urlKey as NSString)
            Task { await removeImageFromDisk(key: urlKey) }
            cacheUpdateSubject.send(urlKey)
        }
        clearStaged(for: identifier)
        clearLastShown(for: identifier)
        cacheUpdateSubject.send(identifier)
    }

    // MARK: - Upload Support

    /// Prepare an image for upload by resizing/compressing. There is no URL yet,
    /// so the picked image is staged into the continuity hint for the identity so
    /// the owner sees it immediately; the byte-cache entry is created later by
    /// `cacheAfterUpload` once the URL is known.
    public func prepareForUpload(_ image: UIImage, for object: any ImageCacheable) -> Data? {
        prepareForUpload(image, forIdentifier: object.imageCacheIdentifier)
    }

    /// Identifier-based variant of `prepareForUpload(_:for:)`.
    public func prepareForUpload(_ image: UIImage, forIdentifier identifier: String) -> Data? {
        guard let jpegData = ImageCompression.resizeAndCompressToJPEG(image, compressionQuality: 0.8) else {
            Log.error("Failed to prepare image for upload: \(identifier)")
            return nil
        }
        let stagedImage = UIImage(data: jpegData) ?? image
        rememberStaged(stagedImage, for: identifier)
        cacheUpdateSubject.send(identifier)
        return jpegData
    }

    /// Cache an image after upload completes, keyed by its final URL. `url` must
    /// be a real URL: the byte cache is content-addressed by it. Callers that have
    /// no URL yet (a pre-upload preview) should use `prepareForUpload` to stage by
    /// identity instead - a non-URL string here is dropped, since nothing reads it.
    public func cacheAfterUpload(_ image: UIImage, for object: any ImageCacheable, url: String) {
        cacheAfterUpload(image, for: object.imageCacheIdentifier, url: url)
    }

    /// Cache an image (recompressing to JPEG) under its URL key, updating the
    /// continuity hint for the identity.
    public func cacheAfterUpload(_ image: UIImage, for identifier: String, url: String) {
        guard let parsedURL = URL(string: url) else {
            Log.error("Invalid URL for cacheAfterUpload: \(url)")
            return
        }
        let urlKey = parsedURL.absoluteString
        Task {
            let cost = memoryCost(for: image)
            cache.setObject(image, forKey: urlKey as NSString, cost: cost)
            rememberLastShown(image, for: identifier, persist: true)
            // The real upload supersedes the pre-upload staged image; clear it so
            // a later nil URL falls through to the placeholder, not the stale stage.
            clearStaged(for: identifier)

            guard let jpegData = ImageCompression.resizeAndCompressToJPEG(image, compressionQuality: 0.8) else {
                Log.error("Failed to convert image to JPEG for disk cache: \(urlKey)")
                publishCacheUpdate(urlKey: urlKey, identifier: identifier)
                return
            }
            await saveDataToDisk(jpegData, key: urlKey, imageFormat: .jpg, forceOverwrite: true)
            publishCacheUpdate(urlKey: urlKey, identifier: identifier)
        }
    }

    /// Cache pre-compressed image data (no re-compression) under its URL key.
    public func cacheAfterUpload(_ imageData: Data, for identifier: String, url: String) {
        guard let parsedURL = URL(string: url) else {
            Log.error("Invalid URL for cacheAfterUpload: \(url)")
            return
        }
        let urlKey = parsedURL.absoluteString
        Task {
            guard let image = BoundedImageDecode.image(from: imageData) else {
                Log.error("Failed to create UIImage from data: \(urlKey)")
                return
            }
            let cost = memoryCost(for: image)
            cache.setObject(image, forKey: urlKey as NSString, cost: cost)
            rememberLastShown(image, for: identifier, persist: true)
            // The real upload supersedes the pre-upload staged image; clear it so
            // a later nil URL falls through to the placeholder, not the stale stage.
            clearStaged(for: identifier)
            await saveDataToDisk(imageData, key: urlKey, imageFormat: .jpg, forceOverwrite: true)
            publishCacheUpdate(urlKey: urlKey, identifier: identifier)
        }
    }

    // MARK: - Network / decrypt fetch (URL-keyed)

    private func fetchImageFromNetwork(url: URL, urlKey: String, identifier: String) async -> UIImage? {
        let existingTask = loadingTasksLock.withLock { tasks in tasks[url] }
        if let existingTask {
            let image = await existingTask.value
            if let image {
                // The shared task only recorded the continuity hint for the first
                // caller's identity; record it for this caller too so its own
                // placeholder bridge survives the next render/relaunch.
                rememberLastShown(image, for: identifier, persist: true)
                cacheUpdateSubject.send(identifier)
            }
            return image
        }

        let loadingTask = Task<UIImage?, Never> {
            defer {
                _ = loadingTasksLock.withLock { tasks in tasks.removeValue(forKey: url) }
            }
            do {
                let (tempFileURL, response) = try await URLSession.shared.download(from: url)
                defer { try? FileManager.default.removeItem(at: tempFileURL) }

                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    Log.error("Failed to load image from URL: \(url) - invalid response")
                    return nil
                }
                guard let image = BoundedImageDecode.image(contentsOf: tempFileURL) else {
                    Log.error("Failed to decode image from URL: \(url)")
                    return nil
                }

                cacheImage(image, key: urlKey, cache: cache, logContext: "loadImage (from network)", imageFormat: .jpg)
                rememberLastShown(image, for: identifier, persist: true)
                Task { await saveImageToDisk(image, key: urlKey, imageFormat: .jpg) }
                publishCacheUpdate(urlKey: urlKey, identifier: identifier)
                return image
            } catch {
                Log.error("Failed to load image from URL: \(url) - \(error)")
                return nil
            }
        }

        loadingTasksLock.withLock { tasks in tasks[url] = loadingTask }
        return await loadingTask.value
    }

    private func fetchEncryptedImageInline(
        for object: any ImageCacheable,
        url: URL,
        urlKey: String,
        identifier: String,
        priority: EncryptedImageFetchPriority
    ) async -> UIImage? {
        guard let key = object.encryptionKey,
              let salt = object.encryptionSalt,
              let nonce = object.encryptionNonce else {
            Log.debug("Cannot inline decrypt - missing encryption params for: \(urlKey)")
            return nil
        }
        do {
            let decryptedData = try await EncryptedImageLoader.loadAndDecrypt(
                url: url,
                salt: salt,
                nonce: nonce,
                groupKey: key,
                priority: priority
            )
            guard let image = BoundedImageDecode.image(from: decryptedData) else {
                Log.error("Failed to create UIImage from decrypted data: \(urlKey)")
                return nil
            }
            cacheImage(image, key: urlKey, cache: cache, logContext: "inline encrypted fetch", imageFormat: .jpg)
            rememberLastShown(image, for: identifier, persist: true)
            Task { await saveDataToDisk(decryptedData, key: urlKey, imageFormat: .jpg, forceOverwrite: true) }
            publishCacheUpdate(urlKey: urlKey, identifier: identifier)
            return image
        } catch {
            Log.error("Failed to inline decrypt image for \(urlKey): \(error)")
            return nil
        }
    }

    // MARK: - Continuity hint (identity-keyed, read-only display fallback)

    private func lastShownInMemory(for identifier: String) -> UIImage? {
        lastShownLock.withLock { $0[identifier] }
    }

    private func stagedInMemory(for identifier: String) -> UIImage? {
        stagedLock.withLock { $0[identifier] }
    }

    private func rememberStaged(_ image: UIImage, for identifier: String) {
        stagedLock.withLock { $0[identifier] = image }
    }

    private func clearStaged(for identifier: String) {
        stagedLock.withLock { $0.removeValue(forKey: identifier) }
    }

    /// Records the last-shown image for an identity. Memory always; disk only on
    /// `persist` (a genuinely new image arriving), to avoid disk churn on every
    /// render. Never fetches and never affects byte-cache truth.
    private func rememberLastShown(_ image: UIImage, for identifier: String, persist: Bool) {
        lastShownLock.withLock { $0[identifier] = image }
        guard persist else { return }
        Task { await saveLastShownToDisk(image, for: identifier) }
    }

    private func clearLastShown(for identifier: String) {
        lastShownLock.withLock { $0.removeValue(forKey: identifier) }
        Task {
            await performDiskOperation { cache in
                let fileURL = cache.lastShownCacheURL.appendingPathComponent(
                    cache.sanitizedFilename(for: identifier, fileExtension: ".jpg")
                )
                guard cache.fileManager.fileExists(atPath: fileURL.path) else { return }
                try? cache.fileManager.removeItem(at: fileURL)
            }
        }
    }

    private func saveLastShownToDisk(_ image: UIImage, for identifier: String) async {
        guard let data = ImageCompression.resizeAndCompressToJPEG(image, compressionQuality: 0.7) else { return }
        await performDiskOperation { cache in
            let fileURL = cache.lastShownCacheURL.appendingPathComponent(
                cache.sanitizedFilename(for: identifier, fileExtension: ".jpg")
            )
            do {
                try data.write(to: fileURL, options: .atomic)
            } catch {
                Log.error("Failed to save continuity hint: \(identifier) - \(error)")
            }
        }
    }

    private func loadLastShownFromDisk(for identifier: String) async -> UIImage? {
        let fileURL = lastShownCacheURL.appendingPathComponent(
            sanitizedFilename(for: identifier, fileExtension: ".jpg")
        )
        let exists: Bool = await performDiskOperation(default: false) { cache in
            cache.fileManager.fileExists(atPath: fileURL.path)
        }
        guard exists, let image = BoundedImageDecode.image(contentsOf: fileURL) else { return nil }
        lastShownLock.withLock { storage in
            if storage[identifier] == nil { storage[identifier] = image }
        }
        return image
    }

    // MARK: - Identifier-based Methods (QR codes, generated images)

    public func image(for identifier: String, imageFormat: ImageFormat = .jpg) -> UIImage? {
        return cache.object(forKey: identifier as NSString)
    }

    public func imageAsync(for identifier: String, imageFormat: ImageFormat = .jpg) async -> UIImage? {
        if let memoryImage = cache.object(forKey: identifier as NSString) {
            return memoryImage
        }
        if let diskImage = await loadImageFromDisk(key: identifier, imageFormat: imageFormat) {
            cacheImageInMemory(diskImage, key: identifier, cache: cache, logContext: "Identifier cache (from disk)")
            return diskImage
        }
        return nil
    }

    public func cacheImage(_ image: UIImage, for identifier: String, imageFormat: ImageFormat = .jpg) {
        cacheImage(image, key: identifier, cache: cache, logContext: "Identifier cache", imageFormat: imageFormat)
        Task { await saveImageToDisk(image, key: identifier, imageFormat: imageFormat) }
        cacheUpdateSubject.send(identifier)
    }

    public func removeImage(for identifier: String) {
        cache.removeObject(forKey: identifier as NSString)
        Task { await removeImageFromDisk(key: identifier) }
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
        Task { await saveDataToDisk(data, key: identifier, storageTier: storageTier) }
        cacheUpdateSubject.send(identifier)
    }

    public func cacheImage(_ image: UIImage, for identifier: String, storageTier: ImageStorageTier) {
        let cost = memoryCost(for: image)
        cache.setObject(image, forKey: identifier as NSString, cost: cost)
        Task { await saveImageToDisk(image, key: identifier, storageTier: storageTier) }
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

    // MARK: - Disk Cache Helpers

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

    /// Load an image from disk by cache key (URL string for the byte cache, or an
    /// identifier for the QR/persistent path). Checks the persistent store and the
    /// evictable cache.
    private func loadImageFromDisk(key: String, imageFormat: ImageFormat) async -> UIImage? {
        let filename = sanitizedFilename(for: key, fileExtension: imageFormat.fileExtension)
        let persistentURL = persistentCacheURL.appendingPathComponent(filename)
        let cacheURL = diskCacheURL.appendingPathComponent(filename)

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

        for fileURL in existingFileURLs {
            guard let image = BoundedImageDecode.image(contentsOf: fileURL) else {
                Log.error("Failed to decode image from disk: \(key)")
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

    private func saveDataToDisk(
        _ data: Data,
        key: String,
        imageFormat: ImageFormat = .jpg,
        forceOverwrite: Bool = false,
        storageTier: ImageStorageTier = .cache
    ) async {
        let dir = directoryURL(for: storageTier)
        let fileURL = dir.appendingPathComponent(sanitizedFilename(for: key, fileExtension: imageFormat.fileExtension))
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
                Log.error("Failed to save image data to disk: \(key) - \(error)")
            }
        }
    }

    private func saveImageToDisk(
        _ image: UIImage,
        key: String,
        imageFormat: ImageFormat = .jpg,
        forceOverwrite: Bool = false,
        storageTier: ImageStorageTier = .cache
    ) async {
        await performDiskOperation { cache in
            let dir = cache.directoryURL(for: storageTier)
            let fileURL = dir.appendingPathComponent(cache.sanitizedFilename(for: key, fileExtension: imageFormat.fileExtension))
            if !forceOverwrite && cache.fileManager.fileExists(atPath: fileURL.path) {
                return
            }
            let data: Data? = switch imageFormat {
            case .png: ImageCompression.resizeAndCompressToPNG(image)
            case .jpg: ImageCompression.resizeAndCompressToJPEG(image, compressionQuality: 0.8)
            }
            guard let imageData = data else {
                Log.error("Failed to resize and compress image for disk: \(key)")
                return
            }
            do {
                try imageData.write(to: fileURL, options: .atomic)
                if storageTier == .cache {
                    cache.scheduleCleanupIfNeeded()
                }
            } catch {
                Log.error("Failed to save image to disk: \(key) - \(error)")
            }
        }
    }

    private func removeImageFromDisk(key: String) async {
        let filename = sanitizedFilename(for: key, fileExtension: ".jpg")
        let pngFilename = sanitizedFilename(for: key, fileExtension: ".png")
        await performDiskOperation { cache in
            let urls = [
                cache.diskCacheURL.appendingPathComponent(filename),
                cache.diskCacheURL.appendingPathComponent(pngFilename),
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

    // MARK: - Cleanup

    private func scheduleCleanupIfNeeded() {
        _ = cleanupLock.withLock { (task: inout Task<Void, Never>?) -> Task<Void, Never>? in
            guard task == nil else { return task }
            task = Task {
                await cleanupDiskCacheIfNeeded()
                _ = cleanupLock.withLock { (t: inout Task<Void, Never>?) -> Task<Void, Never>? in
                    t = nil
                    return nil
                }
            }
            return task
        }
    }

    /// LRU cleanup of the evictable byte cache when it exceeds the size limit.
    private func cleanupDiskCacheIfNeeded() async {
        struct CachedFileInfo {
            let url: URL
            let size: Int
            let date: Date
        }

        await performDiskOperation { cache in
            do {
                let resourceKeys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .isRegularFileKey]
                let fileURLs = try cache.fileManager.contentsOfDirectory(
                    at: cache.diskCacheURL,
                    includingPropertiesForKeys: resourceKeys,
                    options: .skipsHiddenFiles
                )
                let evictableURLs = fileURLs.filter { ($0.pathExtension == "jpg" || $0.pathExtension == "png") }

                let batchSize = 100
                var totalSize = 0

                for i in stride(from: 0, to: evictableURLs.count, by: batchSize) {
                    let endIndex = min(i + batchSize, evictableURLs.count)
                    for j in i..<endIndex {
                        let resourceValues = try evictableURLs[j].resourceValues(forKeys: Set(resourceKeys))
                        totalSize += resourceValues.fileSize ?? 0
                    }
                }

                guard totalSize > cache.maxDiskCacheSize else { return }

                var oldestFiles: [CachedFileInfo] = []
                for i in stride(from: 0, to: evictableURLs.count, by: batchSize) {
                    let endIndex = min(i + batchSize, evictableURLs.count)
                    for j in i..<endIndex {
                        let fileURL = evictableURLs[j]
                        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                        oldestFiles.append(CachedFileInfo(
                            url: fileURL,
                            size: resourceValues.fileSize ?? 0,
                            date: resourceValues.contentAccessDate ?? Date.distantPast
                        ))
                    }
                }

                oldestFiles.sort { $0.date < $1.date }

                var removedSize = 0
                for file in oldestFiles {
                    guard totalSize - removedSize > cache.maxDiskCacheSize else { break }
                    do {
                        try cache.fileManager.removeItem(at: file.url)
                        removedSize += file.size
                    } catch {
                        Log.error("Failed to remove cached image: \(file.url.lastPathComponent) - \(error)")
                    }
                }
                Log.debug("Disk cache cleanup: removed \(removedSize) bytes")
            } catch {
                Log.error("Failed to cleanup disk cache: \(error)")
            }
        }
    }

    /// SHA256-hashed, filesystem-safe filename for a cache key.
    private func sanitizedFilename(for key: String, fileExtension: String = ".jpg") -> String {
        let data = Data(key.utf8)
        let hashData = data.sha256Hash()
        let hashString = hashData.map { String(format: "%02x", $0) }.joined()
        return hashString + fileExtension
    }

    // MARK: - Memory helpers

    private func memoryCost(for image: UIImage) -> Int {
        guard let cgImage = image.cgImage else {
            let scale = image.scale > 0 ? image.scale : 1.0
            return Int(image.size.width * image.size.height * scale * scale * 4)
        }
        return cgImage.width * cgImage.height * 4
    }

    private func cacheImageInMemory(_ image: UIImage, key: String, cache: NSCache<NSString, UIImage>, logContext: String) {
        guard image.size.width > 0 && image.size.height > 0 else {
            Log.error("Invalid image dimensions for \(logContext): \(key)")
            return
        }
        cache.setObject(image, forKey: key as NSString, cost: memoryCost(for: image))
    }

    private func cacheImage(_ image: UIImage, key: String, cache: NSCache<NSString, UIImage>, logContext: String, imageFormat: ImageFormat = .jpg) {
        let compressedData: Data?
        switch imageFormat {
        case .png:
            compressedData = ImageCompression.resizeAndCompressToPNG(image)
        case .jpg:
            compressedData = ImageCompression.resizeAndCompressToJPEG(image, compressionQuality: 0.8)
        }
        guard let imageData = compressedData, let resizedImage = UIImage(data: imageData) else {
            Log.error("Failed to resize and compress image for \(logContext): \(key)")
            return
        }
        guard resizedImage.size.width > 0 && resizedImage.size.height > 0 else {
            Log.error("Failed to resize image for \(logContext): \(key) - invalid dimensions")
            return
        }
        cache.setObject(resizedImage, forKey: key as NSString, cost: memoryCost(for: resizedImage))
    }
}

// MARK: - SwiftUI View Extension

private struct ImageCacheTaskID: Hashable {
    let identifier: String
    let url: URL?
}

public extension View {
    /// Loads an image for an `ImageCacheable` into a binding, bridging with the
    /// continuity hint so a fresh render never blinks to a placeholder while the
    /// authoritative URL is resolved. Reloads when the object's URL changes or
    /// when new bytes are published for its URL or identity.
    func cachedImage(
        for object: any ImageCacheable,
        into binding: Binding<UIImage?>
    ) -> some View {
        self
            .onAppear {
                binding.wrappedValue = ImageCache.shared.image(for: object)
            }
            .task(id: ImageCacheTaskID(identifier: object.imageCacheIdentifier, url: object.imageCacheURL)) {
                // Re-seed for the current object so a reused view that swapped to
                // a different identity drops the previous object's image instead
                // of briefly showing the wrong avatar. For a same-identity URL
                // change this returns the continuity hint (the person's last
                // image), so there is no placeholder blink. Then resolve the URL.
                binding.wrappedValue = ImageCache.shared.image(for: object)
                if binding.wrappedValue == nil {
                    binding.wrappedValue = await ImageCache.shared.continuityImage(for: object)
                }
                if let resolved = await ImageCache.shared.loadImage(for: object) {
                    binding.wrappedValue = resolved
                }
            }
            .onReceive(
                ImageCache.shared.cacheUpdates
                    .filter { $0 == object.imageCacheURL?.absoluteString || $0 == object.imageCacheIdentifier }
            ) { _ in
                binding.wrappedValue = ImageCache.shared.image(for: object)
            }
    }

    /// Backward-compatibility variant that reports the current best-available
    /// image via a closure.
    func cachedImage(
        for object: any ImageCacheable,
        onChange: @escaping (UIImage?) -> Void
    ) -> some View {
        self
            .onAppear {
                onChange(ImageCache.shared.image(for: object))
            }
            .onReceive(
                ImageCache.shared.cacheUpdates
                    .filter { $0 == object.imageCacheURL?.absoluteString || $0 == object.imageCacheIdentifier }
            ) { _ in
                onChange(ImageCache.shared.image(for: object))
            }
    }
}

// MARK: - Persistent wipe

extension ImageCache {
    public func removeAllPersistentImages() {
        clearInMemoryImageState()
        Task {
            _ = await performDiskOperation(default: 0) { cache in
                cache.removeAllPersistentImagesFromDisk()
            }
        }
    }

    public func removeAllPersistentImagesAndWait() async throws {
        clearInMemoryImageState()
        let failureCount: Int = await performDiskOperation(default: 0) { cache in
            cache.removeAllPersistentImagesFromDisk()
        }
        if failureCount > 0 {
            throw ImageCacheWipeIncompleteError(failedFileCount: failureCount)
        }
    }

    private func clearInMemoryImageState() {
        cache.removeAllObjects()
        // Clear the in-memory continuity hint and staged pre-upload maps too, so a
        // delete-all reset cannot bridge to a previously shown avatar/group image.
        lastShownLock.withLock { $0.removeAll() }
        stagedLock.withLock { $0.removeAll() }
    }

    /// Runs on the disk queue (see `performDiskOperation`). Returns the
    /// number of files that could not be removed.
    private func removeAllPersistentImagesFromDisk() -> Int {
        var failureCount = 0
        for dir in [persistentCacheURL, lastShownCacheURL, diskCacheURL] {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            for fileURL in contents {
                do { try fileManager.removeItem(at: fileURL) } catch {
                    Log.error("Failed to remove image: \(fileURL.lastPathComponent) - \(error)")
                    failureCount += 1
                }
            }
            Log.info("Removed all images in \(dir.lastPathComponent) (\(contents.count) files)")
        }
        return failureCount
    }
}

#endif
