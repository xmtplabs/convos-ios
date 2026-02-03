import CoreImage
import Foundation

/// Generates QR codes and renders them as ASCII art for terminal display
enum QRCode {
    /// Generate a QR code as ASCII art using block characters
    /// Each QR module becomes 2 characters wide for better aspect ratio
    static func generate(from string: String, compact: Bool = true) -> [String] {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            return ["[QR generation unavailable]"]
        }

        let data = Data(string.utf8)
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel") // Medium error correction

        guard let ciImage = filter.outputImage else {
            return ["[QR generation failed]"]
        }

        // Get the pixel data
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return ["[QR rendering failed]"]
        }

        let width = cgImage.width
        let height = cgImage.height

        // Create bitmap context to read pixels
        guard let dataProvider = cgImage.dataProvider,
              let pixelData = dataProvider.data,
              let bytes = CFDataGetBytePtr(pixelData) else {
            return ["[QR pixel access failed]"]
        }

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow

        if compact {
            // Use Unicode block characters to show 2 vertical pixels per character
            // ▀ (upper half), ▄ (lower half), █ (full block), (space)
            return renderCompact(
                bytes: bytes,
                width: width,
                height: height,
                bytesPerPixel: bytesPerPixel,
                bytesPerRow: bytesPerRow
            )
        } else {
            // Standard rendering: 2 chars per module for aspect ratio
            return renderStandard(
                bytes: bytes,
                width: width,
                height: height,
                bytesPerPixel: bytesPerPixel,
                bytesPerRow: bytesPerRow
            )
        }
    }

    private static func renderCompact(
        bytes: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerPixel: Int,
        bytesPerRow: Int
    ) -> [String] {
        var lines: [String] = []

        // Process 2 rows at a time
        var y = 0
        while y < height {
            var line = ""
            for x in 0..<width {
                let topBlack = isBlack(
                    bytes: bytes,
                    x: x,
                    y: y,
                    bytesPerPixel: bytesPerPixel,
                    bytesPerRow: bytesPerRow
                )
                let bottomBlack: Bool
                if y + 1 < height {
                    bottomBlack = isBlack(
                        bytes: bytes,
                        x: x,
                        y: y + 1,
                        bytesPerPixel: bytesPerPixel,
                        bytesPerRow: bytesPerRow
                    )
                } else {
                    bottomBlack = false
                }

                // Unicode block characters for combining two vertical pixels
                if topBlack && bottomBlack {
                    line += "█" // Full block
                } else if topBlack {
                    line += "▀" // Upper half
                } else if bottomBlack {
                    line += "▄" // Lower half
                } else {
                    line += " " // Space (white)
                }
            }
            lines.append(line)
            y += 2
        }

        return lines
    }

    private static func renderStandard(
        bytes: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerPixel: Int,
        bytesPerRow: Int
    ) -> [String] {
        var lines: [String] = []

        for y in 0..<height {
            var line = ""
            for x in 0..<width {
                let black = isBlack(
                    bytes: bytes,
                    x: x,
                    y: y,
                    bytesPerPixel: bytesPerPixel,
                    bytesPerRow: bytesPerRow
                )
                line += black ? "██" : "  "
            }
            lines.append(line)
        }

        return lines
    }

    private static func isBlack(
        bytes: UnsafePointer<UInt8>,
        x: Int,
        y: Int,
        bytesPerPixel: Int,
        bytesPerRow: Int
    ) -> Bool {
        let offset = y * bytesPerRow + x * bytesPerPixel
        // QR code from CoreImage is grayscale or RGB, black is 0
        return bytes[offset] == 0
    }

    /// Render QR code with a border and optional label
    static func render(from string: String, label: String? = nil, maxWidth: Int = 60) -> [String] {
        let qrLines = generate(from: string, compact: true)

        // Add quiet zone (border) around QR code
        let qrWidth = qrLines.first?.count ?? 0
        let padding = 2
        let paddedWidth = qrWidth + padding * 2

        var result: [String] = []

        // Top border
        result.append("┌" + String(repeating: "─", count: paddedWidth) + "┐")

        // Top quiet zone
        for _ in 0..<padding {
            result.append("│" + String(repeating: " ", count: paddedWidth) + "│")
        }

        // QR code lines with side padding
        for line in qrLines {
            let paddedLine = String(repeating: " ", count: padding) + line + String(repeating: " ", count: padding)
            result.append("│" + paddedLine + "│")
        }

        // Bottom quiet zone
        for _ in 0..<padding {
            result.append("│" + String(repeating: " ", count: paddedWidth) + "│")
        }

        // Bottom border
        result.append("└" + String(repeating: "─", count: paddedWidth) + "┘")

        // Label if provided
        if let label = label {
            // Center the label
            let labelPadding = max(0, (paddedWidth + 2 - label.count) / 2)
            result.append(String(repeating: " ", count: labelPadding) + label)
        }

        return result
    }
}
