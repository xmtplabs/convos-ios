#if canImport(UIKit)
import ConvosCore
import Foundation
import UIKit

/// iOS implementation of image compression using UIGraphicsImageRenderer.
public struct IOSImageCompression: ImageCompressionProviding {
    public static let cacheOptimizedSize: CGFloat = 500

    public init() {}

    /// Resizes and compresses image to JPEG data in a single pass for optimal performance
    /// - Parameters:
    ///   - image: The original UIImage to resize and compress
    ///   - maxSize: Maximum dimensions in points
    ///   - compressionQuality: JPEG compression quality (0.0-1.0, default: 0.8)
    /// - Returns: JPEG data of the resized and compressed image, or nil if compression fails
    public func resizeAndCompressToJPEG(
        _ image: UIImage,
        maxSize: CGSize = CGSize(width: cacheOptimizedSize, height: cacheOptimizedSize),
        compressionQuality: CGFloat = 0.8
    ) -> Data? {
        // Calculate target size maintaining aspect ratio
        let size = image.size
        guard size.width > 0 && size.height > 0 else { return nil }

        let targetSize: CGSize
        if size.width <= maxSize.width && size.height <= maxSize.height {
            // Image is already small enough
            targetSize = size
        } else {
            // Calculate scale factor to fit within max size while maintaining aspect ratio
            let widthRatio = maxSize.width / size.width
            let heightRatio = maxSize.height / size.height
            let scaleFactor = min(widthRatio, heightRatio)

            targetSize = CGSize(
                width: size.width * scaleFactor,
                height: size.height * scaleFactor
            )
        }

        // Use UIGraphicsImageRenderer to resize - it automatically handles orientation
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        // Compress to JPEG
        return resizedImage.jpegData(compressionQuality: compressionQuality)
    }

    /// Resizes and compresses image to PNG data in a single pass for optimal performance
    /// This preserves alpha channel and is lossless, making it ideal for images with transparency
    /// - Parameters:
    ///   - image: The original UIImage to resize and compress
    ///   - maxSize: Maximum dimensions in points (default: 500×500pt for cache optimization)
    /// - Returns: PNG data of the resized and compressed image, or nil if compression fails
    public func resizeAndCompressToPNG(
        _ image: UIImage,
        maxSize: CGSize = CGSize(width: cacheOptimizedSize, height: cacheOptimizedSize)
    ) -> Data? {
        // Calculate target size maintaining aspect ratio
        let size = image.size
        guard size.width > 0 && size.height > 0 else { return nil }

        let targetSize: CGSize
        if size.width <= maxSize.width && size.height <= maxSize.height {
            // Image is already small enough
            targetSize = size
        } else {
            // Calculate scale factor to fit within max size while maintaining aspect ratio
            let widthRatio = maxSize.width / size.width
            let heightRatio = maxSize.height / size.height
            let scaleFactor = min(widthRatio, heightRatio)

            targetSize = CGSize(
                width: size.width * scaleFactor,
                height: size.height * scaleFactor
            )
        }

        // Use UIGraphicsImageRenderer to resize, automatically handle orientation
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        // Compress to PNG
        return resizedImage.pngData()
    }
}
#endif
