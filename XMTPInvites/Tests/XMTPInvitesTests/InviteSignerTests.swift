import Foundation
import Testing
@testable import XMTPInvites

@Suite("InviteSigner Tests")
struct InviteSignerTests {
    // Test private key (32 bytes)
    let testPrivateKey = Data(repeating: 0x42, count: 32)

    @Test("Sign and verify invite payload")
    func signAndVerify() throws {
        var payload = InvitePayload()
        payload.tag = "test-tag-1"
        payload.conversationToken = Data([1, 2, 3, 4, 5])
        payload.creatorInboxID = Data(repeating: 0xAB, count: 32)

        let signature = try payload.sign(with: testPrivateKey)

        #expect(signature.count == 65)

        // Create signed invite
        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        // Recover public key
        let recoveredPublicKey = try signedInvite.recoverSignerPublicKey()
        #expect(recoveredPublicKey.count == 65) // Uncompressed

        // Verify with recovered key
        let isValid = try signedInvite.verify(with: recoveredPublicKey)
        #expect(isValid)
    }

    @Test("Verification fails with wrong public key")
    func wrongPublicKey() throws {
        var payload = InvitePayload()
        payload.tag = "test-tag-2"
        payload.conversationToken = Data([1, 2, 3])

        let signature = try payload.sign(with: testPrivateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        // Use a different private key to generate wrong public key
        let wrongPrivateKey = Data(repeating: 0x99, count: 32)
        var wrongPayload = InvitePayload()
        wrongPayload.tag = "wrong"
        let wrongSignature = try wrongPayload.sign(with: wrongPrivateKey)

        var wrongSignedInvite = SignedInvite()
        try wrongSignedInvite.setPayload(wrongPayload)
        wrongSignedInvite.signature = wrongSignature

        let wrongPublicKey = try wrongSignedInvite.recoverSignerPublicKey()

        // Verification should fail
        let isValid = try signedInvite.verify(with: wrongPublicKey)
        #expect(!isValid)
    }

    @Test("Invalid signature length throws error")
    func invalidSignatureLength() throws {
        var signedInvite = SignedInvite()
        signedInvite.payload = Data([1, 2, 3])
        signedInvite.signature = Data([1, 2, 3]) // Too short

        #expect(throws: InviteSignatureError.invalidSignature) {
            _ = try signedInvite.recoverSignerPublicKey()
        }
    }

    @Test("Invalid private key length throws error")
    func invalidPrivateKeyLength() throws {
        var payload = InvitePayload()
        payload.tag = "test"

        #expect(throws: InviteSignatureError.invalidPrivateKey) {
            _ = try payload.sign(with: Data([1, 2, 3])) // Too short
        }
    }
}
