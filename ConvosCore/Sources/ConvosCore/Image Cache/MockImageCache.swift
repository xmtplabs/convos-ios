import Foundation

#if os(macOS)
import AppKit
import Combine

/// Mock image cache for macOS (used for testing only)
/// This provides a no-op implementation since image caching is not needed on macOS for tests
public final class MockImageCache: ImageCacheProtocol, @unchecked Sendable {
    public init() {}

    // MARK: - Object-based Methods

    public func image(for object: any ImageCacheable) -> ImageType? { nil }

    public func imageAsync(for object: any ImageCacheable) async -> ImageType? { nil }

    public func setImage(_ image: ImageType, for object: any ImageCacheable) {}

    public func resizeCacheAndGetData(_ image: ImageType, for object: any ImageCacheable) -> Data? { nil }

    public func removeImage(for object: any ImageCacheable) {}

    // MARK: - Identifier-based Methods

    public func image(for identifier: String, imageFormat: ImageFormat) -> ImageType? { nil }

    public func imageAsync(for identifier: String, imageFormat: ImageFormat) async -> ImageType? { nil }

    public func cacheImage(_ image: ImageType, for identifier: String, imageFormat: ImageFormat) {}

    public func resizeCacheAndGetData(_ image: ImageType, for identifier: String) -> Data? { nil }

    public func removeImage(for identifier: String) {}

    // MARK: - URL-based Methods

    public func image(for url: URL) -> ImageType? { nil }

    public func imageAsync(for url: URL) async -> ImageType? { nil }

    public func setImage(_ image: ImageType, for url: String) {}

    public var cacheUpdates: AnyPublisher<String, Never> {
        _cacheUpdates.eraseToAnyPublisher()
    }

    private var _cacheUpdates: CurrentValueSubject<String, Never> = .init("")
}
#endif
