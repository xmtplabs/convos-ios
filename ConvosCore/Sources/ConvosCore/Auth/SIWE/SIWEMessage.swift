import Foundation

/// EIP-4361 "Sign-In With Ethereum" message.
///
/// Renders to the exact text format the backend's `siwe` lib parses. Fields
/// `domain`, `uri`, `chainId`, and `nonce` are validated against backend env
/// values; mismatch causes `401 Invalid SIWE` and burns the nonce.
public struct SIWEMessage: Sendable, Equatable {
    public let domain: String
    public let address: String
    public let statement: String?
    public let uri: String
    public let version: String
    public let chainId: Int
    public let nonce: String
    public let issuedAt: Date
    public let expirationTime: Date?
    public let notBefore: Date?
    public let requestId: String?
    public let resources: [String]?

    public init(
        domain: String,
        address: String,
        statement: String?,
        uri: String,
        version: String = "1",
        chainId: Int,
        nonce: String,
        issuedAt: Date,
        expirationTime: Date? = nil,
        notBefore: Date? = nil,
        requestId: String? = nil,
        resources: [String]? = nil
    ) {
        self.domain = domain
        self.address = address
        self.statement = statement
        self.uri = uri
        self.version = version
        self.chainId = chainId
        self.nonce = nonce
        self.issuedAt = issuedAt
        self.expirationTime = expirationTime
        self.notBefore = notBefore
        self.requestId = requestId
        self.resources = resources
    }

    /// Renders to the exact EIP-4361 message string that gets signed.
    /// Date fields use ISO 8601 with millisecond precision and a `Z` suffix
    /// (matching JS `new Date().toISOString()`).
    public func prepareMessage() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines: [String] = []
        lines.append("\(domain) wants you to sign in with your Ethereum account:")
        lines.append(address)
        lines.append("")
        if let statement {
            lines.append(statement)
            lines.append("")
        }
        lines.append("URI: \(uri)")
        lines.append("Version: \(version)")
        lines.append("Chain ID: \(chainId)")
        lines.append("Nonce: \(nonce)")
        lines.append("Issued At: \(formatter.string(from: issuedAt))")
        if let expirationTime {
            lines.append("Expiration Time: \(formatter.string(from: expirationTime))")
        }
        if let notBefore {
            lines.append("Not Before: \(formatter.string(from: notBefore))")
        }
        if let requestId {
            lines.append("Request ID: \(requestId)")
        }
        if let resources, !resources.isEmpty {
            lines.append("Resources:")
            for resource in resources {
                lines.append("- \(resource)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
