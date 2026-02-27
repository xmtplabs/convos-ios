import Compression
import Foundation
import SwiftProtobuf

// MARK: - ConversationCustomMetadata + Serialization

extension ConversationCustomMetadata {
    /// Maximum allowed decompressed size to prevent decompression bombs
    private static let maxDecompressedSize: UInt32 = 10 * 1024 * 1024

    /// Compression threshold - below this size, compression overhead typically increases size
    private static let compressionThreshold: Int = 100

    /// Maximum size for XMTP appData field (8KB)
    public static let appDataByteLimit: Int = 8 * 1024

    /// Serialize metadata to base64url string with optional compression
    /// - Returns: Base64URL-encoded string (compressed if beneficial)
    public func toCompactString() throws -> String {
        let protobufData = try serializedData()

        let data: Data
        if protobufData.count > Self.compressionThreshold,
           let compressed = protobufData.compressedIfSmaller() {
            data = compressed
        } else {
            data = protobufData
        }

        return data.base64URLEncoded()
    }

    /// Deserialize metadata from base64url string with automatic decompression
    /// - Parameter string: Base64URL-encoded string (potentially compressed)
    /// - Returns: Decoded ConversationCustomMetadata instance
    public static func fromCompactString(_ string: String) throws -> ConversationCustomMetadata {
        let data = try string.base64URLDecoded()

        let protobufData: Data
        if let firstByte = data.first, firstByte == Data.compressionMarker {
            let dataWithoutMarker = data.dropFirst()
            guard let decompressed = dataWithoutMarker.decompressedWithSize(maxSize: maxDecompressedSize) else {
                throw AppDataError.decompressionFailed
            }
            protobufData = decompressed
        } else {
            protobufData = data
        }

        return try ConversationCustomMetadata(serializedBytes: protobufData)
    }

    /// Parse appData string, returning empty metadata if invalid
    /// - Parameter appDataString: The raw appData string from XMTP
    /// - Returns: Parsed metadata or empty metadata if parsing fails
    public static func parseAppData(_ appDataString: String?) -> ConversationCustomMetadata {
        guard let appDataString, !appDataString.isEmpty else {
            return ConversationCustomMetadata()
        }

        if let metadata = try? fromCompactString(appDataString) {
            return metadata
        }

        return ConversationCustomMetadata()
    }

    /// Check if string appears to be encoded metadata
    public static func isEncodedMetadata(_ string: String) -> Bool {
        guard !string.isEmpty else { return false }

        let base64URLCharSet = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
        )
        guard string.rangeOfCharacter(from: base64URLCharSet.inverted) == nil else {
            return false
        }

        return (try? fromCompactString(string)) != nil
    }
}

// MARK: - Errors

public enum AppDataError: Error, LocalizedError {
    case decompressionFailed
    case invalidBase64
    case appDataLimitExceeded(currentSize: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .decompressionFailed:
            return "Failed to decompress app data"
        case .invalidBase64:
            return "Invalid Base64URL encoding"
        case let .appDataLimitExceeded(currentSize, limit):
            return "App data size (\(currentSize) bytes) exceeds limit (\(limit) bytes)"
        }
    }
}

// MARK: - Base64URL Encoding

extension Data {
    /// Encode data to URL-safe base64 string without padding
    public func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension String {
    /// Decode URL-safe base64 string to data
    public func base64URLDecoded() throws -> Data {
        var base64 = self
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = 4 - (base64.count % 4)
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }

        guard let data = Data(base64Encoded: base64) else {
            throw AppDataError.invalidBase64
        }

        return data
    }
}

// MARK: - DEFLATE Compression

extension Data {
    /// Magic byte prefix for compressed data
    static let compressionMarker: UInt8 = 0x1F

    /// Compress data using DEFLATE, only if result is smaller than input
    func compressedIfSmaller(marker: UInt8 = Data.compressionMarker) -> Data? {
        guard let compressed = compressedWithSize(marker: marker),
              compressed.count < count else {
            return nil
        }
        return compressed
    }

    /// Compress data using DEFLATE and prepend format metadata
    /// Format: [marker: 1 byte][size: 4 bytes big-endian][compressed data]
    func compressedWithSize(marker: UInt8 = Data.compressionMarker) -> Data? {
        withUnsafeBytes { bytes in
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
                UInt8(size & 0xFF),
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
