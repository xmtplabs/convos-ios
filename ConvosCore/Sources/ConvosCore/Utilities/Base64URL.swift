import Foundation

// MARK: - Base64URL Extensions

/// URL-safe Base64 encoding/decoding for compact invite codes and metadata
///
/// Replaces standard base64 characters with URL-safe alternatives:
/// - `+` → `-`
/// - `/` → `_`
/// - Removes padding `=`
///
/// Additionally, inserts `*` separator characters every 300 characters to work around
/// an iMessage URL parsing limitation that breaks long Base64 strings.
/// See: https://www.patrickweaver.net/blog/imessage-mystery/
///
/// Used for encoding compressed protobuf payloads in invite URLs and metadata storage.
public extension Data {
    /// Encode data to URL-safe base64 string without padding
    ///
    /// Inserts `*` every 300 characters to prevent iMessage from breaking the URL.
    func base64URLEncoded() -> String {
        let encoded = base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        // Insert "*" every 300 characters to work around iMessage URL parsing
        // iMessage breaks URLs with Base64 sections longer than 301 characters
        return encoded.insertingSeparator("*", every: 300)
    }
}

public extension String {
    /// Decode URL-safe base64 string to data
    ///
    /// Removes `*` separator characters that were inserted for iMessage compatibility.
    func base64URLDecoded() throws -> Data {
        // Remove "*" separators inserted for iMessage compatibility
        var base64 = self
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Add padding if needed
        let padding = 4 - (base64.count % 4)
        if padding < 4 {
            base64 += String(repeating: "=", count: padding)
        }

        guard let data = Data(base64Encoded: base64) else {
            throw Base64URLError.invalidFormat
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

// MARK: - Error Types

public enum Base64URLError: Error, LocalizedError {
    case invalidFormat

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Invalid base64url format"
        }
    }
}
