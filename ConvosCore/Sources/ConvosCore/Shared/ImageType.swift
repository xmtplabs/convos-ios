#if os(macOS)
import AppKit
public typealias ImageType = NSImage
#elseif os(iOS) || os(tvOS) || os(watchOS)
import UIKit
public typealias ImageType = UIImage
#endif

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

extension ImageType {
    func crossPlatformJPEGData(compressionQuality: CGFloat = 0.8) -> Data? {
        #if os(macOS)
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
        #else
        return jpegData(compressionQuality: compressionQuality)
        #endif
    }

    /// Downscale to a JPEG thumbnail capped at `maxPixelSize` on the longest
    /// edge. ImageIO decodes straight at the target size (the same fast path
    /// `UIImage.preparingThumbnail(of:)` uses), so a multi-megapixel photo
    /// never materializes at full resolution on the way to a small chip.
    func crossPlatformThumbnailJPEGData(maxPixelSize: Int, compressionQuality: CGFloat = 0.7) -> Data? {
        guard let sourceData = crossPlatformJPEGData(compressionQuality: 0.9) else { return nil }
        let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, sourceOptions as CFDictionary) else { return nil }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else { return nil }
        guard let mutableData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(mutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        let destinationOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: compressionQuality]
        CGImageDestinationAddImage(destination, thumbnail, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
