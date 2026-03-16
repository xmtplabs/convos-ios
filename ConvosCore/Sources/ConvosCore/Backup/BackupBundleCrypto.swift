import CryptoKit
import Foundation

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
        do {
            let sealedBox = try AES.GCM.seal(data, using: symmetricKey)
            guard let combined = sealedBox.combined else {
                throw CryptoError.encryptionFailed("failed to produce combined representation")
            }
            return combined
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.encryptionFailed(error.localizedDescription)
        }
    }

    static func decrypt(data: Data, key: Data) throws -> Data {
        guard key.count == 32 else {
            throw CryptoError.invalidKeyLength
        }
        let symmetricKey = SymmetricKey(data: key)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch let error as CryptoError {
            throw error
        } catch {
            throw CryptoError.decryptionFailed(error.localizedDescription)
        }
    }
}
