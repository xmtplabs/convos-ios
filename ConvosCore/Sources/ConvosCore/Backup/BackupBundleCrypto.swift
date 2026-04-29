import CryptoKit
import Foundation

/// Outer-seal AES-GCM encryption for the backup bundle tar.
///
/// The plan deliberately uses the raw `identity.databaseKey` as the
/// `SymmetricKey` — no HKDF, no salt, no info string. The threat model is
/// already that a compromised iCloud Keychain leaks both the SQLCipher key
/// and any bundle encrypted with it, so deriving a second key from the first
/// would be security theater.
enum BackupBundleCrypto {
    enum CryptoError: Error, LocalizedError {
        case encryptionFailed(String)
        case decryptionFailed(String)
        case invalidKeyLength

        var errorDescription: String? {
            switch self {
            case .encryptionFailed(let reason):
                return "Backup encryption failed: \(reason)"
            case .decryptionFailed(let reason):
                return "Backup decryption failed: \(reason)"
            case .invalidKeyLength:
                return "Encryption key must be 32 bytes"
            }
        }
    }

    static func encrypt(data: Data, key: Data) throws -> Data {
        guard key.count == 32 else {
            throw CryptoError.invalidKeyLength
        }
        let symmetricKey = SymmetricKey(data: key)
        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(data, using: symmetricKey)
        } catch {
            throw CryptoError.encryptionFailed("\(error)")
        }
        guard let combined = sealedBox.combined else {
            throw CryptoError.encryptionFailed("failed to produce combined representation")
        }
        return combined
    }

    static func decrypt(data: Data, key: Data) throws -> Data {
        guard key.count == 32 else {
            throw CryptoError.invalidKeyLength
        }
        let symmetricKey = SymmetricKey(data: key)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch {
            throw CryptoError.decryptionFailed("\(error)")
        }
    }
}
