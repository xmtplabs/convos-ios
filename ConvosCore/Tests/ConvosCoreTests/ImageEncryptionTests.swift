@testable import ConvosCore
import Foundation
import Testing

@Suite("Image Encryption Tests")
struct ImageEncryptionTests {
    // MARK: - Key Generation Tests

    @Test("Generate group key produces 32 bytes")
    func generateGroupKeyLength() throws {
        let key = try ImageEncryption.generateGroupKey()
        #expect(key.count == 32)
    }

    @Test("Generate group key produces unique keys")
    func generateGroupKeyUniqueness() throws {
        let key1 = try ImageEncryption.generateGroupKey()
        let key2 = try ImageEncryption.generateGroupKey()
        let key3 = try ImageEncryption.generateGroupKey()

        #expect(key1 != key2)
        #expect(key2 != key3)
        #expect(key1 != key3)
    }

    // MARK: - Round-Trip Encryption Tests

    @Test("Encrypt and decrypt round-trip")
    func encryptDecryptRoundTrip() throws {
        let imageData = Data("test image data for encryption".utf8)
        let groupKey = try ImageEncryption.generateGroupKey()

        let encrypted = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)
        let decrypted = try ImageEncryption.decrypt(
            ciphertext: encrypted.ciphertext,
            groupKey: groupKey,
            salt: encrypted.salt,
            nonce: encrypted.nonce
        )

