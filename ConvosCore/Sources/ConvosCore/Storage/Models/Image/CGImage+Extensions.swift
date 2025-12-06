import ImageIO
import UniformTypeIdentifiers

extension CGImage {
	public func jpegData(compressionQuality: CGFloat) -> Data? {
		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(
			data as CFMutableData,
			UTType.jpeg.identifier as CFString,
			1,
			nil
		) else { return nil }

		let options: [CFString: Any] = [
			kCGImageDestinationLossyCompressionQuality: compressionQuality
		]

		CGImageDestinationAddImage(destination, self, options as CFDictionary)
		guard CGImageDestinationFinalize(destination) else { return nil }
		return data as Data
	}
}
