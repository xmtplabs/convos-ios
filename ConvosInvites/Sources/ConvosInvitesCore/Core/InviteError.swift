import Foundation

/// Errors that can occur during invite cryptographic operations
public enum InviteSignatureError: Error, Equatable, Sendable {
    case invalidContext
    case signatureFailure
    case encodingFailure
    case invalidSignature
    case invalidPublicKey
    case invalidPrivateKey
    case verificationFailure
    case invalidFormat
}

/// Errors that can occur during invite token operations
public enum InviteTokenError: Error, LocalizedError, Equatable, Sendable {
    case truncated
    case missingVersion
    case unsupportedVersion(UInt8)
    case badKeyMaterial
    case cryptoOpenFailed
    case invalidFormat(String)
    case stringTooLong(Int)
    case emptyConversationId

    public var errorDescription: String? {
        switch self {
        case .truncated:
            return "Invite code data is truncated"
        case .missingVersion:
            return "Invite code is missing version byte"
        case .unsupportedVersion(let version):
            return "Unsupported invite code version: \(version), expected \(InviteToken.formatVersion)"
        case .badKeyMaterial:
            return "Invalid private key material"
        case .cryptoOpenFailed:
            return "Failed to decrypt invite code"
        case .invalidFormat(let details):
            return "Invalid invite code format: \(details)"
        case .stringTooLong(let length):
            return "Conversation ID too long: \(length) bytes, max \(InviteToken.maxStringLength)"
        case .emptyConversationId:
            return "Conversation ID cannot be empty"
        }
    }
}

/// Errors that can occur during invite encoding/decoding
public enum InviteEncodingError: Error, Equatable, Sendable {
    case compressionFailed
    case decompressionFailed
    case invalidBase64
    case serializationFailed
    case deserializationFailed
}
