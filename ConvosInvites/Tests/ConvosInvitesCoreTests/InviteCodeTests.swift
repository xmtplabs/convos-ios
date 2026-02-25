@testable import ConvosInvitesCore
import Foundation
import Testing

/// Comprehensive tests for InviteToken (conversation ID encryption)
///
/// Tests cover:
/// - UUID and string conversation ID encoding/decoding
/// - Encryption/decryption round-trip
/// - Key derivation with different inbox IDs
/// - Invalid format handling
/// - Version compatibility
/// - Security properties (AAD binding, key derivation)
@Suite("Invite Token Tests")
struct InviteCodeTests {
    // MARK: - Test Keys and Data

    /// Generate a valid 32-byte secp256k1 private key for testing
    private func generateTestPrivateKey() -> Data {
        // Use a deterministic "random" key for reproducible tests
        Data((0..<32).map { UInt8($0 * 7 % 256) })
    }

    private let testInboxId: String = "0011223344556677889900112233445566778899001122334455667788990011"

    // MARK: - UUID Token Tests

    @Test("UUID token round-trip")
    func uuidTokenRoundTrip() throws {
        let conversationId = UUID().uuidString.lowercased()
        let privateKey = generateTestPrivateKey()

        let tokenBytes = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        // UUID tokens should be exactly 46 bytes
        #expect(tokenBytes.count == InviteToken.uuidCodeSize)

        let decoded = try InviteToken.decrypt(
            tokenBytes: tokenBytes,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        #expect(decoded == conversationId)
    }

    @Test("UUID token size is deterministic")
    func uuidTokenSizeDeterministic() throws {
        let privateKey = generateTestPrivateKey()

        // Generate multiple UUID tokens
        let tokens = try (0..<10).map { _ in
            try InviteToken.encrypt(
                conversationId: UUID().uuidString.lowercased(),
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )
        }

        // All should be exactly 46 bytes
        for token in tokens {
            #expect(token.count == InviteToken.uuidCodeSize)
            #expect(token.count == 46)
        }
    }

    @Test("UUID case insensitivity")
    func uuidCaseInsensitivity() throws {
        let uuid = UUID()
        let privateKey = generateTestPrivateKey()

        let uppercase = uuid.uuidString
        let lowercase = uuid.uuidString.lowercased()

        let upperToken = try InviteToken.encrypt(
            conversationId: uppercase,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        let lowerToken = try InviteToken.encrypt(
            conversationId: lowercase,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        // Decoding should return lowercase
        let decodedUpper = try InviteToken.decrypt(
            tokenBytes: upperToken,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        let decodedLower = try InviteToken.decrypt(
            tokenBytes: lowerToken,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        #expect(decodedUpper == lowercase)
        #expect(decodedLower == lowercase)
    }

    // MARK: - String Token Tests

    @Test("String token round-trip")
    func stringTokenRoundTrip() throws {
        let conversationIds = [
            "my-conversation",
            "conversation_with_underscores",
            "conversation-123-abc",
            "c",
            String(repeating: "x", count: 255)
        ]

        let privateKey = generateTestPrivateKey()

        for conversationId in conversationIds {
            let tokenBytes = try InviteToken.encrypt(
                conversationId: conversationId,
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )

            // String tokens should be at least minEncodedSize
            #expect(tokenBytes.count >= InviteToken.minEncodedSize)

            let decoded = try InviteToken.decrypt(
                tokenBytes: tokenBytes,
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )

            #expect(decoded == conversationId)
        }
    }

    @Test("Long string token")
    func longStringToken() throws {
        let longId = String(repeating: "conversation-", count: 100) // ~1300 chars
        let privateKey = generateTestPrivateKey()

        let tokenBytes = try InviteToken.encrypt(
            conversationId: longId,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        let decoded = try InviteToken.decrypt(
            tokenBytes: tokenBytes,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        #expect(decoded == longId)
    }

    @Test("String token with special characters")
    func stringTokenSpecialCharacters() throws {
        let specialIds = [
            "conversation-with-emoji-🎉",
            "conversation\nwith\nnewlines",
            "conversation with spaces",
            "conversation\twith\ttabs"
        ]

        let privateKey = generateTestPrivateKey()

        for conversationId in specialIds {
            let tokenBytes = try InviteToken.encrypt(
                conversationId: conversationId,
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )

            let decoded = try InviteToken.decrypt(
                tokenBytes: tokenBytes,
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )

            #expect(decoded == conversationId)
        }
    }

    // MARK: - Key Derivation Tests

    @Test("Different inbox IDs produce different keys")
    func differentInboxIdsDifferentKeys() throws {
        let conversationId = UUID().uuidString.lowercased()
        let privateKey = generateTestPrivateKey()

        let inboxId1 = "0011223344556677889900112233445566778899001122334455667788990011"
        let inboxId2 = "1122334455667788990011223344556677889900112233445566778899001100"

        let token1 = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: inboxId1,
            privateKey: privateKey
        )

        let token2 = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: inboxId2,
            privateKey: privateKey
        )

        // Tokens should be different due to different inbox IDs in key derivation
        #expect(token1 != token2)
    }

    @Test("Different private keys produce different tokens")
    func differentPrivateKeysDifferentTokens() throws {
        let conversationId = UUID().uuidString.lowercased()

        let privateKey1 = Data((0..<32).map { UInt8($0) })
        let privateKey2 = Data((0..<32).map { UInt8($0 + 1) })

        let token1 = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: privateKey1
        )

        let token2 = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: privateKey2
        )

        #expect(token1 != token2)
    }

    // MARK: - AAD Binding Tests

    @Test("Wrong inbox ID fails decryption (AAD binding)")
    func wrongInboxIdFailsDecryption() throws {
        let conversationId = UUID().uuidString.lowercased()
        let privateKey = generateTestPrivateKey()
        let correctInboxId = "0011223344556677889900112233445566778899001122334455667788990011"
        let wrongInboxId = "1122334455667788990011223344556677889900112233445566778899001100"

        let tokenBytes = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: correctInboxId,
            privateKey: privateKey
        )

        // Attempting to decode with wrong inbox ID should fail
        #expect(throws: InviteTokenError.self) {
            _ = try InviteToken.decrypt(
                tokenBytes: tokenBytes,
                creatorInboxId: wrongInboxId,
                privateKey: privateKey
            )
        }
    }

    @Test("Wrong private key fails decryption")
    func wrongPrivateKeyFailsDecryption() throws {
        let conversationId = UUID().uuidString.lowercased()
        let correctKey = Data((0..<32).map { UInt8($0) })
        let wrongKey = Data((0..<32).map { UInt8($0 + 1) })

        let tokenBytes = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: correctKey
        )

        // Attempting to decode with wrong key should fail
        #expect(throws: InviteTokenError.self) {
            _ = try InviteToken.decrypt(
                tokenBytes: tokenBytes,
                creatorInboxId: testInboxId,
                privateKey: wrongKey
            )
        }
    }

    // MARK: - Version Tests

    @Test("Token has correct version byte")
    func tokenHasCorrectVersion() throws {
        let conversationId = UUID().uuidString.lowercased()
        let privateKey = generateTestPrivateKey()

        let tokenBytes = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        #expect(tokenBytes.first == InviteToken.formatVersion)
        #expect(tokenBytes.first == 1)
    }

    @Test("Unsupported version throws error")
    func unsupportedVersionThrowsError() throws {
        let conversationId = UUID().uuidString.lowercased()
        let privateKey = generateTestPrivateKey()

        var tokenBytes = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        // Corrupt the version byte
        tokenBytes[0] = 99

        #expect {
            try InviteToken.decrypt(
                tokenBytes: tokenBytes,
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )
        } throws: { error in
            guard let inviteError = error as? InviteTokenError,
                  case .unsupportedVersion(let version) = inviteError else {
                return false
            }
            return version == 99
        }
    }

    // MARK: - Invalid Format Tests

    @Test("Too short token throws error")
    func tooShortTokenThrowsError() throws {
        let privateKey = generateTestPrivateKey()

        // Create token shorter than minimum size
        let shortToken = Data([1, 2, 3, 4, 5])

        #expect {
            try InviteToken.decrypt(
                tokenBytes: shortToken,
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )
        } throws: { error in
            guard let inviteError = error as? InviteTokenError,
                  case .invalidFormat = inviteError else {
                return false
            }
            return true
        }
    }

    @Test("Empty token throws error")
    func emptyTokenThrowsError() throws {
        let privateKey = generateTestPrivateKey()
        let emptyToken = Data()

        #expect(throws: InviteTokenError.self) {
            _ = try InviteToken.decrypt(
                tokenBytes: emptyToken,
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )
        }
    }

    @Test("Corrupted ciphertext throws error")
    func corruptedCiphertextThrowsError() throws {
        let conversationId = UUID().uuidString.lowercased()
        let privateKey = generateTestPrivateKey()

        var tokenBytes = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        // Corrupt some bytes in the middle (ciphertext area)
        if tokenBytes.count > 20 {
            tokenBytes[20] ^= 0xFF
            tokenBytes[21] ^= 0xFF
        }

        #expect {
            try InviteToken.decrypt(
                tokenBytes: tokenBytes,
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )
        } throws: { error in
            guard let inviteError = error as? InviteTokenError else {
                return false
            }
            return inviteError == .cryptoOpenFailed
        }
    }

    @Test("Empty conversation ID throws error")
    func emptyConversationIdThrowsError() throws {
        let privateKey = generateTestPrivateKey()

        #expect {
            try InviteToken.encrypt(
                conversationId: "",
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )
        } throws: { error in
            guard let inviteError = error as? InviteTokenError else {
                return false
            }
            return inviteError == .emptyConversationId
        }
    }

    @Test("Maximum string length accepted")
    func maximumStringLength() throws {
        let maxLengthId = String(repeating: "x", count: InviteToken.maxStringLength)
        let privateKey = generateTestPrivateKey()

        let token = try InviteToken.encrypt(
            conversationId: maxLengthId,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        let decoded = try InviteToken.decrypt(
            tokenBytes: token,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        #expect(decoded == maxLengthId)
    }

    @Test("Exceeding maximum string length throws error")
    func exceedingMaxStringLength() throws {
        let tooLongId = String(repeating: "x", count: InviteToken.maxStringLength + 1)
        let privateKey = generateTestPrivateKey()

        #expect(throws: InviteTokenError.self) {
            _ = try InviteToken.encrypt(
                conversationId: tooLongId,
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )
        }
    }

    @Test("Non-standard key size still works with HKDF")
    func nonStandardKeySizeWorksWithHKDF() throws {
        let conversationId = UUID().uuidString.lowercased()
        // HKDF can derive from any non-empty key material
        let shortKey = Data([1, 2, 3])

        // Should succeed - HKDF accepts any non-empty input
        let tokenBytes = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: shortKey
        )

        #expect(tokenBytes.count >= InviteToken.minEncodedSize)

        // Should be able to decrypt with same short key
        let decoded = try InviteToken.decrypt(
            tokenBytes: tokenBytes,
            creatorInboxId: testInboxId,
            privateKey: shortKey
        )

        #expect(decoded == conversationId)
    }

    @Test("Empty private key throws error")
    func emptyPrivateKeyThrowsError() throws {
        let conversationId = UUID().uuidString.lowercased()
        let emptyKey = Data()

        #expect {
            try InviteToken.encrypt(
                conversationId: conversationId,
                creatorInboxId: testInboxId,
                privateKey: emptyKey
            )
        } throws: { error in
            guard let inviteError = error as? InviteTokenError else {
                return false
            }
            return inviteError == .badKeyMaterial
        }
    }

    // MARK: - Size Comparison Tests

    @Test("UUID tokens are smaller than string tokens")
    func uuidTokensSmallerThanStringTokens() throws {
        let uuid = UUID()
        let uuidString = uuid.uuidString.lowercased()
        let privateKey = generateTestPrivateKey()

        // Create token with UUID
        let uuidToken = try InviteToken.encrypt(
            conversationId: uuidString,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        // Create token with same UUID as plain string (forces string encoding)
        // We can force string encoding by using a non-UUID format
        let stringId = "conversation-" + uuidString
        let stringToken = try InviteToken.encrypt(
            conversationId: stringId,
            creatorInboxId: testInboxId,
            privateKey: privateKey
        )

        // UUID tokens should be smaller
        #expect(uuidToken.count < stringToken.count)
        #expect(uuidToken.count == 46)
    }

    @Test("Token size for various string lengths")
    func tokenSizeForVariousStringLengths() throws {
        let privateKey = generateTestPrivateKey()

        let testCases = [
            ("x", "single char"),
            ("short", "short"),
            (String(repeating: "x", count: 50), "50 chars"),
            (String(repeating: "x", count: 255), "255 chars"),
            (String(repeating: "x", count: 256), "256 chars")
        ]

        for (conversationId, description) in testCases {
            let token = try InviteToken.encrypt(
                conversationId: conversationId,
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )

            // Token should be at least minimum size
            #expect(token.count >= InviteToken.minEncodedSize, "Failed for \(description)")
        }
    }

    // MARK: - Randomness Tests

    @Test("Same input produces different tokens (nonce randomness)")
    func sameInputDifferentTokens() throws {
        let conversationId = UUID().uuidString.lowercased()
        let privateKey = generateTestPrivateKey()

        // Run multiple iterations to make nonce collision astronomically unlikely.
        for _ in 0..<10 {
            let token1 = try InviteToken.encrypt(
                conversationId: conversationId,
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )

            let token2 = try InviteToken.encrypt(
                conversationId: conversationId,
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )

            // due to random 12-byte nonce, tokens should be different
            #expect(token1 != token2)

            // but both should decode to the same conversation ID
            let decoded1 = try InviteToken.decrypt(
                tokenBytes: token1,
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )

            let decoded2 = try InviteToken.decrypt(
                tokenBytes: token2,
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )

            #expect(decoded1 == conversationId)
            #expect(decoded2 == conversationId)
        }
    }

    // MARK: - UTF-8 Encoding Tests

    @Test("Unicode conversation IDs")
    func unicodeConversationIds() throws {
        let unicodeIds = [
            "conversation-日本語",
            "conversation-🎉🎊",
            "conversation-العربية",
            "conversation-Русский"
        ]

        let privateKey = generateTestPrivateKey()

        for conversationId in unicodeIds {
            let token = try InviteToken.encrypt(
                conversationId: conversationId,
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )

            let decoded = try InviteToken.decrypt(
                tokenBytes: token,
                creatorInboxId: testInboxId,
                privateKey: privateKey
            )

            #expect(decoded == conversationId)
        }
    }
}
