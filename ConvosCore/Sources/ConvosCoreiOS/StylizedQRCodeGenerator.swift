#if canImport(UIKit)
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import UIKit

/// Generates the stylized QR code the invite screen requires: rounded "dot"
/// data modules, three ring-and-pupil finder eyes in the corners, and a
/// circular center cut-out that holds the convo avatar / emoji.
///
/// The plain `CIQRCodeGenerator` only produces square modules, so this type
/// extracts the boolean module matrix from CoreImage and draws every module
/// itself with Core Graphics. The matrix is generated at error-correction
/// level `H` (~30% recovery) so the center logo cut-out never breaks
/// scannability.
public enum StylizedQRCodeGenerator {
    public struct Options: @unchecked Sendable {
        /// Target point size of the square output image.
        public let size: CGFloat
        /// Render scale (pixels per point). Defaults to 3x for retina.
        public let scale: CGFloat
        /// Color of the modules and finder eyes.
        public let foregroundColor: UIColor
        /// Tile background color drawn behind the modules.
        public let backgroundColor: UIColor
        /// Diameter of the circular center logo as a fraction of the image
        /// (0.0 disables the cut-out). The Figma logo is ~76pt over a 280pt
        /// tile, i.e. ~0.27.
        public let centerLogoFraction: CGFloat
        /// Optional image rendered, clipped to a circle, in the center.
        public let centerImage: UIImage?
        /// Draw the three finder patterns as the Figma rounded ring-and-pupil
        /// "eyes" (rounded-corner concentric squares) instead of crisp square
        /// modules. Defaults to `true`: rounded-corner squares keep the
        /// finder's 1:1:3:1:1 proportions, so both `CIDetector` and Vision
        /// decode them reliably. (An earlier attempt drew the eyes as circles,
        /// which destroyed the proportions and broke decoding; rounded squares
        /// do not.)
        public let roundedFinderEyes: Bool
        /// Corner radius of the rounded finder eyes as a fraction of one
        /// module's side. ~0.30 reads as clearly rounded while keeping the
        /// squareness obvious; round-trip decoding holds well past this.
        public let finderEyeCornerRadiusFactor: CGFloat

        public init(
            size: CGFloat = 280.0,
            scale: CGFloat = 3.0,
            foregroundColor: UIColor = .black,
            backgroundColor: UIColor = .clear,
            centerLogoFraction: CGFloat = 0.27,
            centerImage: UIImage? = nil,
            roundedFinderEyes: Bool = true,
            finderEyeCornerRadiusFactor: CGFloat = 0.30
        ) {
            self.size = size
            self.scale = scale
            self.foregroundColor = foregroundColor
            self.backgroundColor = backgroundColor
            self.centerLogoFraction = centerLogoFraction
            self.centerImage = centerImage
            self.roundedFinderEyes = roundedFinderEyes
            self.finderEyeCornerRadiusFactor = finderEyeCornerRadiusFactor
        }
    }

    /// A boolean module grid plus its side length in modules.
    public struct Matrix: Sendable {
        public let size: Int
        public let modules: [Bool]

        public func isSet(row: Int, column: Int) -> Bool {
            guard row >= 0, row < size, column >= 0, column < size else { return false }
            return modules[row * size + column]
        }
    }

    private static let context: CIContext = CIContext(options: [.cacheIntermediates: false])

    /// Builds the boolean QR module matrix for `string` at the given
    /// error-correction level. Cross-platform (CoreImage), so it is unit
    /// testable without UIKit drawing.
    public static func matrix(for string: String, correctionLevel: String = "H") -> Matrix? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = correctionLevel
        guard let output = filter.outputImage else { return nil }

        let extent = output.extent
        let moduleCount = Int(extent.width.rounded())
        guard moduleCount > 0 else { return nil }

