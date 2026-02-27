@testable import ConvosInvitesCore
import Foundation
import Testing

@Suite("Derive Public Key Tests")
struct DerivePublicKeyTests {
    @Test("Derives valid uncompressed public key from private key")
    func derivesPublicKey() throws {
        let privateKey = Data(repeating: 0x01, count: 32)
        let publicKey = try Data.derivePublicKey(from: privateKey)

        #expect(publicKey.count == 65)
        #expect(publicKey[0] == 0x04) // uncompressed prefix
    }

    @Test("Derived public key matches signature recovery")
    func derivedKeyMatchesRecovery() throws {
        let privateKey = Data((1...32).map { UInt8($0) })
        let derivedPublicKey = try Data.derivePublicKey(from: privateKey)

        var payload = InvitePayload()
        payload.tag = "test-tag"
        payload.creatorInboxID = Data(repeating: 0xAB, count: 20)
        payload.conversationToken = Data(repeating: 0xCD, count: 32)

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        let recoveredPublicKey = try signedInvite.recoverSignerPublicKey()

        #expect(derivedPublicKey == recoveredPublicKey)
    }

    @Test("Signature verification succeeds with derived public key")
    func verifyWithDerivedKey() throws {
        let privateKey = Data((1...32).map { UInt8($0) })
        let publicKey = try Data.derivePublicKey(from: privateKey)

        var payload = InvitePayload()
        payload.tag = "verify-test"
        payload.creatorInboxID = Data(repeating: 0x01, count: 20)
        payload.conversationToken = Data(repeating: 0x02, count: 32)

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        #expect(try signedInvite.verify(with: publicKey))
    }

    @Test("Signature verification fails with wrong public key")
    func verifyFailsWithWrongKey() throws {
        let privateKey = Data((1...32).map { UInt8($0) })
        let wrongPrivateKey = Data((33...64).map { UInt8($0) })
        let wrongPublicKey = try Data.derivePublicKey(from: wrongPrivateKey)

        var payload = InvitePayload()
        payload.tag = "wrong-key-test"
        payload.creatorInboxID = Data(repeating: 0x01, count: 20)
        payload.conversationToken = Data(repeating: 0x02, count: 32)

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        #expect(try !signedInvite.verify(with: wrongPublicKey))
    }

    @Test("Rejects invalid private key length")
    func rejectsInvalidKeyLength() {
        #expect(throws: InviteSignatureError.self) {
            _ = try Data.derivePublicKey(from: Data(repeating: 0x01, count: 16))
        }
    }

    @Test("Different private keys produce different public keys")
    func differentKeysProduceDifferentPublicKeys() throws {
        let key1 = try Data.derivePublicKey(from: Data((1...32).map { UInt8($0) }))
        let key2 = try Data.derivePublicKey(from: Data((33...64).map { UInt8($0) }))

        #expect(key1 != key2)
    }
}
