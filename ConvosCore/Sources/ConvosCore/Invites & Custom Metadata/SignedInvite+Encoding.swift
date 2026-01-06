import Foundation
import SwiftProtobuf

// MARK: - SignedInvite + Encoding

/// URL-safe Base64 encoding extensions for SignedInvite
extension SignedInvite {
    /// Maximum allowed decompressed size to prevent decompression bombs
    private static let maxDecompressedSize: UInt32 = 1 * 1024 * 1024

    /// Encode to URL-safe base64 string with optional DEFLATE compression
    ///
    /// Additionally, inserts `*` separator characters every 300 characters to work around
    /// an iMessage URL parsing limitation that breaks long Base64 strings.
    /// See: https://www.patrickweaver.net/blog/imessage-mystery////
    public func toURLSafeSlug() throws -> String {
        let protobufData = try self.serializedData()
        let data = protobufData.compressedIfSmaller() ?? protobufData
        return data
            .base64URLEncoded()
            .insertingSeparator("*", every: 300)
    }

    /// Decode from URL-safe base64 string, automatically decompressing if needed
    /// Removes `*` separator characters that were inserted for iMessage compatibility.
    public static func fromURLSafeSlug(_ slug: String) throws -> SignedInvite {
        let data = try slug
            .replacingOccurrences(of: "*", with: "")
            .base64URLDecoded()

        let protobufData: Data
        // validate compression marker value explicitly
        if let firstByte = data.first, firstByte == Data.compressionMarker {
            let dataWithoutMarker = data.dropFirst()
            guard let decompressed = dataWithoutMarker.decompressedWithSize(maxSize: maxDecompressedSize) else {
                throw EncodableSignatureError.invalidFormat
            }
            protobufData = decompressed
        } else {
            protobufData = data
        }

        return try SignedInvite(serializedBytes: protobufData)
    }

    /// Decode from either the full URL string or the invite code string
    public static func fromInviteCode(_ code: String) throws -> SignedInvite {
        // Trim whitespace and newlines from input to handle padded URLs
        let trimmedInput = code.trimmingCharacters(in: .whitespacesAndNewlines)

        let extractedCode: String
        if let url = URL(string: trimmedInput),
           let codeFromURL = url.convosInviteCode {
            // Use the URL extension which handles both v2 query params and app scheme
            extractedCode = codeFromURL
        } else {
            // If URL parsing fails, treat the input as a raw invite code
            extractedCode = trimmedInput
        }

        // Trim again in case the extracted code has whitespace
        let finalCode = extractedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return try fromURLSafeSlug(finalCode)
    }
}
