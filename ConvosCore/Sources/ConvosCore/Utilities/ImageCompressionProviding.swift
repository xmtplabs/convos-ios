import Foundation
#if canImport(UIKit)
import UIKit

/// Protocol for image compression and resizing operations.
///
/// Implementations are platform-specific (iOS uses UIGraphicsImageRenderer).
/// The protocol allows ConvosCore to work with image compression without direct UIKit dependencies.
public protocol ImageCompressionProviding: Sendable {
    /// Default size for cache-optimized images
    static var cacheOptimizedSize: CGFloat { get }

    /// Resizes and compresses image to JPEG data in a single pass for optimal performance
    /// - Parameters:
    ///   - image: The original UIImage to resize and compress
    ///   - maxSize: Maximum dimensions in points
    ///   - compressionQuality: JPEG compression quality (0.0-1.0)
    /// - Returns: JPEG data of the resized and compressed image, or nil if compression fails
    func resizeAndCompressToJPEG(
        _ image: UIImage,
        maxSize: CGSize,
        compressionQuality: CGFloat
    ) -> Data?

    /// Resizes and compresses image to PNG data in a single pass for optimal performance
    /// This preserves alpha channel and is lossless, making it ideal for images with transparency
    /// - Parameters:
    ///   - image: The original UIImage to resize and compress
    ///   - maxSize: Maximum dimensions in points
    /// - Returns: PNG data of the resized and compressed image, or nil if compression fails
    func resizeAndCompressToPNG(
        _ image: UIImage,
        maxSize: CGSize
    ) -> Data?
}

// MARK: - Shared Instance Access

/// Accessor for the shared image compression provider instance.
///
/// The concrete implementation must be set by the platform-specific layer (e.g., ConvosCoreiOS)
/// during app initialization before any code in ConvosCore accesses it.
///
/// Example usage in AppDelegate or App init:
/// ```swift
/// ImageCompression.configure(IOSImageCompression())
/// ```
public enum ImageCompression {
    /// Default size for cache-optimized images
    public static let cacheOptimizedSize: CGFloat = 500

    private static let lock: NSLock = .init()
    nonisolated(unsafe) private static var _shared: (any ImageCompressionProviding)?
    nonisolated(unsafe) private static var isConfigured: Bool = false

    /// Configures the shared image compression provider instance.
    /// - Important: Must be called exactly once during app initialization before use.
    /// - Parameter provider: The platform-specific image compression provider.
    public static func configure(_ provider: any ImageCompressionProviding) {
        lock.lock()
        defer { lock.unlock() }

        guard !isConfigured else {
            Log.error("ImageCompression.configure() must only be called once")
            return
        }

        _shared = provider
        isConfigured = true
    }

    /// The shared image compression provider instance.
    /// - Important: `configure(_:)` must be called during app initialization before use.
    public static var shared: any ImageCompressionProviding {
        lock.lock()
        defer { lock.unlock() }

        guard let provider = _shared else {
            fatalError("ImageCompression.configure() must be called before use")
        }
        return provider
    }

    /// Resizes and compresses image to JPEG data using default cache-optimized size
    public static func resizeAndCompressToJPEG(
        _ image: UIImage,
        compressionQuality: CGFloat = 0.8
    ) -> Data? {
        shared.resizeAndCompressToJPEG(
            image,
            maxSize: CGSize(width: cacheOptimizedSize, height: cacheOptimizedSize),
            compressionQuality: compressionQuality
        )
    }

    /// Resizes and compresses image to PNG data using default cache-optimized size
    public static func resizeAndCompressToPNG(_ image: UIImage) -> Data? {
        shared.resizeAndCompressToPNG(
            image,
            maxSize: CGSize(width: cacheOptimizedSize, height: cacheOptimizedSize)
        )
    }

    /// Resets the configuration state. Only for use in tests.
    /// - Important: This is not thread-safe and should only be called from test setup.
    public static func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        _shared = nil
        isConfigured = false
    }
}

#endif
