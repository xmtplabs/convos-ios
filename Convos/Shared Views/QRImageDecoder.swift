import CoreImage
import UIKit

/// Decodes the first QR payload found in a still image, used by the invite
/// screen's "Scan a screenshot" affordance to read a code the user picked
/// from their photo library. Runs the Core Image QR detector off the main
/// thread; mirrors the live scanner, which feeds its decoded string into the
/// same `handleScannedCode` handler.
enum QRImageDecoder {
    /// Returns the first decoded QR message string in `image`, or `nil` when
    /// no readable code is present.
    static func decode(_ image: UIImage) async -> String? {
        await Task.detached(priority: .userInitiated) {
            guard let ciImage = CIImage(image: image) else { return nil }
            let context = CIContext()
            let detector = CIDetector(
                ofType: CIDetectorTypeQRCode,
                context: context,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
            )
            let features = detector?.features(in: ciImage) ?? []
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
}
