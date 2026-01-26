import Combine
import Foundation

// MARK: - Image Cache Protocol

/// Protocol for image caching implementations
public protocol ImageCacheProtocol: AnyObject, Sendable {
    // MARK: - Primary API (object-based with URL tracking)

    /// Load image for an ImageCacheable object, using its URL for fetching
    /// Handles memory → disk → network with URL tracking
    func loadImage(for object: any ImageCacheable) async -> ImageType?

    /// Get cached image for any ImageCacheable object (synchronous, memory only)
    func image(for object: any ImageCacheable) -> ImageType?

    /// Get cached image for any ImageCacheable object (async, checks memory → disk)
    func imageAsync(for object: any ImageCacheable) async -> ImageType?

    /// Remove cached image for any ImageCacheable object
    func removeImage(for object: any ImageCacheable)

    // MARK: - Upload Support

    /// Prepare an image for upload by resizing/compressing and caching it
    func prepareForUpload(_ image: ImageType, for object: any ImageCacheable) -> Data?

    /// Cache an image after upload completes, updating URL tracking
    func cacheAfterUpload(_ image: ImageType, for object: any ImageCacheable, url: String)

    /// Cache an image after fetching/decrypting, updating URL tracking (identifier-based)
    func cacheAfterUpload(_ image: ImageType, for identifier: String, url: String)

    /// Cache pre-compressed image data after fetching/decrypting (avoids re-compression)
    func cacheAfterUpload(_ imageData: Data, for identifier: String, url: String)

    // MARK: - Identifier-based (for QR codes, generated images)

    /// Get cached image by identifier (synchronous, memory only)
    func image(for identifier: String, imageFormat: ImageFormat) -> ImageType?

    /// Get cached image by identifier (async, checks memory → disk)
    func imageAsync(for identifier: String, imageFormat: ImageFormat) async -> ImageType?

    /// Cache image by identifier
    func cacheImage(_ image: ImageType, for identifier: String, imageFormat: ImageFormat)

    /// Remove cached image by identifier
    func removeImage(for identifier: String)

    // MARK: - URL Change Detection

    /// Check if the URL has changed for an identifier (without updating tracker)
    /// Used by prefetcher to detect if it needs to re-fetch encrypted images
    func hasURLChanged(_ url: String?, for identifier: String) async -> Bool

    // MARK: - Observation

    /// Publisher that emits when a specific cached image is updated and ready to display.
    /// Views should observe this to know when to refresh their image.
    var cacheUpdates: AnyPublisher<String, Never> { get }
}

// MARK: - Default Parameters Extension

public extension ImageCacheProtocol {
    func image(for identifier: String) -> ImageType? {
        image(for: identifier, imageFormat: .jpg)
    }

    func imageAsync(for identifier: String) async -> ImageType? {
        await imageAsync(for: identifier, imageFormat: .jpg)
    }

    func cacheImage(_ image: ImageType, for identifier: String) {
        cacheImage(image, for: identifier, imageFormat: .jpg)
    }
}
