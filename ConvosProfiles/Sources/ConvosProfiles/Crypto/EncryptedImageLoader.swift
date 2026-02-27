import ConvosAppData
import Foundation

/// Parameters needed to download and decrypt an encrypted image
public struct EncryptedImageParams: Sendable {
    /// URL to the encrypted ciphertext (typically S3)
    public let url: URL
    /// 32-byte HKDF salt
    public let salt: Data
    /// 12-byte AES-GCM nonce
    public let nonce: Data
    /// 32-byte group encryption key
    public let groupKey: Data

    public init(url: URL, salt: Data, nonce: Data, groupKey: Data) {
        self.url = url
        self.salt = salt
        self.nonce = nonce
        self.groupKey = groupKey
    }

    /// Initialize from an EncryptedImageRef and group key
    /// - Parameters:
    ///   - encryptedRef: Reference containing URL, salt, and nonce
    ///   - groupKey: Group encryption key (from ConversationCustomMetadata.imageEncryptionKey)
    /// - Returns: nil if ref is invalid or groupKey is nil
    public init?(encryptedRef: EncryptedImageRef, groupKey: Data?) {
        guard let groupKey,
              encryptedRef.isValid,
              let url = URL(string: encryptedRef.url) else {
            return nil
        }
        self.url = url
        self.salt = encryptedRef.salt
        self.nonce = encryptedRef.nonce
        self.groupKey = groupKey
    }
}

/// Utility for downloading and decrypting encrypted images
public enum EncryptedImageLoader {
    /// Download ciphertext from URL and decrypt using provided parameters
    /// - Parameter params: Encryption parameters including URL and crypto values
    /// - Returns: Decrypted image data
    /// - Throws: Network errors or `ImageEncryptionError` on decryption failure
    public static func loadAndDecrypt(params: EncryptedImageParams) async throws -> Data {
        let (ciphertext, response) = try await URLSession.shared.data(from: params.url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let plaintext = try ImageEncryption.decrypt(
            ciphertext: ciphertext,
            groupKey: params.groupKey,
            salt: params.salt,
            nonce: params.nonce
        )

        return plaintext
    }

    /// Convenience method with individual parameters
    public static func loadAndDecrypt(
        url: URL,
        salt: Data,
        nonce: Data,
        groupKey: Data
    ) async throws -> Data {
        let params = EncryptedImageParams(url: url, salt: salt, nonce: nonce, groupKey: groupKey)
        return try await loadAndDecrypt(params: params)
    }
}

/// Protocol for encrypted image loading (enables mocking in tests)
public protocol EncryptedImageLoaderProtocol: Sendable {
    func loadAndDecrypt(params: EncryptedImageParams) async throws -> Data
}

/// Default implementation of EncryptedImageLoaderProtocol
public final class EncryptedImageLoaderInstance: EncryptedImageLoaderProtocol, Sendable {
    public static let shared: any EncryptedImageLoaderProtocol = EncryptedImageLoaderInstance()

    public init() {}

    public func loadAndDecrypt(params: EncryptedImageParams) async throws -> Data {
        try await EncryptedImageLoader.loadAndDecrypt(params: params)
    }
}
