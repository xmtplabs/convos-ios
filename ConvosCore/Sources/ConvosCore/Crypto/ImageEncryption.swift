import CryptoKit
import Foundation

public enum ImageEncryption {
    private static let hkdfInfo: Data = Data("ConvosImageV1".utf8)
    private static let saltLength: Int = 32
    private static let nonceLength: Int = 12

    public struct EncryptedPayload: Sendable {
        public let ciphertext: Data
        public let salt: Data
        public let nonce: Data

        public init(ciphertext: Data, salt: Data, nonce: Data) {
            self.ciphertext = ciphertext
            self.salt = salt
            self.nonce = nonce
        }
    }

    public static func generateGroupKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        guard result == errSecSuccess else {
            throw ImageEncryptionError.keyGenerationFailed
        }
        return Data(bytes)
    }

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
