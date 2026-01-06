import Combine
import Foundation

// MARK: - Image Cache Protocol

/// Protocol for image caching implementations
public protocol ImageCacheProtocol: AnyObject, Sendable {
    // MARK: - Object-based Methods

    /// Get cached image for any ImageCacheable object (synchronous, memory only)
    func image(for object: any ImageCacheable) -> ImageType?

    /// Get cached image for any ImageCacheable object (async, checks memory → disk)
    func imageAsync(for object: any ImageCacheable) async -> ImageType?

    /// Set cached image for any ImageCacheable object
    func setImage(_ image: ImageType, for object: any ImageCacheable)

    /// Resize, cache, and return JPEG data for upload
    func resizeCacheAndGetData(_ image: ImageType, for object: any ImageCacheable) -> Data?

    /// Remove cached image for any ImageCacheable object
    func removeImage(for object: any ImageCacheable)

    // MARK: - Identifier-based Methods

    /// Get cached image by identifier (synchronous, memory only)
    func image(for identifier: String, imageFormat: ImageFormat) -> ImageType?

    /// Get cached image by identifier (async, checks memory → disk)
    func imageAsync(for identifier: String, imageFormat: ImageFormat) async -> ImageType?

    /// Cache image by identifier
    func cacheImage(_ image: ImageType, for identifier: String, imageFormat: ImageFormat)

    /// Resize, cache, and return JPEG data for upload (identifier-based)
    func resizeCacheAndGetData(_ image: ImageType, for identifier: String) -> Data?

    /// Remove cached image by identifier
    func removeImage(for identifier: String)

    // MARK: - URL-based Methods

    /// Get cached image by URL (synchronous, memory only)
    func image(for url: URL) -> ImageType?

    /// Get cached image by URL (async, checks memory → disk)
    func imageAsync(for url: URL) async -> ImageType?

    /// Set cached image for URL string
    func setImage(_ image: ImageType, for url: String)

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
