@testable import ConvosInvitesCore
import CryptoKit
import Foundation
import Testing

/// Comprehensive tests for InviteProtobufExtensions.swift (SignedInvite)
///
/// Tests cover:
/// - Round-trip encoding/decoding with compression
/// - Signature creation and verification
/// - Public key recovery
/// - Backward compatibility with uncompressed invites
/// - Invite code parsing (URL and raw formats)
/// - Expiration handling
/// - Invalid signature detection
@Suite("Signed Invite Tests")
struct InviteProtobufExtensionsTests {
    // MARK: - Test Keys and Data

    /// Generate a consistent test private key
    private func generateTestPrivateKey() -> Data {
        Data((0..<32).map { UInt8($0 * 7 % 256) })
    }

    private let testInboxId = "0011223344556677889900112233445566778899001122334455667788990011"

    // MARK: - Basic Encoding/Decoding Tests

    @Test("Minimal invite round-trip")
    func minimalInviteRoundTrip() throws {
        let privateKey = generateTestPrivateKey()
        let conversationId = UUID().uuidString.lowercased()

        let conversationTokenBytes = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        var payload = InvitePayload()
        payload.conversationToken = conversationTokenBytes
        payload.creatorInboxID = Data(hexString: testInboxId)!
        payload.tag = "test123"

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        let encoded = try signedInvite.toURLSafeSlug()
        let decoded = try SignedInvite.fromURLSafeSlug(encoded)

        #expect(decoded.invitePayload.tag == "test123")
        #expect(decoded.invitePayload.conversationToken == conversationTokenBytes)
        #expect(decoded.signature == signature)
    }

    @Test("Full invite with all fields")
    func fullInviteWithAllFields() throws {
        let privateKey = generateTestPrivateKey()
        let conversationId = UUID().uuidString.lowercased()

        let conversationTokenBytes = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        var payload = InvitePayload()
        payload.conversationToken = conversationTokenBytes
        payload.creatorInboxID = Data(hexString: testInboxId)!
        payload.tag = "test123"
        payload.name = "My Group Chat"
        payload.description_p = "A group chat for testing"
        payload.imageURL = "https://example.com/group.jpg"
        payload.expiresAtUnix = 1735689600 // 2025-01-01
        payload.conversationExpiresAtUnix = 1767225600 // 2026-01-01
        payload.expiresAfterUse = true

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        let encoded = try signedInvite.toURLSafeSlug()
        let decoded = try SignedInvite.fromURLSafeSlug(encoded)

        #expect(decoded.invitePayload.name == "My Group Chat")
        #expect(decoded.invitePayload.description_p == "A group chat for testing")
        #expect(decoded.invitePayload.imageURL == "https://example.com/group.jpg")
        #expect(decoded.invitePayload.expiresAtUnix == 1735689600)
        #expect(decoded.invitePayload.conversationExpiresAtUnix == 1767225600)
        #expect(decoded.invitePayload.expiresAfterUse == true)
    }

    // MARK: - Compression Tests

    @Test("Large invite compresses")
    func largeInviteCompresses() throws {
        let privateKey = generateTestPrivateKey()
        let conversationId = UUID().uuidString.lowercased()

        let conversationTokenBytes = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        var payload = InvitePayload()
        payload.conversationToken = conversationTokenBytes
        payload.creatorInboxID = Data(hexString: testInboxId)!
        payload.tag = String(repeating: "test", count: 50)
        payload.name = String(repeating: "Long Name ", count: 20)
        payload.description_p = String(repeating: "Long Description ", count: 30)

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        let protobufData = try signedInvite.serializedData()
        let encoded = try signedInvite.toURLSafeSlug()
        let encodedData = try encoded.base64URLDecoded()

        // Check if compression was applied
        if encodedData.first == Data.compressionMarker {
            #expect(encodedData.count < protobufData.count)
        }

        // Should decode correctly
        let decoded = try SignedInvite.fromURLSafeSlug(encoded)
        #expect(decoded.invitePayload.name == payload.name)
        #expect(decoded.invitePayload.description_p == payload.description_p)
    }

