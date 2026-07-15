import Foundation

#if os(macOS)
import AppKit
import Combine

/// Mock image cache for macOS (used for testing only)
/// This provides a no-op implementation since image caching is not needed on macOS for tests
public final class MockImageCache: ImageCacheProtocol, @unchecked Sendable {
    /// Test hook: invoked by `removeAllPersistentImagesAndWait` so wiring
    /// tests can observe (and fail) the awaited wipe path.
    public var onRemoveAllPersistentImagesAndWait: (@Sendable () async throws -> Void)?

    public init() {}

    // MARK: - Primary API (object-based with URL tracking)

    public func loadImage(for object: any ImageCacheable) async -> ImageType? { nil }

    public func image(for object: any ImageCacheable) -> ImageType? { nil }

    public func imageAsync(for object: any ImageCacheable) async -> ImageType? { nil }

    public func imageAsync(forURL url: String) async -> ImageType? { nil }

    public func continuityImage(for object: any ImageCacheable) async -> ImageType? { nil }

    public func loadImageOrContinuity(for object: any ImageCacheable) async -> ImageType? { nil }

    public func removeImage(for object: any ImageCacheable) {}

    // MARK: - Upload Support

    public func prepareForUpload(_ image: ImageType, for object: any ImageCacheable) -> Data? { nil }

    public func prepareForUpload(_ image: ImageType, forIdentifier identifier: String) -> Data? { nil }

    public func cacheAfterUpload(_ image: ImageType, for object: any ImageCacheable, url: String) {}

    public func cacheAfterUpload(_ image: ImageType, for identifier: String, url: String) {}

    public func cacheAfterUpload(_ imageData: Data, for identifier: String, url: String) {}

    // MARK: - Identifier-based (for QR codes, generated images)

    public func image(for identifier: String, imageFormat: ImageFormat) -> ImageType? { nil }

    public func imageAsync(for identifier: String, imageFormat: ImageFormat) async -> ImageType? { nil }

    public func cacheImage(_ image: ImageType, for identifier: String, imageFormat: ImageFormat) {}

    public func removeImage(for identifier: String) {}

    // MARK: - Persistent Storage

    public func cacheData(_ data: Data, for identifier: String, storageTier: ImageStorageTier) {}

    public func cacheImage(_ image: ImageType, for identifier: String, storageTier: ImageStorageTier) {}

    public func removePersistentImages(for identifiers: [String]) {}

    public func removeAllPersistentImages() {}

    public func removeAllPersistentImagesAndWait() async throws {
        try await onRemoveAllPersistentImagesAndWait?()
    }

    // MARK: - Observation

    public var cacheUpdates: AnyPublisher<String, Never> {
        _cacheUpdates.eraseToAnyPublisher()
    }

    private var _cacheUpdates: CurrentValueSubject<String, Never> = .init("")
}
#endif
