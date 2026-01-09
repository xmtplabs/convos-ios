import Foundation

public struct EncryptedImageParams: Sendable {
    public let url: URL
    public let salt: Data
    public let nonce: Data
    public let groupKey: Data

    public init(url: URL, salt: Data, nonce: Data, groupKey: Data) {
        self.url = url
        self.salt = salt
        self.nonce = nonce
        self.groupKey = groupKey
    }

    public init?(encryptedRef: EncryptedImageRef, groupKey: Data?) {
        guard let groupKey = groupKey,
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

public enum EncryptedImageLoader {
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
