import Compression
import Foundation
import SwiftProtobuf

// MARK: - URL-Safe Encoding

/// URL-safe Base64 encoding with optional DEFLATE compression for invite codes
public enum InviteEncoder {
    /// Maximum allowed decompressed size to prevent decompression bombs
    public static let maxDecompressedSize: UInt32 = 1 * 1024 * 1024

    /// Encode a signed invite to URL-safe string
    /// - Parameter signedInvite: The invite to encode
    /// - Returns: URL-safe Base64 string with asterisks every 300 chars for iMessage compatibility
    public static func encode(_ signedInvite: SignedInvite) throws -> String {
        let protobufData = try signedInvite.serializedData()
        let data = protobufData.compressedIfSmaller() ?? protobufData
        return data
            .base64URLEncoded()
            .insertingSeparator("*", every: 300)
    }

    /// Decode from URL-safe string
    /// - Parameter slug: The URL-safe encoded string
    /// - Returns: The decoded signed invite
    public static func decode(_ slug: String) throws -> SignedInvite {
        let data = try slug
            .replacingOccurrences(of: "*", with: "")
            .base64URLDecoded()

        let protobufData: Data
        if let firstByte = data.first, firstByte == Data.compressionMarker {
            let dataWithoutMarker = data.dropFirst()
            guard let decompressed = dataWithoutMarker.decompressedWithSize(maxSize: maxDecompressedSize) else {
                throw InviteEncodingError.decompressionFailed
            }
            protobufData = decompressed
        } else {
            protobufData = data
        }

        return try SignedInvite(serializedBytes: protobufData)
    }

    /// Decode from either the full URL string or the invite code string
    public static func decodeFromURL(_ urlString: String) throws -> SignedInvite {
        let trimmedInput = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        let extractedCode: String
        if let url = URL(string: trimmedInput),
           let codeFromURL = url.convosInviteCode {
            extractedCode = codeFromURL
        } else {
            extractedCode = trimmedInput
        }

        let finalCode = extractedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return try decode(finalCode)
    }
}

// MARK: - SignedInvite Encoding Extensions

extension SignedInvite {
    /// Encode to URL-safe base64 string
    public func toURLSafeSlug() throws -> String {
        try InviteEncoder.encode(self)
    }

    /// Decode from URL-safe base64 string
    public static func fromURLSafeSlug(_ slug: String) throws -> SignedInvite {
        try InviteEncoder.decode(slug)
    }

    /// Decode from either the full URL string or the invite code string
    public static func fromInviteCode(_ code: String) throws -> SignedInvite {
        try InviteEncoder.decodeFromURL(code)
    }
}

// MARK: - Base64URL Extensions

extension Data {
    /// Encode data to URL-safe base64 string without padding
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    /// Decode URL-safe base64 string to data
    func base64URLDecoded() throws -> Data {
        var base64 = self
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = 4 - (base64.count % 4)
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }

        guard let data = Data(base64Encoded: base64) else {
            throw InviteEncodingError.invalidBase64
        }

        return data
    }

    /// Insert a separator string at regular intervals
    func insertingSeparator(_ separator: String, every count: Int) -> String {
        guard count > 0, !isEmpty else { return self }

        var result = ""
        result.reserveCapacity(self.count + (self.count / count) * separator.count)

        for (index, character) in self.enumerated() {
            if index > 0, index.isMultiple(of: count) {
                result.append(separator)
            }
            result.append(character)
        }

        return result
    }
}

// MARK: - DEFLATE Compression

extension Data {
    /// Magic byte prefix for compressed data
    static let compressionMarker: UInt8 = 0x1F

    /// Compress data using DEFLATE, only if result is smaller than input
    func compressedIfSmaller(marker: UInt8 = Data.compressionMarker) -> Data? {
        guard let compressed = compressedWithSize(marker: marker), compressed.count < count else {
            return nil
        }
        return compressed
    }

    /// Compress data using DEFLATE and prepend format metadata
    /// Format: [marker: 1 byte][size: 4 bytes big-endian][compressed data]
    func compressedWithSize(marker: UInt8 = Data.compressionMarker) -> Data? {
        return self.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }

            let sourceBuffer = UnsafeBufferPointer<UInt8>(
                start: baseAddress.assumingMemoryBound(to: UInt8.self),
                count: count
            )

            let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
            defer { destinationBuffer.deallocate() }

            guard let sourceBaseAddress = sourceBuffer.baseAddress else { return nil }

            let compressedSize = compression_encode_buffer(
                destinationBuffer, count,
                sourceBaseAddress, count,
                nil, COMPRESSION_ZLIB
            )

            guard compressedSize > 0 else { return nil }

            var result = Data()
            result.append(marker)

            guard count <= Int(UInt32.max) else { return nil }
            let size = UInt32(count)
            result.append(contentsOf: [
                UInt8((size >> 24) & 0xFF),
                UInt8((size >> 16) & 0xFF),
                UInt8((size >> 8) & 0xFF),
                UInt8(size & 0xFF)
            ])

            result.append(Data(bytes: destinationBuffer, count: compressedSize))

            return result
        }
    }

    /// Decompress DEFLATE-compressed data with size metadata
    /// Format: [size: 4 bytes big-endian][compressed data] (marker already stripped)
    func decompressedWithSize(maxSize: UInt32, maxCompressionRatio: UInt32 = 100) -> Data? {
        guard count >= 5 else { return nil }

        let sizeBytes = Array(prefix(4))

        let originalSize: UInt32 = (UInt32(sizeBytes[0]) << 24) |
                                    (UInt32(sizeBytes[1]) << 16) |
                                    (UInt32(sizeBytes[2]) << 8) |
                                     UInt32(sizeBytes[3])

        guard originalSize > 0, originalSize <= maxSize else { return nil }

        let compressedData = dropFirst(4)
        guard !compressedData.isEmpty else { return nil }

        let compressionRatio = originalSize / UInt32(compressedData.count)
        guard compressionRatio <= maxCompressionRatio else { return nil }

        return compressedData.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }

            let sourceBuffer = UnsafeBufferPointer<UInt8>(
                start: baseAddress.assumingMemoryBound(to: UInt8.self),
                count: compressedData.count
            )

            guard let sourceBaseAddress = sourceBuffer.baseAddress else { return nil }

            let destinationBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(originalSize))
            defer { destinationBuffer.deallocate() }

            let decompressedSize = compression_decode_buffer(
                destinationBuffer, Int(originalSize),
                sourceBaseAddress, compressedData.count,
                nil, COMPRESSION_ZLIB
            )

            guard decompressedSize > 0, decompressedSize == Int(originalSize) else {
                return nil
            }

            return Data(bytes: destinationBuffer, count: decompressedSize)
        }
    }
}

// MARK: - URL Extension

extension URL {
    /// Extract invite code from Convos URL
    var convosInviteCode: String? {
        // Handle convos:// scheme
        if scheme == "convos" {
            // convos://invite/{code}
            if host == "invite" || pathComponents.first == "invite" {
                return pathComponents.last
            }
        }

        // Handle https://convos.org URLs
        if host?.contains("convos") == true {
            // https://convos.org/i/{code}
            if pathComponents.contains("i"), let codeIndex = pathComponents.firstIndex(of: "i"),
               codeIndex + 1 < pathComponents.count {
                return pathComponents[codeIndex + 1]
            }

            // https://convos.org/invite?code={code}
            if let queryItems = URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems,
               let code = queryItems.first(where: { $0.name == "code" })?.value {
                return code
            }
        }

        return nil
    }
}
