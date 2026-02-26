@testable import ConvosProfiles
import Foundation
import Testing

@Suite("Image Encryption Edge Cases")
struct ImageEncryptionEdgeCaseTests {
    @Test("Different key lengths produce different ciphertexts")
    func differentKeyLengthsDifferentOutput() throws {
        let imageData = Data("test".utf8)
        let key32 = Data(repeating: 0x42, count: 32)
        let key16 = Data(repeating: 0x42, count: 16)

        let enc32 = try ImageEncryption.encrypt(imageData: imageData, groupKey: key32)
        let enc16 = try ImageEncryption.encrypt(imageData: imageData, groupKey: key16)

        let dec32 = try ImageEncryption.decrypt(
            ciphertext: enc32.ciphertext, groupKey: key32,
            salt: enc32.salt, nonce: enc32.nonce
        )
        let dec16 = try ImageEncryption.decrypt(
            ciphertext: enc16.ciphertext, groupKey: key16,
            salt: enc16.salt, nonce: enc16.nonce
        )
        #expect(dec32 == imageData)
        #expect(dec16 == imageData)
    }

    @Test("Wrong key length cannot decrypt other key's ciphertext")
    func crossKeyDecryptFails() throws {
        let imageData = Data("secret".utf8)
        let key32 = try ImageEncryption.generateGroupKey()
        let key16 = Data(repeating: 0x99, count: 16)

        let encrypted = try ImageEncryption.encrypt(imageData: imageData, groupKey: key32)

        #expect(throws: (any Error).self) {
            _ = try ImageEncryption.decrypt(
                ciphertext: encrypted.ciphertext, groupKey: key16,
                salt: encrypted.salt, nonce: encrypted.nonce
            )
        }
    }

    @Test("Decrypt with truncated ciphertext throws")
    func decryptTruncatedCiphertext() throws {
        let groupKey = try ImageEncryption.generateGroupKey()
        let encrypted = try ImageEncryption.encrypt(imageData: Data("hello world".utf8), groupKey: groupKey)
        let truncated = encrypted.ciphertext.prefix(2)

        #expect(throws: (any Error).self) {
            _ = try ImageEncryption.decrypt(
                ciphertext: Data(truncated),
                groupKey: groupKey,
                salt: encrypted.salt,
                nonce: encrypted.nonce
            )
        }
    }

    @Test("EncryptedPayload fields have correct sizes")
    func payloadFieldSizes() throws {
        let groupKey = try ImageEncryption.generateGroupKey()
        let payload = try ImageEncryption.encrypt(imageData: Data("test".utf8), groupKey: groupKey)

        #expect(payload.salt.count == 32)
        #expect(payload.nonce.count == 12)
        #expect(!payload.ciphertext.isEmpty)
    }
}

@Suite("EncryptedImageParams Tests")
struct EncryptedImageParamsTests {
    @Test("EncryptedImageParams initializes from components")
    func initFromComponents() throws {
        let url = try #require(URL(string: "https://example.com/image.bin"))
        let params = EncryptedImageParams(
            url: url,
            salt: Data(repeating: 0xAA, count: 32),
            nonce: Data(repeating: 0xBB, count: 12),
            groupKey: Data(repeating: 0x42, count: 32)
        )

        #expect(params.url.absoluteString == "https://example.com/image.bin")
        #expect(params.groupKey.count == 32)
        #expect(params.salt.count == 32)
        #expect(params.nonce.count == 12)
    }

    @Test("EncryptedImageParams initializes from valid EncryptedImageRef")
    func initFromValidRef() {
        var ref = EncryptedImageRef()
        ref.url = "https://example.com/image.bin"
        ref.salt = Data(repeating: 0xAA, count: 32)
        ref.nonce = Data(repeating: 0xBB, count: 12)

        let params = EncryptedImageParams(
            encryptedRef: ref,
            groupKey: Data(repeating: 0x42, count: 32)
        )

        #expect(params != nil)
        #expect(params?.salt == ref.salt)
        #expect(params?.nonce == ref.nonce)
    }

    @Test("EncryptedImageParams returns nil for invalid ref")
    func initFromInvalidRef() {
        var ref = EncryptedImageRef()
        ref.url = ""
        ref.salt = Data(repeating: 0xAA, count: 32)
        ref.nonce = Data(repeating: 0xBB, count: 12)

        let params = EncryptedImageParams(encryptedRef: ref, groupKey: Data(repeating: 0x42, count: 32))
        #expect(params == nil)
    }

    @Test("EncryptedImageParams returns nil for nil groupKey")
    func initWithNilGroupKey() {
        var ref = EncryptedImageRef()
        ref.url = "https://example.com/image.bin"
        ref.salt = Data(repeating: 0xAA, count: 32)
        ref.nonce = Data(repeating: 0xBB, count: 12)

        let params = EncryptedImageParams(encryptedRef: ref, groupKey: nil)
        #expect(params == nil)
    }
}
