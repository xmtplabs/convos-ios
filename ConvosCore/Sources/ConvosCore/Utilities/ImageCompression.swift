import Foundation

struct ImageCompression {
    static let cacheOptimizedSize: CGFloat = 500

    /// Resizes and compresses image to JPEG data in a single pass for optimal performance
    /// - Parameters:
    ///   - image: The original Image to resize and compress
    ///   - maxSize: Maximum dimensions in points
    ///   - compressionQuality: JPEG compression quality (0.0-1.0, default: 0.8)
    /// - Returns: JPEG data of the resized and compressed image, or nil if compression fails
	static func resizeAndCompressToJPEG(
		_ image: Image,
		maxSize: CGSize = CGSize(width: cacheOptimizedSize, height: cacheOptimizedSize),
		compressionQuality: CGFloat = 0.8
	) -> Data? {
		let size = image.size
		guard size.width > 0 && size.height > 0 else { return nil }

		let targetSize: CGSize
		if size.width <= maxSize.width && size.height <= maxSize.height {
			targetSize = size
		} else {
			let widthRatio = maxSize.width / size.width
			let heightRatio = maxSize.height / size.height
			let scaleFactor = min(widthRatio, heightRatio)
			targetSize = CGSize(width: size.width * scaleFactor, height: size.height * scaleFactor)
		}

		#if os(iOS) || os(tvOS) || os(watchOS)
		let renderer = UIGraphicsImageRenderer(size: targetSize)
		let resizedImage = renderer.image { _ in
			image.draw(in: CGRect(origin: .zero, size: targetSize))
		}
		return resizedImage.jpegData(compressionQuality: compressionQuality)
		#elseif os(macOS)
		guard let resized = image.resized(to: targetSize) else { return nil }
		return resized.jpegData(compressionQuality: compressionQuality)
		#endif
	}

    /// Resizes and compresses image to PNG data in a single pass for optimal performance
    /// This preserves alpha channel and is lossless, making it ideal for images with transparency
    /// - Parameters:
    ///   - image: The original Image to resize and compress
    ///   - maxSize: Maximum dimensions in points (default: 500×500pt for cache optimization)
    /// - Returns: PNG data of the resized and compressed image, or nil if compression fails
	static func resizeAndCompressToPNG(
		_ image: Image,
		maxSize: CGSize = CGSize(width: cacheOptimizedSize, height: cacheOptimizedSize)
	) -> Data? {
		let size = image.size
		guard size.width > 0 && size.height > 0 else { return nil }

		let targetSize: CGSize
		if size.width <= maxSize.width && size.height <= maxSize.height {
			targetSize = size
		} else {
			let widthRatio = maxSize.width / size.width
			let heightRatio = maxSize.height / size.height
			let scaleFactor = min(widthRatio, heightRatio)
			targetSize = CGSize(width: size.width * scaleFactor, height: size.height * scaleFactor)
		}

		#if os(iOS) || os(tvOS) || os(watchOS)
		let renderer = UIGraphicsImageRenderer(size: targetSize)
		let resizedImage = renderer.image { _ in
			image.draw(in: CGRect(origin: .zero, size: targetSize))
		}
		return resizedImage.pngData()
		#elseif os(macOS)
		guard let resized = image.resized(to: targetSize) else { return nil }
		return resized.pngData()
		#endif
	}
}
