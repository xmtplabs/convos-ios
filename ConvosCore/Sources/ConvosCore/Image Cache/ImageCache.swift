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

// MARK: - ImageCacheable Protocol

/// Protocol for objects that can have their images cached.
public protocol ImageCacheable: Sendable {
    /// Unique identifier used for caching the image
    var imageCacheIdentifier: String { get }
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

/// Smart reactive image cache that stores images for any ImageCacheable object with instant updates.
/// Supports three-tier caching: memory → disk → network
/// When a new image is uploaded for an object, all views showing that object update instantly.
///
/// @unchecked Sendable: Thread safety is ensured through:
/// - NSCache: Internally thread-safe for all operations
/// - diskCacheQueue: Serial DispatchQueue serializing all disk I/O
/// - cleanupLock: OSAllocatedUnfairLock coordinating cleanup task scheduling
/// - cacheUpdateSubject: Combine PassthroughSubject is thread-safe for send/subscribe
/// All properties are immutable after init except for cleanup task coordination.
@Observable
public final class ImageCache: ImageCacheProtocol, @unchecked Sendable {
    public static var shared: any ImageCacheProtocol { ImageCacheContainer.shared }

    private let cache: NSCache<NSString, UIImage>

    // Disk cache properties
    private let diskCacheURL: URL
    private let diskCacheQueue: DispatchQueue
    private let fileManager: FileManager
    private let maxDiskCacheSize: Int = CacheConfiguration.maxDiskCacheSize

    // Cleanup coordination
    private let cleanupLock: OSAllocatedUnfairLock<Task<Void, Never>?> = OSAllocatedUnfairLock(initialState: nil)

    /// Publisher for specific cache updates by identifier
    private let cacheUpdateSubject: PassthroughSubject<String, Never> = PassthroughSubject<String, Never>()

