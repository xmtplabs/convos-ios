import CoreImage.CIFilterBuiltins
import CryptoKit
import Foundation
#if os(macOS)
import AppKit
public typealias Color = NSColor
extension Color {
	public var ciColor: CIColor {
		CIColor(color: self) ?? .red
	}
}
#elseif os(iOS) || os(tvOS) || os(watchOS)
import UIKit
public typealias Color = UIColor
extension Color {
	public var ciColor: CIColor {
		CIColor(color: self)
	}
}
#endif

/// A reusable QR code generator that can be used throughout the app
///
/// This generator automatically caches generated QR codes based on their content and options.
/// Different options (colors, size, etc.) for the same content will be cached separately.
public enum QRCodeGenerator {
    public struct Options {
        /// The scale factor to use for rendering (defaults to main screen scale)
        public let scale: CGFloat
        /// The target display size in points
        public let displaySize: CGFloat
        /// Whether to use rounded markers
        public let roundedMarkers: Bool
        /// Whether to use rounded data cells
        public let roundedData: Bool
        /// The size of the center space (0.0 to 1.0)
        public let centerSpaceSize: Float
        /// Error correction level: "L", "M", "Q", "H"
        public let correctionLevel: String
        /// Foreground color
        public let foregroundColor: CIColor
        /// Background color
        public let backgroundColor: CIColor

        public init(
            scale: CGFloat? = nil,
            displaySize: CGFloat = 220,
            roundedMarkers: Bool = true,
            roundedData: Bool = true,
            centerSpaceSize: Float = 0.25,
            correctionLevel: String = "Q",
            foregroundColor: Color = .black,
            backgroundColor: Color = .white
        ) {
            self.scale = scale ?? 3.0 // Default to 3x if not provided
            self.displaySize = displaySize
            self.roundedMarkers = roundedMarkers
            self.roundedData = roundedData
            self.centerSpaceSize = centerSpaceSize
            self.correctionLevel = correctionLevel
			self.foregroundColor = foregroundColor.ciColor
			self.backgroundColor = backgroundColor.ciColor
        }

        /// Configuration for QR codes in light mode
        public static var qrCodeLight: Options {
            Options(
                scale: 3.0, // Default to 3x for retina displays
                displaySize: 220,
                foregroundColor: .black, // Dark QR code
                backgroundColor: .clear  // Light background
            )
        }

        /// Configuration for QR codes in dark mode
        public static var qrCodeDark: Options {
            Options(
                scale: 3.0, // Default to 3x for retina displays
                displaySize: 220,
                foregroundColor: .white, // Light QR code
                backgroundColor: .clear  // Dark background
            )
        }
    }

    /// Custom hash key for options that includes all relevant properties
    private struct OptionsHashKey: Hashable {
        let scale: CGFloat
        let displaySize: CGFloat
        let roundedMarkers: Bool
        let roundedData: Bool
        let centerSpaceSize: Float
        let correctionLevel: String
        let foregroundColorHex: String
        let backgroundColorHex: String

        /// Converts a color component (0-1) to a 2-digit hex string (00-FF)
        private static func colorComponentToHex(_ value: CGFloat) -> String {
            let clamped = max(0, min(1, value))
            let intValue = Int(round(clamped * 255))
            return String(format: "%02X", intValue)
        }

        /// Converts RGBA color components to a hex string (RRGGBBAA format)
        private static func colorToHex(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> String {
            return colorComponentToHex(red) +
                   colorComponentToHex(green) +
                   colorComponentToHex(blue) +
                   colorComponentToHex(alpha)
        }

        init(options: Options) {
            // Normalize scale to 3.0 for consistent caching
            self.scale = 3.0
            // Round displaySize to handle any floating point variations
            self.displaySize = round(options.displaySize * 100) / 100
            self.roundedMarkers = options.roundedMarkers
            self.roundedData = options.roundedData
            // Round centerSpaceSize to handle floating point variations
            self.centerSpaceSize = Float(round(options.centerSpaceSize * 100) / 100)
            self.correctionLevel = options.correctionLevel
            // Convert colors to hex strings for consistent, stable hashing
            self.foregroundColorHex = Self.colorToHex(
                red: options.foregroundColor.red,
                green: options.foregroundColor.green,
                blue: options.foregroundColor.blue,
                alpha: options.foregroundColor.alpha
            )
            self.backgroundColorHex = Self.colorToHex(
                red: options.backgroundColor.red,
                green: options.backgroundColor.green,
                blue: options.backgroundColor.blue,
                alpha: options.backgroundColor.alpha
            )
        }
    }

    /// Creates a cache key based on the string and options
    /// Normalizes scale to 3.0 for consistent caching across different display scales
    /// Uses SHA256 for deterministic hashing (unlike Swift's Hasher which is seeded randomly)
    private static func cacheKey(for string: String, options: Options) -> String {
        // Normalize scale to 3.0 for cache key to ensure consistent caching
        // while still rendering at the requested scale
        let normalizedOptions = options.withNormalizedScale()
        let hashKey = OptionsHashKey(options: normalizedOptions)

        // Create a deterministic string representation of all cache key components
        let cacheKeyString = """
        string:\(string)
        scale:\(hashKey.scale)
        displaySize:\(hashKey.displaySize)
        roundedMarkers:\(hashKey.roundedMarkers)
        roundedData:\(hashKey.roundedData)
        centerSpaceSize:\(hashKey.centerSpaceSize)
        correctionLevel:\(hashKey.correctionLevel)
        foregroundColor:\(hashKey.foregroundColorHex)
        backgroundColor:\(hashKey.backgroundColorHex)
        """

        // Use SHA256 for deterministic hashing (consistent across app launches)
        guard let inputData = cacheKeyString.data(using: .utf8) else {
            // Fallback: use a hash of just the string if UTF-8 conversion fails (should never happen)
            let fallbackData = string.data(using: .utf8) ?? Data()
            let hash = SHA256.hash(data: fallbackData)
            let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
            return "qr_\(hashString)"
        }
        let hash = SHA256.hash(data: inputData)
        let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
        let key = "qr_\(hashString)"

        return key
    }

