@testable import ConvosInvitesCore
import Foundation
import Testing

@Suite("InviteToken Tests")
struct InviteTokenTests {
    // Test private key (32 bytes)
    let testPrivateKey: Data = Data(repeating: 0x42, count: 32)
    let testInboxId: String = "abc123def456"

    @Test("Encrypt and decrypt UUID conversation ID")
    func encryptDecryptUUID() throws {
        let conversationId = UUID().uuidString.lowercased()

        let encrypted = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: testPrivateKey
        )

        #expect(encrypted.count == InviteToken.uuidCodeSize)

        let decrypted = try InviteToken.decrypt(
            tokenBytes: encrypted,
            creatorInboxId: testInboxId,
            privateKey: testPrivateKey
        )

        #expect(decrypted == conversationId)
    }

    @Test("Encrypt and decrypt string conversation ID")
    func encryptDecryptString() throws {
        let conversationId = "custom-conversation-id-12345"

        let encrypted = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: testPrivateKey
        )

        let decrypted = try InviteToken.decrypt(
            tokenBytes: encrypted,
            creatorInboxId: testInboxId,
            privateKey: testPrivateKey
        )

        #expect(decrypted == conversationId)
    }

    @Test("Decryption fails with wrong private key")
    func wrongPrivateKey() throws {
        let conversationId = UUID().uuidString.lowercased()

        let encrypted = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: testPrivateKey
        )

        let wrongKey = Data(repeating: 0x99, count: 32)

        #expect(throws: InviteTokenError.self) {
            _ = try InviteToken.decrypt(
                tokenBytes: encrypted,
                creatorInboxId: testInboxId,
                privateKey: wrongKey
            )
        }
    }

    @Test("Decryption fails with wrong inbox ID")
    func wrongInboxId() throws {
        let conversationId = UUID().uuidString.lowercased()

        let encrypted = try InviteToken.encrypt(
            conversationId: conversationId,
            creatorInboxId: testInboxId,
            privateKey: testPrivateKey
        )

        #expect(throws: InviteTokenError.self) {
            _ = try InviteToken.decrypt(
                tokenBytes: encrypted,
                creatorInboxId: "wrong-inbox-id",
                privateKey: testPrivateKey
            )
        }
    }

    @Test("Empty conversation ID throws error")
    func emptyConversationId() throws {
        #expect(throws: InviteTokenError.emptyConversationId) {
            _ = try InviteToken.encrypt(
                conversationId: "",
                creatorInboxId: testInboxId,
                privateKey: testPrivateKey
            )
        }
    }

    @Test("Empty private key throws error")
    func emptyPrivateKey() throws {
        #expect(throws: InviteTokenError.badKeyMaterial) {
            _ = try InviteToken.encrypt(
                conversationId: "test",
                creatorInboxId: testInboxId,
                privateKey: Data()
            )
        }
    }
}
