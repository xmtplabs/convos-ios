import CoreImage
import UIKit

/// Decodes the first QR payload found in a still image, used by the invite
/// screen's "Or scan from camera roll" affordance to read a code the user picked
/// from their photo library. Runs the Core Image QR detector off the main
/// thread; mirrors the live scanner, which feeds its decoded string into the
/// same `handleScannedCode` handler.
enum QRImageDecoder {
    /// Returns the first decoded QR message string in `image`, or `nil` when
    /// no readable code is present.
    static func decode(_ image: UIImage) async -> String? {
        // CIImage(image:) carries the bitmap in its stored orientation, not
        // upright, so a screenshot saved with an EXIF rotation reads as a
        // rotated matrix the detector can't decode. Resolve the EXIF
        // orientation (1-8) the detector expects so it reads the code the
        // right way up; an upright screenshot resolves to 1 and is unaffected.
        let orientation = exifOrientation(for: image.imageOrientation)
        return await Task.detached(priority: .userInitiated) {
            guard let ciImage = CIImage(image: image) else { return nil }
            let context = CIContext()
            let detector = CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: context,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
            )
            let options: [String: Any] = [CIDetectorImageOrientation: orientation]
            let features = detector?.features(in: ciImage, options: options) ?? []
            for feature in features {
                if let qrFeature = feature as? CIQRCodeFeature,
                   let message = qrFeature.messageString,
                   !message.isEmpty {
                    return message
                }
            }
            return nil
        }.value
    }

    /// Maps a `UIImage.Orientation` to the EXIF orientation value (1-8) used
    /// by `CIDetectorImageOrientation`. The two enumerations use different
    /// raw values, so the cases are translated explicitly.
    private static func exifOrientation(for orientation: UIImage.Orientation) -> Int {
        switch orientation {
        case .up: return 1
        case .upMirrored: return 2
        case .down: return 3
        case .downMirrored: return 4
        case .leftMirrored: return 5
        case .right: return 6
        case .rightMirrored: return 7
        case .left: return 8
        @unknown default: return 1
        }
    }
}