        let bytesPerRow = moduleCount
        var pixels = [UInt8](repeating: 0, count: moduleCount * moduleCount)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let bitmapInfo = CGImageAlphaInfo.none.rawValue
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let cgContext = CGContext(
                      data: base,
                      width: moduleCount,
                      height: moduleCount,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  ),
                  let cgImage = context.createCGImage(output, from: extent) else {
                return false
            }
            cgContext.interpolationQuality = .none
            cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: moduleCount, height: moduleCount))
            return true
        }
        guard drawn else { return nil }

        // Drawing the CoreImage symbol into a top-left-origin CGContext lands
        // row 0 at the top already. The symbol carries a one-module quiet zone
        // on every side, so trim to the bounding box of set modules to return
        // the bare symbol with finder patterns anchored at its corners.
        func isDark(row: Int, column: Int) -> Bool {
            pixels[row * moduleCount + column] < 128
        }

        var minRow = moduleCount
        var maxRow = -1
        var minColumn = moduleCount
        var maxColumn = -1
        for row in 0..<moduleCount {
            for column in 0..<moduleCount where isDark(row: row, column: column) {
                minRow = min(minRow, row)
                maxRow = max(maxRow, row)
                minColumn = min(minColumn, column)
                maxColumn = max(maxColumn, column)
            }
        }
        guard maxRow >= minRow, maxColumn >= minColumn else { return nil }

        let side = maxRow - minRow + 1
        guard maxColumn - minColumn + 1 == side else { return nil }

        var modules = [Bool](repeating: false, count: side * side)
        for row in 0..<side {
            for column in 0..<side {
                modules[row * side + column] = isDark(row: minRow + row, column: minColumn + column)
            }
        }
        return Matrix(size: side, modules: modules)
    }

    /// Generates the stylized QR image, or nil if the matrix cannot be built.
    public static func generate(from string: String, options: Options = .init()) -> UIImage? {
        guard let matrix = matrix(for: string) else { return nil }
        return draw(matrix: matrix, options: options)
    }

    /// Generates the stylized QR image off the main thread.
    public static func generate(from string: String, options: Options = .init()) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            generate(from: string, options: options)
        }.value
    }

    private static func draw(matrix: Matrix, options: Options) -> UIImage? {
        let pointSize = options.size
        let format = UIGraphicsImageRendererFormat()
        format.scale = options.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: pointSize, height: pointSize),
            format: format
        )

        let layout = Layout(matrix: matrix, options: options)

        return renderer.image { rendererContext in
            let cgContext = rendererContext.cgContext
            if options.backgroundColor != .clear {
                cgContext.setFillColor(options.backgroundColor.cgColor)
                cgContext.fill(CGRect(x: 0, y: 0, width: pointSize, height: pointSize))
            }
            cgContext.setFillColor(options.foregroundColor.cgColor)

            drawDataModules(in: cgContext, matrix: matrix, layout: layout)
            drawFinderEyes(in: cgContext, layout: layout, options: options)
            drawCenterLogo(in: cgContext, options: options, pointSize: pointSize, center: layout.center)
        }
    }

    /// Precomputed pixel geometry shared by the draw passes.
    private struct Layout {
        let moduleSize: CGFloat
        let dotInset: CGFloat
        let center: CGPoint
        let centerExclusionRadius: CGFloat
        let finderOrigins: [(row: Int, column: Int)]

        init(matrix: Matrix, options: Options) {
            let pointSize = options.size
            let moduleCount = matrix.size
            self.moduleSize = pointSize / CGFloat(moduleCount)
            self.dotInset = moduleSize * 0.10
            self.center = CGPoint(x: pointSize / 2.0, y: pointSize / 2.0)
            self.centerExclusionRadius = options.centerLogoFraction > 0
                ? pointSize * options.centerLogoFraction / 2.0 + moduleSize
                : 0.0
            self.finderOrigins = [
                (0, 0),
                (0, moduleCount - 7),
                (moduleCount - 7, 0),
            ]
        }
    }

    private static func drawDataModules(in cgContext: CGContext, matrix: Matrix, layout: Layout) {
        let moduleCount = matrix.size
        let moduleSize = layout.moduleSize
        let dotInset = layout.dotInset
        let center = layout.center
        let exclusionRadius = layout.centerExclusionRadius
        let diameter: CGFloat = moduleSize - dotInset * 2.0
        for row in 0..<moduleCount {
            for column in 0..<moduleCount where matrix.isSet(row: row, column: column) {
                guard !isFinderModule(row: row, column: column, origins: layout.finderOrigins) else { continue }
                let originX: CGFloat = CGFloat(column) * moduleSize + dotInset
                let originY: CGFloat = CGFloat(row) * moduleSize + dotInset
                let dotCenterX: CGFloat = originX + diameter / 2.0
                let dotCenterY: CGFloat = originY + diameter / 2.0
                if exclusionRadius > 0 {
                    let dx: CGFloat = dotCenterX - center.x
                    let dy: CGFloat = dotCenterY - center.y
                    if (dx * dx + dy * dy) < (exclusionRadius * exclusionRadius) {
                        continue
                    }
                }
                cgContext.fillEllipse(in: CGRect(x: originX, y: originY, width: diameter, height: diameter))
            }
        }
    }

    private static func drawFinderEyes(in cgContext: CGContext, layout: Layout, options: Options) {
        cgContext.setFillColor(options.foregroundColor.cgColor)
        guard options.roundedFinderEyes else {
            drawSquareFinders(in: cgContext, layout: layout)
            return
        }
        drawRoundedFinderEyes(
            in: cgContext,
            layout: layout,
            foregroundColor: options.foregroundColor,
            cornerRadiusFactor: options.finderEyeCornerRadiusFactor
        )
    }

    /// Draws the finder patterns as their exact square modules (outer 7x7 ring
    /// + 3x3 pupil). This keeps the 1:1:3:1:1 finder ratio crisp so scanners
    /// reliably lock onto the code. It is the default finder rendering.
    private static func drawSquareFinders(in cgContext: CGContext, layout: Layout) {
        let moduleSize = layout.moduleSize
        for origin in layout.finderOrigins {
            for rowOffset in 0..<7 {
                for columnOffset in 0..<7 {
                    let onBorder: Bool = rowOffset == 0 || rowOffset == 6 || columnOffset == 0 || columnOffset == 6
                    let inPupil: Bool = (2...4).contains(rowOffset) && (2...4).contains(columnOffset)
                    guard onBorder || inPupil else { continue }
                    let rect = CGRect(
                        x: CGFloat(origin.column + columnOffset) * moduleSize,
                        y: CGFloat(origin.row + rowOffset) * moduleSize,
                        width: moduleSize,
                        height: moduleSize
                    )
                    cgContext.fill(rect)
                }
            }
        }
    }

    /// Draws the finder patterns as rounded-corner concentric squares (the
    /// Figma ring-and-pupil "eyes"): a rounded-rect outer ring, a cleared
    /// rounded-rect separator band, and a rounded-rect pupil. Rounding the
    /// corners of squares preserves the finder's 1:1:3:1:1 proportions, so
    /// both CIDetector and Vision still decode the code. The separator band is
    /// cleared (not filled white) so the tile color shows through, matching the
    /// transparent gaps left between the data dots.
    private static func drawRoundedFinderEyes(
        in cgContext: CGContext,
        layout: Layout,
        foregroundColor: UIColor,
        cornerRadiusFactor: CGFloat
    ) {
        let moduleSize = layout.moduleSize
        let outerSide: CGFloat = moduleSize * 7.0
        let ringThickness: CGFloat = moduleSize
        let pupilSide: CGFloat = moduleSize * 3.0
        let outerRadius: CGFloat = moduleSize * cornerRadiusFactor
        let bandRadius: CGFloat = max(0.0, outerRadius - ringThickness * 0.6)
        let pupilRadius: CGFloat = max(0.0, outerRadius - ringThickness)
        for origin in layout.finderOrigins {
            let originX: CGFloat = CGFloat(origin.column) * moduleSize
            let originY: CGFloat = CGFloat(origin.row) * moduleSize
            let outerRect = CGRect(x: originX, y: originY, width: outerSide, height: outerSide)
            let bandRect = outerRect.insetBy(dx: ringThickness, dy: ringThickness)
            let pupilOrigin: CGFloat = (outerSide - pupilSide) / 2.0
            let pupilRect = CGRect(
                x: originX + pupilOrigin,
                y: originY + pupilOrigin,
                width: pupilSide,
                height: pupilSide
            )
            cgContext.setFillColor(foregroundColor.cgColor)
            fillRoundedRect(in: cgContext, rect: outerRect, radius: outerRadius)
            cgContext.setBlendMode(.clear)
            fillRoundedRect(in: cgContext, rect: bandRect, radius: bandRadius)
            cgContext.setBlendMode(.normal)
            cgContext.setFillColor(foregroundColor.cgColor)
            fillRoundedRect(in: cgContext, rect: pupilRect, radius: pupilRadius)
        }
    }

    private static func fillRoundedRect(in cgContext: CGContext, rect: CGRect, radius: CGFloat) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        cgContext.beginPath()
        cgContext.addPath(path)
        cgContext.fillPath()
    }

    private static func drawCenterLogo(
        in cgContext: CGContext,
        options: Options,
        pointSize: CGFloat,
        center: CGPoint
    ) {
        guard options.centerLogoFraction > 0 else { return }
        let logoDiameter: CGFloat = pointSize * options.centerLogoFraction
        let logoRect = CGRect(
            x: center.x - logoDiameter / 2.0,
            y: center.y - logoDiameter / 2.0,
            width: logoDiameter,
            height: logoDiameter
        )
        cgContext.setBlendMode(.clear)
        cgContext.fillEllipse(in: logoRect)
        cgContext.setBlendMode(.normal)
        cgContext.setFillColor(UIColor.white.cgColor)
        cgContext.fillEllipse(in: logoRect)
        guard let centerImage = options.centerImage else { return }
        cgContext.saveGState()
        cgContext.addEllipse(in: logoRect)
        cgContext.clip()
        centerImage.draw(in: logoRect)
        cgContext.restoreGState()
    }

    private static func isFinderModule(
        row: Int,
        column: Int,
        origins: [(row: Int, column: Int)]
    ) -> Bool {
        for origin in origins {
            if row >= origin.row, row < origin.row + 7,
               column >= origin.column, column < origin.column + 7 {
                return true
            }
        }
        return false
    }
}
#endif
