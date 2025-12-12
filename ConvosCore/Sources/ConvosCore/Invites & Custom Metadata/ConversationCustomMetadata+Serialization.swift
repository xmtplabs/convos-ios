import Foundation
import SwiftProtobuf

// MARK: - ConversationCustomMetadata + Serialization

extension ConversationCustomMetadata {
    /// Maximum allowed decompressed size to prevent decompression bombs
    private static let maxDecompressedSize: UInt32 = 10 * 1024 * 1024

    /// Compression threshold - below this size, compression overhead typically increases size
    private static let compressionThreshold: Int = 100

    /// Serialize metadata to base64url string with optional compression
    /// - Returns: Base64URL-encoded string (compressed if beneficial)
    public func toCompactString() throws -> String {
        let protobufData = try self.serializedData()

        let data: Data
        if protobufData.count > Self.compressionThreshold, let compressed = protobufData.compressedIfSmaller() {
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
        // validate compression marker value explicitly
        if let firstByte = data.first, firstByte == Data.compressionMarker {
            let dataWithoutMarker = data.dropFirst()
            guard let decompressed = dataWithoutMarker.decompressedWithSize(maxSize: maxDecompressedSize) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(codingPath: [], debugDescription: "Failed to decompress metadata")
                )
            }
            protobufData = decompressed
        } else {
            protobufData = data
        }

        return try ConversationCustomMetadata(serializedBytes: protobufData)
    }

    /// Check if a string appears to be encoded metadata (vs plain text description)
    /// - Parameter string: The string to check
    /// - Returns: true if the string appears to be Base64URL-encoded metadata
    public static func isEncodedMetadata(_ string: String) -> Bool {
        // Quick heuristics to detect if this is likely our encoded metadata:
        // 1. Must be non-empty
        // 2. Should only contain Base64URL characters
        // 3. Try to decode and parse (more expensive, so do last)

        guard !string.isEmpty else { return false }

        // Base64URL character set: A-Z, a-z, 0-9, -, _
        let base64URLCharSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        guard string.rangeOfCharacter(from: base64URLCharSet.inverted) == nil else {
            return false
        }

        // Try to actually decode it
        do {
            _ = try ConversationCustomMetadata.fromCompactString(string)
            return true
        } catch {
            return false
        }
    }

    /// Parse a description field that might be either plain text or encoded metadata
    /// - Parameter descriptionField: The raw description field from XMTP
    /// - Returns: ConversationCustomMetadata with either decoded data or plain text description
    public static func parseAppData(_ appDataString: String?) -> ConversationCustomMetadata {
        guard let appDataString = appDataString, !appDataString.isEmpty else {
            return ConversationCustomMetadata()
        }

        // Try to decode as metadata first
        if let metadata = try? ConversationCustomMetadata.fromCompactString(appDataString) {
            return metadata
        }

        return ConversationCustomMetadata()
    }
}
