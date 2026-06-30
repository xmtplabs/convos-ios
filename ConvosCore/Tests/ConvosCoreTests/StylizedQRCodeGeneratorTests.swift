#if canImport(UIKit)
import ConvosCoreiOS
import CoreImage
import Foundation
import Testing
import UIKit
import Vision

struct StylizedQRCodeGeneratorTests {
    private let sampleString: String = "https://local.convos.org/v2?i=stylized-qr-test-token"

    @Test
    func generatesNonNilImageForSampleString() {
        let options = StylizedQRCodeGenerator.Options(
            size: 280.0,
            scale: 2.0,
            centerImage: nil
        )
        let image = StylizedQRCodeGenerator.generate(from: sampleString, options: options)
        #expect(image != nil)
        if let image {
            #expect(image.size.width > 0)
            #expect(image.size.height > 0)
        }
    }

    /// The default render uses rounded ring-and-pupil finder eyes. Assert it
    /// round-trips through both decoders across payload sizes, with and without
    /// a center logo. Vision is the better proxy for the real camera scanner;
    /// CIDetector is the more conservative legacy decoder.
    @Test(arguments: [
        "convos",
        "https://local.convos.org/v2?i=stylized-qr-test-token",
        "https://local.convos.org/v2?i=" + String(repeating: "x", count: 120),
    ])
    func defaultRoundedEyeImageDecodesBackToInput(payload: String) {
        for withLogo in [false, true] {
            let logo: UIImage? = withLogo ? UIImage(systemName: "person.crop.circle.fill") : nil
            let options = StylizedQRCodeGenerator.Options(
                size: 280.0,
                scale: 3.0,
                foregroundColor: .black,
                backgroundColor: .white,
                centerImage: logo
            )
            #expect(options.roundedFinderEyes)
            guard let cgImage = StylizedQRCodeGenerator.generate(from: payload, options: options)?.cgImage else {
                Issue.record("Expected a CGImage-backed stylized QR for \(payload)")
                continue
            }
            #expect(ciDecode(cgImage) == payload)
            #expect(visionDecode(cgImage) == payload)
        }
    }

    private func ciDecode(_ cgImage: CGImage) -> String? {
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: CIImage(cgImage: cgImage)) ?? []
        return (features.first as? CIQRCodeFeature)?.messageString
    }

    private func visionDecode(_ cgImage: CGImage) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        return (request.results?.first as? VNBarcodeObservation)?.payloadStringValue
    }

    @Test
    func matrixIsSquareAndNonTrivial() {
        let matrix = StylizedQRCodeGenerator.matrix(for: sampleString)
        #expect(matrix != nil)
        guard let matrix else { return }
        // A QR symbol is at least 21x21 modules (version 1).
        #expect(matrix.size >= 21)
        #expect(matrix.modules.count == matrix.size * matrix.size)
    }

    @Test
    func matrixHasThreeFinderPatterns() {
        let matrix = StylizedQRCodeGenerator.matrix(for: sampleString)
        #expect(matrix != nil)
        guard let matrix else { return }
        let size = matrix.size
        let finderOrigins: [(row: Int, column: Int)] = [
            (0, 0),
            (0, size - 7),
            (size - 7, 0),
        ]
        for origin in finderOrigins {
            #expect(isFinderPattern(matrix: matrix, originRow: origin.row, originColumn: origin.column))
        }
        // The bottom-right corner must not carry a finder pattern.
        #expect(!isFinderPattern(matrix: matrix, originRow: size - 7, originColumn: size - 7))
    }

    /// Verifies the canonical 7x7 finder structure at a corner: a solid outer
    /// ring (all border modules set), a one-module clear band, and a solid
    /// 3x3 center.
    private func isFinderPattern(matrix: StylizedQRCodeGenerator.Matrix, originRow: Int, originColumn: Int) -> Bool {
        for offset in 0..<7 {
            guard matrix.isSet(row: originRow, column: originColumn + offset),
                  matrix.isSet(row: originRow + 6, column: originColumn + offset),
                  matrix.isSet(row: originRow + offset, column: originColumn),
                  matrix.isSet(row: originRow + offset, column: originColumn + 6) else {
                return false
            }
        }
        for rowOffset in 1...5 {
            guard !matrix.isSet(row: originRow + rowOffset, column: originColumn + 1),
                  !matrix.isSet(row: originRow + rowOffset, column: originColumn + 5) else {
                return false
            }
        }
        for rowOffset in 2...4 {
            for columnOffset in 2...4 where !matrix.isSet(row: originRow + rowOffset, column: originColumn + columnOffset) {
                return false
            }
        }
        return true
    }
}
#endif
