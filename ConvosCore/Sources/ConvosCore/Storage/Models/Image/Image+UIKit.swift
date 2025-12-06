#if os(iOS) || os(tvOS) || os(watchOS)
import UIKit
extension UIImage {
	public static func fromCgImage(_ cgImage: CGImage, scale: CGFloat) -> UIImage {
		UIImage(cgImage: cgImage, scale: scale, orientation: .up)
	}

	public func asCgImage() -> CGImage? {
		self.cgImage
	}
}
#endif
