#if os(macOS)
import AppKit
public typealias ImageType = NSImage
#elseif os(iOS) || os(tvOS) || os(watchOS)
import UIKit
public typealias ImageType = UIImage
#endif

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
}
