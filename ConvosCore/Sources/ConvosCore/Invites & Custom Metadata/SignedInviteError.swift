import Foundation

// MARK: - SignedInviteError

enum EncodableSignatureError: Error, Equatable {
    case invalidContext
    case signatureFailure
    case encodingFailure
    case invalidSignature
    case invalidPublicKey
    case invalidPrivateKey
    case verificationFailure
    case invalidFormat
}