        #expect(decrypted == imageData)
    }

    @Test("Encrypt and decrypt with binary data")
    func encryptDecryptBinaryData() throws {
        let imageData = Data((0..<1000).map { UInt8($0 % 256) })
        let groupKey = try ImageEncryption.generateGroupKey()

        let encrypted = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)
        let decrypted = try ImageEncryption.decrypt(
            ciphertext: encrypted.ciphertext,
            groupKey: groupKey,
            salt: encrypted.salt,
            nonce: encrypted.nonce
        )

        #expect(decrypted == imageData)
    }

    @Test("Encrypt and decrypt empty data")
    func encryptDecryptEmptyData() throws {
        let imageData = Data()
        let groupKey = try ImageEncryption.generateGroupKey()

        let encrypted = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)
        let decrypted = try ImageEncryption.decrypt(
            ciphertext: encrypted.ciphertext,
            groupKey: groupKey,
            salt: encrypted.salt,
            nonce: encrypted.nonce
        )

        #expect(decrypted == imageData)
    }

    @Test("Encrypt and decrypt large data")
    func encryptDecryptLargeData() throws {
        let imageData = Data((0..<100_000).map { UInt8($0 % 256) })
        let groupKey = try ImageEncryption.generateGroupKey()

        let encrypted = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)
        let decrypted = try ImageEncryption.decrypt(
            ciphertext: encrypted.ciphertext,
            groupKey: groupKey,
            salt: encrypted.salt,
            nonce: encrypted.nonce
        )

        #expect(decrypted == imageData)
    }

    // MARK: - Encrypted Payload Tests

    @Test("Encrypted payload has correct salt length")
    func encryptedPayloadSaltLength() throws {
        let imageData = Data("test".utf8)
        let groupKey = try ImageEncryption.generateGroupKey()

        let encrypted = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)

        #expect(encrypted.salt.count == 32)
    }

    @Test("Encrypted payload has correct nonce length")
    func encryptedPayloadNonceLength() throws {
        let imageData = Data("test".utf8)
        let groupKey = try ImageEncryption.generateGroupKey()

        let encrypted = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)

        #expect(encrypted.nonce.count == 12)
    }

    @Test("Encrypted payload produces unique salt per encryption")
    func encryptedPayloadUniqueSalt() throws {
        let imageData = Data("test".utf8)
        let groupKey = try ImageEncryption.generateGroupKey()

        let encrypted1 = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)
        let encrypted2 = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)

        #expect(encrypted1.salt != encrypted2.salt)
    }

    @Test("Encrypted payload produces unique nonce per encryption")
    func encryptedPayloadUniqueNonce() throws {
        let imageData = Data("test".utf8)
        let groupKey = try ImageEncryption.generateGroupKey()

        let encrypted1 = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)
        let encrypted2 = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)

        #expect(encrypted1.nonce != encrypted2.nonce)
    }

    @Test("Encrypted payload produces unique ciphertext per encryption")
    func encryptedPayloadUniqueCiphertext() throws {
        let imageData = Data("test".utf8)
        let groupKey = try ImageEncryption.generateGroupKey()

        let encrypted1 = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)
        let encrypted2 = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)

        #expect(encrypted1.ciphertext != encrypted2.ciphertext)
    }

    // MARK: - Decryption Failure Tests

    @Test("Decryption fails with wrong key")
    func decryptionFailsWithWrongKey() throws {
        let imageData = Data("test image data".utf8)
        let groupKey1 = try ImageEncryption.generateGroupKey()
        let groupKey2 = try ImageEncryption.generateGroupKey()

        let encrypted = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey1)

        #expect(throws: (any Error).self) {
            _ = try ImageEncryption.decrypt(
                ciphertext: encrypted.ciphertext,
                groupKey: groupKey2,
                salt: encrypted.salt,
                nonce: encrypted.nonce
            )
        }
    }

    @Test("Decryption fails with tampered ciphertext")
    func decryptionFailsWithTamperedCiphertext() throws {
        let imageData = Data("test image data".utf8)
        let groupKey = try ImageEncryption.generateGroupKey()

        let encrypted = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)

        var tamperedCiphertext = encrypted.ciphertext
        if !tamperedCiphertext.isEmpty {
            tamperedCiphertext[0] ^= 0xFF
        }

        #expect(throws: (any Error).self) {
            _ = try ImageEncryption.decrypt(
                ciphertext: tamperedCiphertext,
                groupKey: groupKey,
                salt: encrypted.salt,
                nonce: encrypted.nonce
            )
        }
    }

    @Test("Decryption fails with wrong salt")
    func decryptionFailsWithWrongSalt() throws {
        let imageData = Data("test image data".utf8)
        let groupKey = try ImageEncryption.generateGroupKey()

        let encrypted = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)

        let wrongSalt = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        #expect(throws: (any Error).self) {
            _ = try ImageEncryption.decrypt(
                ciphertext: encrypted.ciphertext,
                groupKey: groupKey,
                salt: wrongSalt,
                nonce: encrypted.nonce
            )
        }
    }

    @Test("Decryption fails with wrong nonce")
    func decryptionFailsWithWrongNonce() throws {
        let imageData = Data("test image data".utf8)
        let groupKey = try ImageEncryption.generateGroupKey()

        let encrypted = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)

        let wrongNonce = Data((0..<12).map { _ in UInt8.random(in: 0...255) })

        #expect(throws: (any Error).self) {
            _ = try ImageEncryption.decrypt(
                ciphertext: encrypted.ciphertext,
                groupKey: groupKey,
                salt: encrypted.salt,
                nonce: wrongNonce
            )
        }
    }

    // MARK: - Input Validation Tests

    @Test("Decryption throws for invalid salt length")
    func decryptionThrowsForInvalidSaltLength() throws {
        let groupKey = try ImageEncryption.generateGroupKey()
        let invalidSalt = Data([0x00, 0x01])
        let validNonce = Data(repeating: 0, count: 12)
        let ciphertext = Data("test".utf8)

        #expect(throws: ImageEncryptionError.self) {
            _ = try ImageEncryption.decrypt(
                ciphertext: ciphertext,
                groupKey: groupKey,
                salt: invalidSalt,
                nonce: validNonce
            )
        }
    }

    @Test("Decryption throws for invalid nonce length")
    func decryptionThrowsForInvalidNonceLength() throws {
        let groupKey = try ImageEncryption.generateGroupKey()
        let validSalt = Data(repeating: 0, count: 32)
        let invalidNonce = Data([0x00, 0x01])
        let ciphertext = Data("test".utf8)

        #expect(throws: ImageEncryptionError.self) {
            _ = try ImageEncryption.decrypt(
                ciphertext: ciphertext,
                groupKey: groupKey,
                salt: validSalt,
                nonce: invalidNonce
            )
        }
    }

    @Test("Invalid salt length error has correct values")
    func invalidSaltLengthErrorValues() throws {
        let groupKey = try ImageEncryption.generateGroupKey()
        let invalidSalt = Data([0x00, 0x01, 0x02])
        let validNonce = Data(repeating: 0, count: 12)

        do {
            _ = try ImageEncryption.decrypt(
                ciphertext: Data(),
                groupKey: groupKey,
                salt: invalidSalt,
                nonce: validNonce
            )
            Issue.record("Expected error to be thrown")
        } catch let error as ImageEncryptionError {
            if case let .invalidSaltLength(expected, actual) = error {
                #expect(expected == 32)
                #expect(actual == 3)
            } else {
                Issue.record("Expected invalidSaltLength error")
            }
        }
    }

    @Test("Invalid nonce length error has correct values")
    func invalidNonceLengthErrorValues() throws {
        let groupKey = try ImageEncryption.generateGroupKey()
        let validSalt = Data(repeating: 0, count: 32)
        let invalidNonce = Data([0x00, 0x01, 0x02, 0x03, 0x04])

        do {
            _ = try ImageEncryption.decrypt(
                ciphertext: Data(),
                groupKey: groupKey,
                salt: validSalt,
                nonce: invalidNonce
            )
            Issue.record("Expected error to be thrown")
        } catch let error as ImageEncryptionError {
            if case let .invalidNonceLength(expected, actual) = error {
                #expect(expected == 12)
                #expect(actual == 5)
            } else {
                Issue.record("Expected invalidNonceLength error")
            }
        }
    }

    // MARK: - Cross-Encryption Tests

    @Test("Same data with same key but different salt/nonce produces different ciphertext")
    func sameDataDifferentEncryptions() throws {
        let imageData = Data("identical data".utf8)
        let groupKey = try ImageEncryption.generateGroupKey()

        var ciphertexts: [Data] = []
        for _ in 0..<10 {
            let encrypted = try ImageEncryption.encrypt(imageData: imageData, groupKey: groupKey)
            ciphertexts.append(encrypted.ciphertext)
        }

        let uniqueCiphertexts = Set(ciphertexts)
        #expect(uniqueCiphertexts.count == 10, "All encryptions should produce unique ciphertexts")
    }

    @Test("Different data with same key produces different ciphertext")
    func differentDataSameKey() throws {
        let groupKey = try ImageEncryption.generateGroupKey()

        let encrypted1 = try ImageEncryption.encrypt(imageData: Data("data1".utf8), groupKey: groupKey)
        let encrypted2 = try ImageEncryption.encrypt(imageData: Data("data2".utf8), groupKey: groupKey)

        #expect(encrypted1.ciphertext != encrypted2.ciphertext)
    }

    // MARK: - Error Description Tests

    @Test("Error descriptions are human readable")
    func errorDescriptionsAreReadable() {
        let errors: [ImageEncryptionError] = [
            .keyGenerationFailed,
            .randomGenerationFailed,
            .encryptionFailed,
            .decryptionFailed,
            .missingEncryptionKey,
            .invalidSaltLength(expected: 32, actual: 16),
            .invalidNonceLength(expected: 12, actual: 8)
        ]

        for error in errors {
            let description = error.errorDescription
            #expect(description != nil)
            #expect(!description!.isEmpty)
        }
    }
}
