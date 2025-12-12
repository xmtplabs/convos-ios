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
/// ImageCompression.shared = IOSImageCompression()
/// ```
public enum ImageCompression {
    /// Default size for cache-optimized images
    public static let cacheOptimizedSize: CGFloat = 500

    // Using nonisolated(unsafe) because:
    // 1. This is set once at app startup before any concurrent access
    // 2. After initialization, it's read-only
    // 3. The underlying type is Sendable
    nonisolated(unsafe) private static var _shared: (any ImageCompressionProviding)?

    /// The shared image compression provider instance.
    /// - Important: Must be set during app initialization before use.
    public static var shared: any ImageCompressionProviding {
        get {
            guard let provider = _shared else {
                fatalError("ImageCompression.shared must be set before use")
            }
            return provider
        }
        set {
            _shared = newValue
        }
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
}

#endif