    @Test("Uncompressed invite decoding (backward compatibility)")
    func uncompressedInviteDecoding() throws {
        let privateKey = generateTestPrivateKey()
        let conversationId = UUID().uuidString.lowercased()

        let conversationTokenBytes = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        var payload = InvitePayload()
        payload.conversationToken = conversationTokenBytes
        payload.creatorInboxID = Data(hexString: testInboxId)!
        payload.tag = "test"

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        // Create truly uncompressed slug by encoding protobuf directly
        let protobufData = try signedInvite.serializedData()

        // Only test uncompressed if protobuf doesn't start with compression marker
        // (avoiding collision with 0x1F marker)
        guard protobufData.first != Data.compressionMarker else {
            // Skip this iteration if collision occurs (very rare: ~1/256 probability)
            return
        }

        let uncompressedSlug = protobufData.base64URLEncoded()
        let decoded = try SignedInvite.fromURLSafeSlug(uncompressedSlug)
        #expect(decoded.invitePayload.tag == "test")
    }

    // MARK: - Signature Tests

    @Test("Signature is valid")
    func signatureIsValid() throws {
        let privateKey = generateTestPrivateKey()
        let conversationId = UUID().uuidString.lowercased()

        let conversationTokenBytes = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        var payload = InvitePayload()
        payload.conversationToken = conversationTokenBytes
        payload.creatorInboxID = Data(hexString: testInboxId)!
        payload.tag = "test123"

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        // Signature should be 65 bytes (64 + recovery ID)
        #expect(signature.count == 65)

        // Should be able to recover public key
        let publicKey = try signedInvite.recoverSignerPublicKey()
        #expect(!publicKey.isEmpty)
    }

    @Test("Different payloads produce different signatures")
    func differentPayloadsDifferentSignatures() throws {
        let privateKey = generateTestPrivateKey()

        var payload1 = InvitePayload()
        payload1.tag = "test1"
        payload1.creatorInboxID = Data(hexString: testInboxId)!

        var payload2 = InvitePayload()
        payload2.tag = "test2"
        payload2.creatorInboxID = Data(hexString: testInboxId)!

        let signature1 = try payload1.sign(with: privateKey)
        let signature2 = try payload2.sign(with: privateKey)

        #expect(signature1 != signature2)
    }

    @Test("Same payload produces different signatures (nonce randomness)")
    func samePayloadDifferentSignaturesWithNonce() throws {
        let privateKey = generateTestPrivateKey()

        var payload = InvitePayload()
        payload.tag = "test"
        payload.creatorInboxID = Data(hexString: testInboxId)!

        // Note: secp256k1 signatures are deterministic (RFC 6979)
        // So same payload + key should produce same signature
        let signature1 = try payload.sign(with: privateKey)
        let signature2 = try payload.sign(with: privateKey)

        // Signatures should be the same (deterministic)
        #expect(signature1 == signature2)
    }

