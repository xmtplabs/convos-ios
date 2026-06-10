#if os(macOS)
import AppKit
#elseif os(iOS) || os(tvOS) || os(watchOS)
import UIKit
#endif

import CoreGraphics
import Foundation
import ImageIO

/// Decodes images with a hard cap on the decoded bitmap's dimensions.
///
/// Network payloads and decrypted attachments are sender-controlled: a tiny
/// encoded file can decode to a gigabyte-scale bitmap (decompression bomb),
/// and even honest full-resolution photos decode to tens of megabytes each.
/// Decoding through ImageIO's thumbnail API bounds the bitmap to
/// `maxPixelSize` on the longest edge, so a burst of image loads (e.g.
/// background sync) cannot exhaust process memory the way unbounded
/// `UIImage(data:)` decodes can.
public enum BoundedImageDecode {
    /// Matches the sender-side photo attachment cap (see
    /// `ImageCompression.compressForPhotoAttachment`), so images sent by
    /// Convos clients decode pixel-perfect while oversized payloads from
    /// other clients are clamped to a display-quality size.
    public static let defaultMaxPixelSize: Int = 2048

    /// Decode encoded image bytes, clamped to `maxPixelSize` on the longest edge.
    public static func image(from data: Data, maxPixelSize: Int = defaultMaxPixelSize) -> ImageType? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else { return nil }
        return image(from: source, maxPixelSize: maxPixelSize)
    }

    /// Decode an image file, clamped to `maxPixelSize` on the longest edge.
    /// Reads straight from the file, so the encoded bytes are never fully
    /// buffered in memory.
    public static func image(contentsOf url: URL, maxPixelSize: Int = defaultMaxPixelSize) -> ImageType? {
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else { return nil }
        return image(from: source, maxPixelSize: maxPixelSize)
    }

    private static func image(from source: CGImageSource, maxPixelSize: Int) -> ImageType? {
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        #else
        return UIImage(cgImage: cgImage)
        #endif
    }
}
