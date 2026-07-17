import CryptoKit
import Foundation

/// AES-256-GCM image encryption for Convos per-conversation profiles.
///
/// Each group has a 32-byte encryption key stored in `ConversationCustomMetadata.imageEncryptionKey`.
/// Per-image encryption uses HKDF to derive a unique key from the group key + random salt.
///
/// ## Usage
///
/// ```swift
/// // Generate a group key (once per conversation)
/// let groupKey = try ImageEncryption.generateGroupKey()
///
/// // Encrypt an image
/// let payload = try ImageEncryption.encrypt(imageData: jpegData, groupKey: groupKey)
/// // Upload payload.ciphertext to S3, store salt/nonce in EncryptedImageRef
///
/// // Decrypt an image
/// let plaintext = try ImageEncryption.decrypt(
///     ciphertext: downloadedData,
///     groupKey: groupKey,
///     salt: ref.salt,
///     nonce: ref.nonce
/// )
/// ```
public enum ImageEncryption {
    private static let hkdfInfo: Data = Data("ConvosImageV1".utf8)
    private static let saltLength: Int = 32
    private static let nonceLength: Int = 12

    /// Encrypted image payload containing ciphertext and crypto parameters
    public struct EncryptedPayload: Sendable {
        /// AES-GCM ciphertext with appended auth tag
        public let ciphertext: Data
        /// 32-byte HKDF salt for key derivation
        public let salt: Data
        /// 12-byte AES-GCM nonce
        public let nonce: Data

        public init(ciphertext: Data, salt: Data, nonce: Data) {
            self.ciphertext = ciphertext
            self.salt = salt
            self.nonce = nonce
        }
    }

    /// Generate a new 32-byte AES-256 group key
    /// - Returns: Random 32-byte key
    /// - Throws: `ImageEncryptionError.keyGenerationFailed` if SecRandomCopyBytes fails
    public static func generateGroupKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        guard result == errSecSuccess else {
            throw ImageEncryptionError.keyGenerationFailed
        }
        return Data(bytes)
    }

    /// Encrypt image data using AES-256-GCM
    /// - Parameters:
    ///   - imageData: Plaintext image data (JPEG, PNG, etc.)
    ///   - groupKey: 32-byte group encryption key
    /// - Returns: Encrypted payload with ciphertext, salt, and nonce
    /// - Throws: `ImageEncryptionError` on failure
    public static func encrypt(imageData: Data, groupKey: Data) throws -> EncryptedPayload {
        var saltBytes = [UInt8](repeating: 0, count: saltLength)
        var nonceBytes = [UInt8](repeating: 0, count: nonceLength)

        guard SecRandomCopyBytes(kSecRandomDefault, saltLength, &saltBytes) == errSecSuccess,
              SecRandomCopyBytes(kSecRandomDefault, nonceLength, &nonceBytes) == errSecSuccess else {
            throw ImageEncryptionError.randomGenerationFailed
        }

        let salt = Data(saltBytes)
        let nonce = Data(nonceBytes)

        let derivedKey = deriveKey(groupKey: groupKey, salt: salt)

        let gcmNonce = try AES.GCM.Nonce(data: nonce)
        let sealedBox = try AES.GCM.seal(imageData, using: derivedKey, nonce: gcmNonce)

        guard let combined = sealedBox.combined else {
            throw ImageEncryptionError.encryptionFailed
        }

        let ciphertext = combined.dropFirst(nonceLength)

        return EncryptedPayload(
            ciphertext: Data(ciphertext),
            salt: salt,
            nonce: nonce
        )
    }

    /// Decrypt ciphertext using AES-256-GCM
    /// - Parameters:
    ///   - ciphertext: Encrypted data with appended auth tag
    ///   - groupKey: 32-byte group encryption key
    ///   - salt: 32-byte HKDF salt used during encryption
    ///   - nonce: 12-byte AES-GCM nonce used during encryption
    /// - Returns: Decrypted plaintext image data
    /// - Throws: `ImageEncryptionError` on failure
    public static func decrypt(
        ciphertext: Data,
        groupKey: Data,
        salt: Data,
        nonce: Data
    ) throws -> Data {
        guard salt.count == saltLength else {
            throw ImageEncryptionError.invalidSaltLength(expected: saltLength, actual: salt.count)
        }
        guard nonce.count == nonceLength else {
            throw ImageEncryptionError.invalidNonceLength(expected: nonceLength, actual: nonce.count)
        }

        let derivedKey = deriveKey(groupKey: groupKey, salt: salt)

        let combined = nonce + ciphertext
        let sealedBox = try AES.GCM.SealedBox(combined: combined)

        let plaintext = try AES.GCM.open(sealedBox, using: derivedKey)

        return plaintext
    }

    private static func deriveKey(groupKey: Data, salt: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: groupKey),
            salt: salt,
            info: hkdfInfo,
            outputByteCount: 32
        )
    }
}

/// Errors that can occur during image encryption/decryption
public enum ImageEncryptionError: Error, LocalizedError {
    case keyGenerationFailed
    case randomGenerationFailed
    case encryptionFailed
    case decryptionFailed
    case missingEncryptionKey
    case invalidSaltLength(expected: Int, actual: Int)
    case invalidNonceLength(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return "Failed to generate encryption key"
        case .randomGenerationFailed:
            return "Failed to generate random bytes"
        case .encryptionFailed:
            return "Failed to encrypt image"
        case .decryptionFailed:
            return "Failed to decrypt image"
        case .missingEncryptionKey:
            return "Group encryption key not found"
        case let .invalidSaltLength(expected, actual):
            return "Invalid salt length: expected \(expected), got \(actual)"
        case let .invalidNonceLength(expected, actual):
            return "Invalid nonce length: expected \(expected), got \(actual)"
        }
    }
}
