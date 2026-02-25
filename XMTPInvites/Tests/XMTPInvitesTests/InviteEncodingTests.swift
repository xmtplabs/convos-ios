import Foundation
import Testing
@testable import XMTPInvites

@Suite("InviteEncoding Tests")
struct InviteEncodingTests {
    let testPrivateKey = Data(repeating: 0x42, count: 32)

    @Test("Encode and decode signed invite")
    func encodeDecodeRoundtrip() throws {
        var payload = InvitePayload()
        payload.tag = "roundtrip-test"
        payload.conversationToken = Data([1, 2, 3, 4, 5, 6, 7, 8])
        payload.creatorInboxID = Data(repeating: 0xCD, count: 32)
        payload.name = "Test Conversation"

        let signature = try payload.sign(with: testPrivateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        // Encode to slug
        let slug = try signedInvite.toURLSafeSlug()
        #expect(!slug.isEmpty)

        // Decode back
        let decoded = try SignedInvite.fromURLSafeSlug(slug)

        // Verify payload matches
        #expect(decoded.invitePayload.tag == "roundtrip-test")
        #expect(decoded.invitePayload.name == "Test Conversation")
        #expect(decoded.signature == signature)
    }

    @Test("URL-safe Base64 encoding")
    func urlSafeEncoding() throws {
        var payload = InvitePayload()
        payload.tag = "base64-test"
        payload.conversationToken = Data([255, 254, 253]) // Will produce +/= in standard base64

        let signature = try payload.sign(with: testPrivateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        let slug = try signedInvite.toURLSafeSlug()

        // Should not contain standard base64 special chars
        #expect(!slug.contains("+"))
        #expect(!slug.contains("/"))
        #expect(!slug.contains("="))

        // Should contain URL-safe replacements
        // (might contain - and _ if those bytes are present)
    }

    @Test("iMessage separator insertion")
    func separatorInsertion() throws {
        // Create a payload large enough to exceed 300 chars
        var payload = InvitePayload()
        payload.tag = String(repeating: "a", count: 10)
        payload.conversationToken = Data(repeating: 0xFF, count: 200)
        payload.creatorInboxID = Data(repeating: 0xAB, count: 32)
        payload.name = String(repeating: "n", count: 50)
        payload.description_p = String(repeating: "d", count: 100)

        let signature = try payload.sign(with: testPrivateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        let slug = try signedInvite.toURLSafeSlug()

        // Should contain asterisks for iMessage compatibility
        if slug.replacingOccurrences(of: "*", with: "").count > 300 {
            #expect(slug.contains("*"))
        }

        // Should still decode correctly
        let decoded = try SignedInvite.fromURLSafeSlug(slug)
        #expect(decoded.invitePayload.tag == payload.tag)
    }

    @Test("Decode from convos URL")
    func decodeFromURL() throws {
        var payload = InvitePayload()
        payload.tag = "url-test"
        payload.conversationToken = Data([1, 2, 3])

        let signature = try payload.sign(with: testPrivateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        let slug = try signedInvite.toURLSafeSlug()
        let fullURL = "https://convos.org/i/\(slug)"

        let decoded = try SignedInvite.fromInviteCode(fullURL)
        #expect(decoded.invitePayload.tag == "url-test")
    }

    @Test("Expiration accessors")
    func expirationAccessors() throws {
        var payload = InvitePayload()
        payload.tag = "expiry-test"
        payload.expiresAtUnix = Int64(Date().timeIntervalSince1970 + 3600) // 1 hour from now
        payload.conversationExpiresAtUnix = Int64(Date().timeIntervalSince1970 + 86400) // 1 day from now
        payload.expiresAfterUse = true

        let signature = try payload.sign(with: testPrivateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        #expect(signedInvite.expiresAt != nil)
        #expect(signedInvite.conversationExpiresAt != nil)
        #expect(signedInvite.expiresAfterUse == true)
        #expect(signedInvite.hasExpired == false)
        #expect(signedInvite.conversationHasExpired == false)
    }

    @Test("Expired invite detection")
    func expiredInviteDetection() throws {
        var payload = InvitePayload()
        payload.tag = "expired-test"
        payload.expiresAtUnix = Int64(Date().timeIntervalSince1970 - 3600) // 1 hour ago

        let signature = try payload.sign(with: testPrivateKey)

        var signedInvite = SignedInvite()
        try signedInvite.setPayload(payload)
        signedInvite.signature = signature

        #expect(signedInvite.hasExpired == true)
    }
}