    /// Publisher that emits when a specific cached image is updated
    public var cacheUpdates: AnyPublisher<String, Never> {
        cacheUpdateSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    init() {
        cache = NSCache<NSString, UIImage>()
        cache.countLimit = CacheConfiguration.memoryCacheCountLimit
        cache.totalCostLimit = CacheConfiguration.memoryCacheTotalCostLimit

        // Setup disk cache
        fileManager = FileManager.default
        diskCacheQueue = DispatchQueue(label: "com.convos.imagecache.disk", qos: .utility)

        // Create disk cache directory
        let cacheDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        diskCacheURL = cacheDir.appendingPathComponent("ImageCache", isDirectory: true)

        do {
            try fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        } catch {
            Log.error("Failed to create disk cache directory: \(error)")
            // Fallback: Memory-only caching will still work, but disk operations will fail gracefully
        }

        // Clean up disk cache on init if needed
        scheduleCleanupIfNeeded()
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

    /// Set cached image for any ImageCacheable object (saves to both memory and disk)
    public func setImage(_ image: UIImage, for object: any ImageCacheable) {
        let identifier = object.imageCacheIdentifier
        cacheImage(image, key: identifier, cache: cache, logContext: "Object cache", imageFormat: .jpg)

        // Save to disk asynchronously (default to JPEG for object-based cache)
        Task {
            await saveImageToDisk(image, identifier: identifier, imageFormat: .jpg)
        }

        cacheUpdateSubject.send(identifier)
    }

    /// Resize, cache, and return JPEG data for upload in one pass
    /// This optimizes the common pattern of resizing, caching, and uploading images
    /// - Parameters:
    ///   - image: The original UIImage to resize and cache
    ///   - object: The ImageCacheable object to cache the image for
    /// - Returns: JPEG data ready for upload, or nil if compression fails
    public func resizeCacheAndGetData(_ image: UIImage, for object: any ImageCacheable) -> Data? {
        let identifier = object.imageCacheIdentifier

        // Resize and compress to JPEG in one pass
        guard let jpegData = ImageCompression.resizeAndCompressToJPEG(image, compressionQuality: 0.8) else {
            Log.error("Failed to resize and compress image for upload: \(identifier)")
            return nil
        }

        // Reconstruct UIImage and cache asynchronously to avoid blocking
        // This allows the method to return the JPEG data immediately for upload
        Task {
            guard let resizedImage = UIImage(data: jpegData) else {
                Log.error("Failed to create UIImage from compressed data for caching: \(identifier)")
                return
            }

            // Cache the resized image in memory
            let cost = memoryCost(for: resizedImage)
            cache.setObject(resizedImage, forKey: identifier as NSString, cost: cost)
            Log.info("Successfully cached resized image for upload: \(identifier)")

            // Notify immediately after memory cache (consistent with other methods)
            cacheUpdateSubject.send(identifier)

            // Save pre-compressed JPEG data directly to disk to avoid double compression
            await saveDataToDisk(jpegData, identifier: identifier, imageFormat: .jpg)
        }

        return jpegData
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

    /// Resize, cache, and return JPEG data for upload in one pass (identifier-based)
    /// This optimizes the common pattern of resizing, caching, and uploading images
    /// - Parameters:
    ///   - image: The original UIImage to resize and cache
    ///   - identifier: The identifier string to cache the image for
    /// - Returns: JPEG data ready for upload, or nil if compression fails
    public func resizeCacheAndGetData(_ image: UIImage, for identifier: String) -> Data? {
        // Resize and compress to JPEG in one pass
        guard let jpegData = ImageCompression.resizeAndCompressToJPEG(image, compressionQuality: 0.8) else {
            Log.error("Failed to resize and compress image for upload: \(identifier)")
            return nil
        }

        // Reconstruct UIImage and cache asynchronously to avoid blocking
        // This allows the method to return the JPEG data immediately for upload
        Task {
            guard let resizedImage = UIImage(data: jpegData) else {
                Log.error("Failed to create UIImage from compressed data for caching: \(identifier)")
                return
            }

            // Cache the resized image in memory
            let cost = memoryCost(for: resizedImage)
            cache.setObject(resizedImage, forKey: identifier as NSString, cost: cost)
            Log.info("Successfully cached resized image for upload: \(identifier)")

            // Notify immediately after memory cache (consistent with other methods)
            cacheUpdateSubject.send(identifier)

            // Save pre-compressed JPEG data directly to disk to avoid double compression
            await saveDataToDisk(jpegData, identifier: identifier, imageFormat: .jpg)
        }

        return jpegData
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

    // MARK: - URL-based Methods (kept for compatibility)

    public func image(for url: URL) -> UIImage? {
        return cache.object(forKey: url.absoluteString as NSString)
    }

    /// Get cached image by URL (async, checks memory → disk)
    public func imageAsync(for url: URL) async -> UIImage? {
        let urlString = url.absoluteString

        // Check memory first
        if let memoryImage = cache.object(forKey: urlString as NSString) {
            return memoryImage
        }

        // Check disk (using URL string as identifier, default to JPEG)
        if let diskImage = await loadImageFromDisk(identifier: urlString, imageFormat: .jpg) {
            // Populate memory cache (image is already compressed/resized from disk)
            cacheImageInMemory(diskImage, key: urlString, cache: cache, logContext: "URL cache (from disk)")
            return diskImage
        }

        return nil
    }

    public func setImage(_ image: UIImage, for url: String) {
        cacheImage(image, key: url, cache: cache, logContext: "URL cache", imageFormat: .jpg)

        // Save to disk asynchronously (default to JPEG for URL-based cache)
        Task {
            await saveImageToDisk(image, identifier: url, imageFormat: .jpg)
        }

        cacheUpdateSubject.send(url)
    }

    // MARK: - Disk Cache Methods

    /// Load image from disk cache
    private func loadImageFromDisk(identifier: String, imageFormat: ImageFormat) async -> UIImage? {
        let fileURL = self.diskCacheURL.appendingPathComponent(self.sanitizedFilename(for: identifier, fileExtension: imageFormat.fileExtension))
        let formatName = imageFormat == .png ? "PNG" : "JPEG"

        return await withCheckedContinuation { continuation in
            self.diskCacheQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }

                guard self.fileManager.fileExists(atPath: fileURL.path) else {
                    continuation.resume(returning: nil)
                    return
                }

                do {
                    let data = try Data(contentsOf: fileURL)
                    if let image = UIImage(data: data) {
                        // Update file access date for LRU cleanup
                        var mutableFileURL = fileURL
                        var resourceValues = URLResourceValues()
                        resourceValues.contentAccessDate = Date()
                        try? mutableFileURL.setResourceValues(resourceValues)
                        Log.info("Successfully loaded \(formatName) image from disk: \(identifier)")
                        continuation.resume(returning: image)
                    } else {
                        Log.error("Failed to decode image from disk: \(identifier)")
                        continuation.resume(returning: nil)
                    }
                } catch {
                    Log.error("Failed to load image from disk: \(identifier) - \(error)")
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// Save pre-compressed data directly to disk cache (avoids double compression)
    /// - Parameters:
    ///   - data: The image data to save
    ///   - identifier: The cache identifier
    ///   - imageFormat: The image format (default: .jpg)
    private func saveDataToDisk(_ data: Data, identifier: String, imageFormat: ImageFormat = .jpg) async {
        let fileURL = self.diskCacheURL.appendingPathComponent(self.sanitizedFilename(for: identifier, fileExtension: imageFormat.fileExtension))
        let formatName = imageFormat == .png ? "PNG" : "JPEG"

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.diskCacheQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                do {
                    try data.write(to: fileURL, options: .atomic)
                    Log.info("Successfully saved image data to disk: \(identifier) (\(data.count) bytes, format: \(formatName))")
                    // Trigger cleanup if needed
                    self.scheduleCleanupIfNeeded()
                } catch {
                    Log.error("Failed to save image data to disk: \(identifier) - \(error)")
                }

                continuation.resume()
            }
        }
    }

    /// Save image to disk cache
    private func saveImageToDisk(_ image: UIImage, identifier: String, imageFormat: ImageFormat = .jpg) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.diskCacheQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                let data: Data?
                switch imageFormat {
                case .png:
                    data = ImageCompression.resizeAndCompressToPNG(image)
                case .jpg:
                    data = ImageCompression.resizeAndCompressToJPEG(image, compressionQuality: 0.8)
                }

                guard let imageData = data else {
                    Log.error("Failed to resize and compress image for disk: \(identifier)")
                    continuation.resume()
                    return
                }

                let fileURL = self.diskCacheURL.appendingPathComponent(self.sanitizedFilename(for: identifier, fileExtension: imageFormat.fileExtension))

                do {
                    try imageData.write(to: fileURL, options: .atomic)
                    let formatName = imageFormat == .png ? "PNG" : "JPEG"
                    Log.info("Successfully saved image to disk: \(identifier) (\(imageData.count) bytes, format: \(formatName))")
                    // Trigger cleanup if needed
                    self.scheduleCleanupIfNeeded()
                } catch {
                    Log.error("Failed to save image to disk: \(identifier) - \(error)")
                }

                continuation.resume()
            }
        }
    }

    /// Remove image from disk cache
    /// Removes both PNG and JPEG versions if they exist (for backward compatibility)
    private func removeImageFromDisk(identifier: String) async {
        let pngURL = self.diskCacheURL.appendingPathComponent(self.sanitizedFilename(for: identifier, fileExtension: ".png"))
        let jpgURL = self.diskCacheURL.appendingPathComponent(self.sanitizedFilename(for: identifier, fileExtension: ".jpg"))

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.diskCacheQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                // Remove PNG if it exists
                if self.fileManager.fileExists(atPath: pngURL.path) {
                    do {
                        try self.fileManager.removeItem(at: pngURL)
                        Log.info("Successfully removed PNG image from disk: \(identifier)")
                    } catch {
                        if (error as NSError).code != NSFileNoSuchFileError {
                            Log.error("Failed to remove PNG image from disk: \(identifier) - \(error)")
                        }
                    }
                }

                // Remove JPEG if it exists
                if self.fileManager.fileExists(atPath: jpgURL.path) {
                    do {
                        try self.fileManager.removeItem(at: jpgURL)
                        Log.info("Successfully removed JPEG image from disk: \(identifier)")
                    } catch {
                        // Ignore error if file doesn't exist
                        if (error as NSError).code != NSFileNoSuchFileError {
                            Log.error("Failed to remove JPEG image from disk: \(identifier) - \(error)")
                        }
                    }
                }

                continuation.resume()
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

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.diskCacheQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                do {
                    let resourceKeys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey]
                    let fileURLs = try self.fileManager.contentsOfDirectory(
                        at: self.diskCacheURL,
                        includingPropertiesForKeys: resourceKeys,
                        options: .skipsHiddenFiles
                    )

                    // Process files in batches to avoid loading all metadata into memory at once
                    let batchSize = 100
                    var totalSize = 0
                    var batch: [CachedFileInfo] = []
                    batch.reserveCapacity(batchSize)

                    // First pass: Calculate total size in batches
                    for i in stride(from: 0, to: fileURLs.count, by: batchSize) {
                        let endIndex = min(i + batchSize, fileURLs.count)
                        batch.removeAll(keepingCapacity: true)

                        for j in i..<endIndex {
                            let fileURL = fileURLs[j]
                            let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                            let size = resourceValues.fileSize ?? 0

                            totalSize += size
                        }
                    }

                    // Second pass: If cleanup needed, collect oldest files in batches
                    if totalSize > self.maxDiskCacheSize {
                        var oldestFiles: [CachedFileInfo] = []

                        // Collect all files in batches
                        for i in stride(from: 0, to: fileURLs.count, by: batchSize) {
                            let endIndex = min(i + batchSize, fileURLs.count)
                            batch.removeAll(keepingCapacity: true)

                            // Process batch
                            for j in i..<endIndex {
                                let fileURL = fileURLs[j]
                                let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                                let size = resourceValues.fileSize ?? 0
                                let date = resourceValues.contentAccessDate ?? Date.distantPast

                                batch.append(CachedFileInfo(url: fileURL, size: size, date: date))
                            }

                            // Merge batch with oldestFiles
                            oldestFiles.append(contentsOf: batch)
                        }

                        // Sort by date (oldest first) once at the end
                        oldestFiles.sort { $0.date < $1.date }

                        // Delete oldest files until we're under the limit
                        var removedSize = 0
                        for file in oldestFiles {
                            guard totalSize - removedSize > self.maxDiskCacheSize else { break }

                            do {
                                try self.fileManager.removeItem(at: file.url)
                                removedSize += file.size
                                Log.info("Removed old cached image from disk: \(file.url.lastPathComponent)")
                            } catch {
                                Log.error("Failed to remove cached image: \(file.url.lastPathComponent) - \(error)")
                            }
                        }

                        Log.info("Disk cache cleanup: removed \(removedSize) bytes")
                    }
                } catch {
                    Log.error("Failed to cleanup disk cache: \(error)")
                }

                continuation.resume()
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
        Log.info("Successfully cached image for \(logContext): \(key)")
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
        Log.info("Successfully cached resized image for \(logContext): \(key) (format: \(formatName))")
    }
}

// MARK: - SwiftUI View Extension for Easy Image Cache Integration

public extension View {
    /// Modifier that subscribes to image cache updates for a specific ImageCacheable object
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