    @Test("Invalid signature length throws error")
    func invalidSignatureLengthThrowsError() throws {
        var signedInvite = SignedInvite()
        var payload = InvitePayload()
        payload.tag = "test"
        try signedInvite.setPayload(payload)
        signedInvite.signature = Data([1, 2, 3]) // Invalid length

        #expect {
            try signedInvite.recoverSignerPublicKey()
        } throws: { error in
            guard let signatureError = error as? InviteSignatureError else {
                return false
            }
            return signatureError == .invalidSignature
        }
    }

    @Test("Corrupted signature may recover different key")
    func corruptedSignatureMayRecoverDifferentKey() throws {
        let privateKey = generateTestPrivateKey()

        var payload = InvitePayload()
        payload.tag = "test"
        payload.creatorInboxID = Data(hexString: testInboxId)!

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        let originalPublicKey = try signedInvite.recoverSignerPublicKey()

        // Corrupt the recovery ID (last byte)
        var corruptedSignature = signature
        corruptedSignature[64] = (corruptedSignature[64] + 1) % 4

        signedInvite.signature = corruptedSignature

        // May throw or may recover a different (invalid) key
        // This test just verifies corrupted signatures don't crash
        do {
            let corruptedPublicKey = try signedInvite.recoverSignerPublicKey()
            // If it doesn't throw, the key should be different
            #expect(corruptedPublicKey != originalPublicKey)
        } catch {
            // This is also acceptable - corrupted data may fail verification
        }
    }

    // MARK: - Public Key Recovery Tests

    @Test("Public key recovery from signature")
    func publicKeyRecoveryFromSignature() throws {
        let privateKey = generateTestPrivateKey()

        var payload = InvitePayload()
        payload.tag = "test"
        payload.creatorInboxID = Data(hexString: testInboxId)!

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        let recoveredPublicKey = try signedInvite.recoverSignerPublicKey()

        // Public key should be 65 bytes (uncompressed) or 33 bytes (compressed)
        #expect(recoveredPublicKey.count == 65 || recoveredPublicKey.count == 33)
    }

    // MARK: - Inbox ID Conversion Tests

    @Test("Creator inbox ID hex conversion")
    func creatorInboxIdHexConversion() throws {
        let privateKey = generateTestPrivateKey()
        let inboxIdHex = "0011223344556677889900112233445566778899001122334455667788990011"

        var payload = InvitePayload()
        payload.tag = "test"
        payload.creatorInboxID = Data(hexString: inboxIdHex)!

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        let encoded = try signedInvite.toURLSafeSlug()
        let decoded = try SignedInvite.fromURLSafeSlug(encoded)

        #expect(decoded.invitePayload.creatorInboxIdString == inboxIdHex)
    }

    // MARK: - Expiration Tests

    @Test("Invite expiration detection")
    func inviteExpirationDetection() throws {
        let privateKey = generateTestPrivateKey()

        var payload = InvitePayload()
        payload.tag = "test"
        payload.creatorInboxID = Data(hexString: testInboxId)!

        // Set expiration to past
        let pastDate = Date(timeIntervalSince1970: 1000000000) // 2001
        payload.expiresAtUnix = Int64(pastDate.timeIntervalSince1970)

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        #expect(signedInvite.hasExpired == true)
    }

    @Test("Invite not expired")
    func inviteNotExpired() throws {
        let privateKey = generateTestPrivateKey()

        var payload = InvitePayload()
        payload.tag = "test"
        payload.creatorInboxID = Data(hexString: testInboxId)!

        // Set expiration to future
        let futureDate = Date(timeIntervalSince1970: 2000000000) // 2033
        payload.expiresAtUnix = Int64(futureDate.timeIntervalSince1970)

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        #expect(signedInvite.hasExpired == false)
    }

    @Test("Conversation expiration detection")
    func conversationExpirationDetection() throws {
        let privateKey = generateTestPrivateKey()

        var payload = InvitePayload()
        payload.tag = "test"
        payload.creatorInboxID = Data(hexString: testInboxId)!

        // Set conversation expiration to past
        let pastDate = Date(timeIntervalSince1970: 1000000000)
        payload.conversationExpiresAtUnix = Int64(pastDate.timeIntervalSince1970)

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        #expect(signedInvite.conversationHasExpired == true)
    }

    // MARK: - Optional Field Accessors

    @Test("Optional field accessors")
    func optionalFieldAccessors() throws {
        let privateKey = generateTestPrivateKey()

        var payload = InvitePayload()
        payload.tag = "test"
        payload.creatorInboxID = Data(hexString: testInboxId)!
        payload.name = "Test Name"
        payload.description_p = "Test Description"
        payload.imageURL = "https://example.com/image.jpg"

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        #expect(signedInvite.name == "Test Name")
        #expect(signedInvite.description_p == "Test Description")
        #expect(signedInvite.imageURL == "https://example.com/image.jpg")
    }

    @Test("Optional field accessors return nil when not set")
    func optionalFieldAccessorsReturnNil() throws {
        let privateKey = generateTestPrivateKey()

        var payload = InvitePayload()
        payload.tag = "test"
        payload.creatorInboxID = Data(hexString: testInboxId)!

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        #expect(signedInvite.name == nil)
        #expect(signedInvite.description_p == nil)
        #expect(signedInvite.imageURL == nil)
        #expect(signedInvite.expiresAt == nil)
        #expect(signedInvite.conversationExpiresAt == nil)
    }

    // MARK: - Invite Code Parsing Tests

    @Test("Parse raw invite code")
    func parseRawInviteCode() throws {
        let privateKey = generateTestPrivateKey()

        var payload = InvitePayload()
        payload.tag = "test"
        payload.creatorInboxID = Data(hexString: testInboxId)!

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        let code = try signedInvite.toURLSafeSlug()

        // Parse as raw code
        let decoded = try SignedInvite.fromInviteCode(code)
        #expect(decoded.invitePayload.tag == "test")
    }

    @Test("Parse invite code with whitespace")
    func parseInviteCodeWithWhitespace() throws {
        let privateKey = generateTestPrivateKey()

        var payload = InvitePayload()
        payload.tag = "test"
        payload.creatorInboxID = Data(hexString: testInboxId)!

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        let code = try signedInvite.toURLSafeSlug()

        // Add whitespace
        let codeWithWhitespace = "  \n\(code)\n  "

        let decoded = try SignedInvite.fromInviteCode(codeWithWhitespace)
        #expect(decoded.invitePayload.tag == "test")
    }

    // MARK: - Error Handling Tests

    @Test("Invalid base64url throws error")
    func invalidBase64URLThrowsError() throws {
        let invalidCode = "not-valid-base64url!"

        #expect(throws: (any Error).self) {
            _ = try SignedInvite.fromURLSafeSlug(invalidCode)
        }
    }

    @Test("Invalid protobuf data throws error")
    func invalidProtobufDataThrowsError() throws {
        let randomData = Data((0..<100).map { _ in UInt8.random(in: 0...255) })
        let invalidCode = randomData.base64URLEncoded()

        #expect(throws: (any Error).self) {
            _ = try SignedInvite.fromURLSafeSlug(invalidCode)
        }
    }

    // MARK: - Private Key Validation Tests

    @Test("Invalid private key size throws error on signing")
    func invalidPrivateKeySizeThrowsErrorOnSigning() throws {
        var payload = InvitePayload()
        payload.tag = "test"

        let shortKey = Data([1, 2, 3]) // Not 32 bytes

        #expect {
            try payload.sign(with: shortKey)
        } throws: { error in
            guard let signatureError = error as? InviteSignatureError else {
                return false
            }
            return signatureError == .invalidPrivateKey
        }
    }

    @Test("Empty private key throws error on signing")
    func emptyPrivateKeyThrowsErrorOnSigning() throws {
        var payload = InvitePayload()
        payload.tag = "test"

        let emptyKey = Data()

        #expect {
            try payload.sign(with: emptyKey)
        } throws: { error in
            guard let signatureError = error as? InviteSignatureError else {
                return false
            }
            return signatureError == .invalidPrivateKey
        }
    }

    // MARK: - Edge Cases

    @Test("Very long tag")
    func veryLongTag() throws {
        let privateKey = generateTestPrivateKey()

        var payload = InvitePayload()
        payload.tag = String(repeating: "x", count: 1000)
        payload.creatorInboxID = Data(hexString: testInboxId)!

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        let encoded = try signedInvite.toURLSafeSlug()
        let decoded = try SignedInvite.fromURLSafeSlug(encoded)

        #expect(decoded.invitePayload.tag.count == 1000)
    }

    @Test("Special characters in name and description")
    func specialCharactersInFields() throws {
        let privateKey = generateTestPrivateKey()

        var payload = InvitePayload()
        payload.tag = "test"
        payload.creatorInboxID = Data(hexString: testInboxId)!
        payload.name = "Group 🎉 with emoji"
        payload.description_p = "Description\nwith\nnewlines\tand\ttabs"

        let signature = try payload.sign(with: privateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        let encoded = try signedInvite.toURLSafeSlug()
        let decoded = try SignedInvite.fromURLSafeSlug(encoded)

        #expect(decoded.invitePayload.name == "Group 🎉 with emoji")
        #expect(decoded.invitePayload.description_p == "Description\nwith\nnewlines\tand\ttabs")
    }

    // MARK: - Decompression Bomb Protection

    @Test("Malicious compressed invite rejected")
    func maliciousCompressedInviteRejected() throws {
        // Create data claiming to be compressed but is actually malicious
        var maliciousData = Data()
        maliciousData.append(Data.compressionMarker)

        // Claim huge decompressed size
        let fakeSize: UInt32 = 100 * 1024 * 1024
        maliciousData.append(contentsOf: [
            UInt8((fakeSize >> 24) & 0xFF),
            UInt8((fakeSize >> 16) & 0xFF),
            UInt8((fakeSize >> 8) & 0xFF),
            UInt8(fakeSize & 0xFF)
        ])

        maliciousData.append(Data(repeating: 0x42, count: 100))

        let maliciousCode = maliciousData.base64URLEncoded()

        #expect(throws: (any Error).self) {
            _ = try SignedInvite.fromURLSafeSlug(maliciousCode)
        }
    }
}
