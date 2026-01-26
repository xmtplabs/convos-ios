import Foundation

#if os(macOS)
import AppKit
import Combine

/// Mock image cache for macOS (used for testing only)
/// This provides a no-op implementation since image caching is not needed on macOS for tests
public final class MockImageCache: ImageCacheProtocol, @unchecked Sendable {
    public init() {}

    // MARK: - Primary API (object-based with URL tracking)

    public func loadImage(for object: any ImageCacheable) async -> ImageType? { nil }

    public func image(for object: any ImageCacheable) -> ImageType? { nil }

    public func imageAsync(for object: any ImageCacheable) async -> ImageType? { nil }

    public func removeImage(for object: any ImageCacheable) {}

    // MARK: - Upload Support

    public func prepareForUpload(_ image: ImageType, for object: any ImageCacheable) -> Data? { nil }

    public func cacheAfterUpload(_ image: ImageType, for object: any ImageCacheable, url: String) {}

    public func cacheAfterUpload(_ image: ImageType, for identifier: String, url: String) {}

    public func cacheAfterUpload(_ imageData: Data, for identifier: String, url: String) {}

    // MARK: - Identifier-based (for QR codes, generated images)

    public func image(for identifier: String, imageFormat: ImageFormat) -> ImageType? { nil }

    public func imageAsync(for identifier: String, imageFormat: ImageFormat) async -> ImageType? { nil }

    public func cacheImage(_ image: ImageType, for identifier: String, imageFormat: ImageFormat) {}

    public func removeImage(for identifier: String) {}

    // MARK: - URL Change Detection

    public func hasURLChanged(_ url: String?, for identifier: String) async -> Bool { false }

    // MARK: - Observation

    public var cacheUpdates: AnyPublisher<String, Never> {
        _cacheUpdates.eraseToAnyPublisher()
    }

    /// Publisher that emits when an image URL changes for an identifier.
    ///
    /// - Important: **For testing only.** Do not use this for UI observation.
    ///   Use `cacheUpdates` instead, which emits when an image is cached and ready to display.
    internal var urlChanges: AnyPublisher<ImageURLChange, Never> {
        _urlChanges.eraseToAnyPublisher()
    }

    private var _cacheUpdates: CurrentValueSubject<String, Never> = .init("")
    private var _urlChanges: PassthroughSubject<ImageURLChange, Never> = .init()
}
#endif