    /// Generates a QR code image from the given string
    /// - Parameters:
    ///   - from: The string to encode
    ///   - options: Generation options
    /// - Returns: The generated QR code image, or nil if generation fails
    public static func generate(from string: String, options: Options = .init()) -> Image? {
        let cacheKey = cacheKey(for: string, options: options)

        // Check memory cache first
        if let cachedImage = ImageCache.shared.image(for: cacheKey, imageFormat: .png) {
            return cachedImage
        }

        let context = CIContext()
        let filter = CIFilter.roundedQRCodeGenerator()

        filter.message = Data(string.utf8)
        filter.roundedMarkers = options.roundedMarkers ? 1 : 0
        filter.roundedData = options.roundedData
        filter.centerSpaceSize = options.centerSpaceSize
        filter.correctionLevel = options.correctionLevel
        filter.color1 = options.foregroundColor
        filter.color0 = options.backgroundColor

        guard let outputImage = filter.outputImage else { return nil }

        let outputExtent = outputImage.extent
        let baseSize = max(outputExtent.width, outputExtent.height)

        // Normalize scale to 3.0 for consistent caching (matches cache key normalization)
        // This ensures all QR codes are cached at the same resolution regardless of display scale
        let normalizedScale: CGFloat = 3.0
        let targetPixelSize = options.displaySize * normalizedScale
        let scaleFactor = targetPixelSize / baseSize

        let transform = CGAffineTransform(scaleX: scaleFactor, y: scaleFactor)
        let scaledImage = outputImage.transformed(by: transform)

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }
		let image = Image.fromCgImage(cgImage, scale: normalizedScale)

        // Cache the generated image (use PNG for QR codes to preserve transparency)
        ImageCache.shared.cacheImage(image, for: cacheKey, imageFormat: .png)

        return image
    }

    /// Generates a QR code asynchronously
    /// - Parameters:
    ///   - from: The string to encode
    ///   - options: Generation options
    /// - Returns: The generated QR code image, or nil if generation fails
    public static func generate(from string: String, options: Options = .init()) async -> Image? {
        let cacheKey = cacheKey(for: string, options: options)

        // Check cache first (use PNG for QR codes)
        if let cachedImage = await ImageCache.shared.imageAsync(for: cacheKey, imageFormat: .png) {
            Log.info("Returning cached QR for key: \(cacheKey)")
            return cachedImage
        }

        // Generate in background
        return await Task {
            generate(from: string, options: options)
        }.value
    }

    /// Pre-generates QR codes for both light and dark modes
    /// - Parameters:
    ///   - string: The string to encode
    ///   - scale: Optional scale factor (defaults to 3.0)
    /// - Returns: Tuple of (lightModeImage, darkModeImage)
    public static func pregenerate(from string: String, scale: CGFloat = 3.0) async -> (light: Image?, dark: Image?) {
        let lightOptions = Options(
            scale: scale,
            displaySize: 220,
            foregroundColor: .black,
            backgroundColor: .white
        )

        let darkOptions = Options(
            scale: scale,
            displaySize: 220,
            foregroundColor: .white,
            backgroundColor: .black
        )

        async let lightImage = generate(from: string, options: lightOptions)
        async let darkImage = generate(from: string, options: darkOptions)

        return await (lightImage, darkImage)
    }

    /// Clears a specific QR code from the cache
    /// - Parameters:
    ///   - string: The string content of the QR code
    ///   - options: The options used to generate the QR code
    public static func clearFromCache(string: String, options: Options = .init()) {
        let cacheKey = cacheKey(for: string, options: options)
        ImageCache.shared.removeImage(for: cacheKey)
    }

    /// Clears QR codes for both light and dark modes from cache
    /// - Parameter string: The string content of the QR code
    public static func clearFromCacheAllModes(string: String) {
        clearFromCache(string: string, options: Options.qrCodeLight)
        clearFromCache(string: string, options: Options.qrCodeDark)
    }
}

/// Extension to provide normalized scale for consistent caching
public extension QRCodeGenerator.Options {
    /// Returns a new Options instance with the scale normalized to 3.0
    /// This ensures consistent cache keys regardless of the original display scale
    func withNormalizedScale() -> QRCodeGenerator.Options {
        let foregroundUIColor = Color(
            red: foregroundColor.red,
            green: foregroundColor.green,
            blue: foregroundColor.blue,
            alpha: foregroundColor.alpha
        )
        let backgroundUIColor = Color(
            red: backgroundColor.red,
            green: backgroundColor.green,
            blue: backgroundColor.blue,
            alpha: backgroundColor.alpha
        )
        return QRCodeGenerator.Options(
            scale: 3.0,
            displaySize: displaySize,
            roundedMarkers: roundedMarkers,
            roundedData: roundedData,
            centerSpaceSize: centerSpaceSize,
            correctionLevel: correctionLevel,
            foregroundColor: foregroundUIColor,
            backgroundColor: backgroundUIColor
        )
    }
}
