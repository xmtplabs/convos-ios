@testable import ConvosCore
import CryptoKit
import Foundation
import Testing

@Suite("BackupBundleCrypto Tests")
struct BackupBundleCryptoTests {
    private func randomKey() -> Data {
        Data(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
    }

    @Test("encrypt and decrypt round-trip")
    func testRoundTrip() throws {
        let key = randomKey()
        let plaintext = Data("hello-backup".utf8)
        let sealed = try BackupBundleCrypto.encrypt(data: plaintext, key: key)
        #expect(sealed != plaintext)
        let opened = try BackupBundleCrypto.decrypt(data: sealed, key: key)
        #expect(opened == plaintext)
    }

    @Test("rejects non-32-byte keys on encrypt")
    func testRejectsShortKeyOnEncrypt() {
        let shortKey = Data(repeating: 0, count: 16)
        #expect(throws: BackupBundleCrypto.CryptoError.self) {
            _ = try BackupBundleCrypto.encrypt(data: Data("x".utf8), key: shortKey)
        }
    }

    @Test("rejects non-32-byte keys on decrypt")
    func testRejectsShortKeyOnDecrypt() {
        let shortKey = Data(repeating: 0, count: 16)
        #expect(throws: BackupBundleCrypto.CryptoError.self) {
            _ = try BackupBundleCrypto.decrypt(data: Data("x".utf8), key: shortKey)
        }
    }

    @Test("decrypt fails under wrong key")
    func testWrongKeyFails() throws {
        let sealed = try BackupBundleCrypto.encrypt(data: Data("secret".utf8), key: randomKey())
        let wrongKey = randomKey()
        #expect(throws: BackupBundleCrypto.CryptoError.self) {
            _ = try BackupBundleCrypto.decrypt(data: sealed, key: wrongKey)
        }
    }

    @Test("decrypt fails when ciphertext is tampered with")
    func testTamperedCiphertextFails() throws {
        let key = randomKey()
        var sealed = try BackupBundleCrypto.encrypt(data: Data("secret".utf8), key: key)
        // Flip a byte in the middle of the ciphertext so AES-GCM auth rejects it.
        sealed[sealed.count / 2] ^= 0xFF
        #expect(throws: BackupBundleCrypto.CryptoError.self) {
            _ = try BackupBundleCrypto.decrypt(data: sealed, key: key)
        }
    }
}
