#if os(macOS)
import AppKit

import ImageIO
import UniformTypeIdentifiers

extension NSImage {
	public var width: CGFloat {
		self.size.width
	}

	public var height: CGFloat {
		self.size.height
	}

	func resized(to targetSize: CGSize) -> NSImage? {
		guard targetSize.width > 0, targetSize.height > 0 else { return nil }

		// Create a new NSImage with the target size
		let newImage = NSImage(size: targetSize)
		newImage.lockFocus()
		defer { newImage.unlockFocus() }

		// Draw the original image into the new size
		let rect = CGRect(
			origin: .zero,
			size: targetSize
		)
		self.draw(
			in: rect,
			from: .zero,
			operation: .copy,
			fraction: 1.0
		)

		return newImage
	}

	func pngData() -> Data? {
		// Try to get a CGImage first for best fidelity
		var rect = CGRect(origin: .zero, size: self.size)
		let scale = NSScreen.main?.backingScaleFactor ?? 1.0
		rect.size.width *= scale
		rect.size.height *= scale
		let cgImage = self.cgImage(forProposedRect: &rect, context: nil, hints: nil)

		let data = NSMutableData()
		guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }

		if let cg = cgImage {
			CGImageDestinationAddImage(destination, cg, nil)
		} else if let tiff = self.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let cg = rep.cgImage {
			CGImageDestinationAddImage(destination, cg, nil)
		} else {
			return nil
		}

		guard CGImageDestinationFinalize(destination) else { return nil }
		return data as Data
	}

	public func asCgImage() -> CGImage? {
		// Try to get a CGImage directly from NSImage; if unavailable (e.g., PDF/vector-backed), rasterize it.
		if let cg = self.cgImage(forProposedRect: nil, context: nil, hints: nil) {
			return cg
		}
		return self.rasterizedCGImage()
	}

	public var scale: CGFloat {
		// Derive scale from pixel dimensions when possible; fallback to screen scale or 1.0
		let sizeInPoints = self.size
		if let rep = self.bestRepresentation(for: NSRect(origin: .zero, size: sizeInPoints), context: nil, hints: nil) {
			let pixelWidth = CGFloat(rep.pixelsWide)
			let scaleX = sizeInPoints.width > 0 ? pixelWidth / sizeInPoints.width : 0
			if scaleX > 0 {
				return scaleX
			}
		}
		return NSScreen.main?.backingScaleFactor ?? 1.0
	}

	public static func fromCgImage(_ cgImage: CGImage, scale: CGFloat) -> NSImage {
		let size = NSSize(width: cgImage.width, height: cgImage.height)
		let image = NSImage(size: size)
		image.addRepresentation(NSBitmapImageRep(cgImage: cgImage))
		return image
	}

	func jpegData(compressionQuality: CGFloat) -> Data? {
		// Get a CGImage from the NSImage
		guard let cgImage = asCgImage() else {
			// If cgImage is nil (e.g., NSImage backed by PDF/vector), draw into a bitmap first
			return self.rasterizedCGImage()?.jpegData(compressionQuality: compressionQuality)
		}
		return cgImage.jpegData(compressionQuality: compressionQuality)
	}

	public func rasterizedCGImage() -> CGImage? {
		// Determine size in pixels
		let size = self.size
		let scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0
		let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)

		guard let context = CGContext(
			data: nil,
			width: Int(pixelSize.width),
			height: Int(pixelSize.height),
			bitsPerComponent: 8,
			bytesPerRow: 0,
			space: CGColorSpaceCreateDeviceRGB(),
			bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
		) else {
			return nil
		}

		context.interpolationQuality = .high
		context.scaleBy(x: scale, y: scale)

		// Flip to draw like AppKit coordinates
		context.translateBy(x: 0, y: size.height)
		context.scaleBy(x: 1, y: -1)

		// Draw the NSImage into the context
		let rect = CGRect(origin: .zero, size: size)
		self.draw(in: rect)

		return context.makeImage()
	}
}
#endif
