@testable import ConvosCore
import ConvosAppData
import Foundation
import Testing

// Note: Full integration tests require a running XMTP node.
// These tests verify that ConvosAppData types are properly re-exported.

@Suite("ConvosProfiles Re-export Tests")
struct ConvosProfilesTests {
    @Test("ConversationProfile is accessible via ConvosProfiles")
    func conversationProfileAccessible() {
        let profile = ConversationProfile(
            inboxIdString: "0011223344556677889900112233445566778899001122334455667788990011",
            name: "Test"
        )

        #expect(profile != nil)
        #expect(profile?.name == "Test")
    }

    @Test("EncryptedImageRef is accessible via ConvosProfiles")
    func encryptedImageRefAccessible() {
        var ref = EncryptedImageRef()
        ref.url = "https://example.com/test.bin"
        ref.salt = Data(repeating: 0xAB, count: 32)
        ref.nonce = Data(repeating: 0xCD, count: 12)

        #expect(ref.isValid == true)
    }

    @Test("ConversationCustomMetadata is accessible via ConvosProfiles")
    func customMetadataAccessible() throws {
        var metadata = ConversationCustomMetadata()
        metadata.tag = "test-tag"

        let profile = try #require(ConversationProfile(
            inboxIdString: "0011223344556677889900112233445566778899001122334455667788990011",
            name: "Alice"
        ))
        metadata.upsertProfile(profile)

        let encoded = try metadata.toCompactString()
        let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

        #expect(decoded.tag == "test-tag")
        #expect(decoded.profiles.count == 1)
        #expect(decoded.profiles[0].name == "Alice")
    }
}
