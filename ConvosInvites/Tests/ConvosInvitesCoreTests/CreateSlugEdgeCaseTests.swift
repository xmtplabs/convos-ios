@testable import ConvosInvitesCore
import Foundation
import Testing

@Suite("createSlug Edge Cases")
struct CreateSlugEdgeCaseTests {
    let validPrivateKey: Data = Data(repeating: 0x42, count: 32)
    let validInboxId: String = Data(repeating: 0xAB, count: 32).toHexString()

    @Test("createSlug with invalid hex inbox ID throws")
    func invalidInboxIdThrows() {
        #expect(throws: InviteEncodingError.self) {
            _ = try SignedInvite.createSlug(
                conversationId: "test",
                creatorInboxId: "not-valid-hex",
                privateKey: validPrivateKey,
                tag: "tag"
            )
        }
    }

    @Test("createSlug with empty inbox ID throws")
    func emptyInboxIdThrows() {
        #expect(throws: InviteEncodingError.self) {
            _ = try SignedInvite.createSlug(
                conversationId: "test",
                creatorInboxId: "",
                privateKey: validPrivateKey,
                tag: "tag"
            )
        }
    }

    @Test("createSlug with empty conversation ID throws")
    func emptyConversationIdThrows() {
        #expect(throws: InviteTokenError.self) {
            _ = try SignedInvite.createSlug(
                conversationId: "",
                creatorInboxId: validInboxId,
                privateKey: validPrivateKey,
                tag: "tag"
            )
        }
    }

    @Test("createSlug with invalid private key throws")
    func invalidPrivateKeyThrows() {
        #expect(throws: (any Error).self) {
            _ = try SignedInvite.createSlug(
                conversationId: "test",
                creatorInboxId: validInboxId,
                privateKey: Data(repeating: 0x42, count: 16),
                tag: "tag"
            )
        }
    }

    @Test("createSlug with conversationExpiresAt round-trips")
    func conversationExpiresAtRoundTrip() throws {
        let convExpiry = Date(timeIntervalSince1970: 2_500_000_000)
        let slug = try SignedInvite.createSlug(
            conversationId: "convo-1",
            creatorInboxId: validInboxId,
            privateKey: validPrivateKey,
            tag: "tag",
            options: InviteSlugOptions(conversationExpiresAt: convExpiry)
        )

        let decoded = try SignedInvite.fromURLSafeSlug(slug)
        #expect(decoded.conversationExpiresAt == convExpiry)
    }

    @Test("createSlug with empty tag throws")
    func emptyTagThrows() {
        #expect(throws: InviteTokenError.self) {
            _ = try SignedInvite.createSlug(
                conversationId: "convo-1",
                creatorInboxId: validInboxId,
                privateKey: validPrivateKey,
                tag: ""
            )
        }
    }

    @Test("createSlug with unicode conversation ID round-trips")
    func unicodeConversationId() throws {
        let slug = try SignedInvite.createSlug(
            conversationId: "群組-聊天-🎉",
            creatorInboxId: validInboxId,
            privateKey: validPrivateKey,
            tag: "unicode-tag"
        )

        let decoded = try SignedInvite.fromURLSafeSlug(slug)
        let decryptedId = try InviteToken.decrypt(
            tokenBytes: decoded.invitePayload.conversationToken,
            creatorInboxId: validInboxId,
            privateKey: validPrivateKey
        )
        #expect(decryptedId == "群組-聊天-🎉")
    }
}
