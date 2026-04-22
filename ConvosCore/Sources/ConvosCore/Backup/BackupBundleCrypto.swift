import CryptoKit
import Foundation

/// AES-256-GCM seal/open for the outer backup bundle.
///
/// The outer seal is keyed directly on the identity's 32-byte
/// `databaseKey` — the same key XMTPiOS uses as the SQLCipher key for
/// the local XMTP DB, so compromising the bundle key already implied
/// compromising the XMTP DB. HKDF adds no meaningful isolation under
/// that threat model (see `docs/plans/icloud-backup-single-inbox.md`
/// §"No HKDF on the bundle key"). The inner XMTP archive uses its
/// own per-bundle `archiveKey`; see §"Two keys, two roles" for why
/// the two keys are kept distinct.
package enum BackupBundleCrypto {
    static let expectedKeyLength: Int = 32

    enum CryptoError: Error, LocalizedError {
        case encryptionFailed(String)
        case decryptionFailed(String)
        case invalidKeyLength(expected: Int, got: Int)

        var errorDescription: String? {
            switch self {
            case let .encryptionFailed(reason):
                return "Backup encryption failed: \(reason)"
            case let .decryptionFailed(reason):
                return "Backup decryption failed: \(reason)"
            case let .invalidKeyLength(expected, got):
                return "Bundle encryption key must be \(expected) bytes (got \(got))"
            }
        }
    }

    static func encrypt(data: Data, key: Data) throws -> Data {
        let symmetricKey = try makeSymmetricKey(from: key)
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
        let symmetricKey = try makeSymmetricKey(from: key)
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch {
            throw CryptoError.decryptionFailed("\(error)")
        }
    }

    /// 32 bytes of CSPRNG, suitable as the inner `archiveKey` handed to
    /// `XMTPiOS.Client.createArchive`. Fresh per bundle (never reused).
    static func generateArchiveKey() throws -> Data {
        var key = Data(count: expectedKeyLength)
        let status = key.withUnsafeMutableBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else {
                return errSecUnknownFormat
            }
            return SecRandomCopyBytes(kSecRandomDefault, expectedKeyLength, baseAddress)
        }
        guard status == errSecSuccess else {
            throw CryptoError.encryptionFailed("SecRandomCopyBytes returned \(status)")
        }
        return key
    }

    private static func makeSymmetricKey(from key: Data) throws -> SymmetricKey {
        guard key.count == expectedKeyLength else {
            throw CryptoError.invalidKeyLength(expected: expectedKeyLength, got: key.count)
        }
        return SymmetricKey(data: key)
    }
}
