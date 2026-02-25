@testable import ConvosProfiles
@testable import ConvosProfilesCore
import Foundation
import Testing

// Note: Full integration tests require a running XMTP node.
// These tests verify the basic structure and types compile correctly.

@Suite("ProfileCoordinator Tests")
struct ProfileCoordinatorTests {
    @Test("ConversationProfile is re-exported from ConvosProfiles")
    func conversationProfileReExported() {
        // Verify that ConvosProfilesCore types are accessible via ConvosProfiles
        let profile = ConversationProfile(
            inboxIdString: "0011223344556677889900112233445566778899001122334455667788990011",
            name: "Test"
        )

        #expect(profile != nil)
    }

    @Test("EncryptedImageRef is re-exported from ConvosProfiles")
    func encryptedImageRefReExported() {
        var ref = EncryptedImageRef()
        ref.url = "https://example.com/test.bin"
        ref.salt = Data(repeating: 0xAB, count: 32)
        ref.nonce = Data(repeating: 0xCD, count: 12)

        #expect(ref.isValid == true)
    }
}
