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

    public func compressForPhotoAttachment(
        _ image: UIImage,
        targetBytes: Int,
        maxBytes: Int,
        maxDimension: CGFloat
    ) -> Data? {
        let size = image.size
        guard size.width > 0 && size.height > 0 else {
            Log.error("compressForPhotoAttachment: Invalid image size \(size)")
            return nil
        }

        Log.info("compressForPhotoAttachment: Original size \(size), maxDimension \(maxDimension)")

        // Calculate target size maintaining aspect ratio
        let targetSize: CGSize
        if size.width <= maxDimension && size.height <= maxDimension {
            targetSize = size
        } else {
            let scaleFactor = maxDimension / max(size.width, size.height)
            targetSize = CGSize(
                width: size.width * scaleFactor,
                height: size.height * scaleFactor
            )
        }

        Log.info("compressForPhotoAttachment: Target size \(targetSize)")

        // Resize image using UIGraphicsImageRenderer with scale 1.0
        // This ensures we work with actual pixels, not points (which would be 3x on retina)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resizedImage = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        // Check if resized image at high quality exceeds max bytes
        // This catches truly huge images that can't be compressed enough
        if let initialData = resizedImage.jpegData(compressionQuality: 1.0) {
            Log.info("compressForPhotoAttachment: Resized image at q1.0 = \(initialData.count) bytes, maxBytes = \(maxBytes)")
            if initialData.count > maxBytes {
                Log.error("compressForPhotoAttachment: Resized image still exceeds maxBytes")
                return nil
            }
        }

        // Iteratively reduce quality until under target size
        var quality: CGFloat = 0.85
        let minQuality: CGFloat = 0.5
        let qualityStep: CGFloat = 0.05

        var data = resizedImage.jpegData(compressionQuality: quality)

        while let currentData = data,
              currentData.count > targetBytes,
              quality > minQuality {
            quality -= qualityStep
            data = resizedImage.jpegData(compressionQuality: quality)
        }

        return data
    }
}
#endif
