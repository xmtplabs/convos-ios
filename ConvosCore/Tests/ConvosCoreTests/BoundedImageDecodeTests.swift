@testable import ConvosCore
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Renders a solid-color PNG at the given pixel dimensions using only
/// CoreGraphics/ImageIO, so these tests run on macOS and iOS alike.
private func makePNGData(width: Int, height: Int) throws -> Data {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try #require(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let cgImage = try #require(context.makeImage())

    let mutableData = try #require(CFDataCreateMutable(nil, 0))
    let destination = try #require(
        CGImageDestinationCreateWithData(mutableData, UTType.png.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, cgImage, nil)
    #expect(CGImageDestinationFinalize(destination))
    return mutableData as Data
}

/// Pixel dimensions of a decoded image, platform-independently. Decoded
/// images come from `CGImage`s at scale 1, so point size equals pixel size.
private func pixelSize(of image: ImageType) -> CGSize {
    image.size
}

struct BoundedImageDecodeTests {
    @Test func oversizedImageIsClampedToDefaultMax() throws {
        let data = try makePNGData(width: 4096, height: 1024)

        let image = try #require(BoundedImageDecode.image(from: data))

        let size = pixelSize(of: image)
        #expect(Int(size.width) == BoundedImageDecode.defaultMaxPixelSize)
        #expect(Int(size.height) == 512)
    }

    @Test func smallImageKeepsItsDimensions() throws {
        let data = try makePNGData(width: 300, height: 200)

        let image = try #require(BoundedImageDecode.image(from: data))

        let size = pixelSize(of: image)
        #expect(Int(size.width) == 300)
        #expect(Int(size.height) == 200)
    }

    @Test func customMaxPixelSizePreservesAspectRatio() throws {
        let data = try makePNGData(width: 1000, height: 500)

        let image = try #require(BoundedImageDecode.image(from: data, maxPixelSize: 100))

        let size = pixelSize(of: image)
        #expect(Int(size.width) == 100)
        #expect(Int(size.height) == 50)
    }

    @Test func invalidDataReturnsNil() {
        let garbage = Data([0xde, 0xad, 0xbe, 0xef, 0x00, 0x01, 0x02, 0x03])

        #expect(BoundedImageDecode.image(from: garbage) == nil)
    }

    @Test func decodesFromFileURLWithClamping() throws {
        let data = try makePNGData(width: 3000, height: 3000)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounded-decode-test-\(UUID().uuidString).png")
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let image = try #require(BoundedImageDecode.image(contentsOf: fileURL))

        let size = pixelSize(of: image)
        #expect(Int(size.width) == BoundedImageDecode.defaultMaxPixelSize)
        #expect(Int(size.height) == BoundedImageDecode.defaultMaxPixelSize)
    }

    @Test func missingFileReturnsNil() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).png")

        #expect(BoundedImageDecode.image(contentsOf: missing) == nil)
    }
}
