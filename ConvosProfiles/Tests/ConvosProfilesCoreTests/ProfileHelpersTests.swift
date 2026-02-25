@testable import ConvosProfilesCore
import Foundation
import Testing

@Suite("ConversationProfile Tests")
struct ConversationProfileTests {
    private let testInboxId: String = "0011223344556677889900112233445566778899001122334455667788990011"

    @Test("Create profile with name and image URL")
    func createProfileWithNameAndImage() {
        let profile = ConversationProfile(
            inboxIdString: testInboxId,
            name: "Alice",
            imageUrl: "https://example.com/avatar.jpg"
        )

        #expect(profile != nil)
        #expect(profile?.name == "Alice")
        #expect(profile?.image == "https://example.com/avatar.jpg")
        #expect(profile?.inboxIdString == testInboxId)
    }

    @Test("Create profile with encrypted image")
    func createProfileWithEncryptedImage() {
        var encryptedRef = EncryptedImageRef()
        encryptedRef.url = "https://s3.example.com/encrypted.bin"
        encryptedRef.salt = Data(repeating: 0xAB, count: 32)
        encryptedRef.nonce = Data(repeating: 0xCD, count: 12)

        let profile = ConversationProfile(
            inboxIdString: testInboxId,
            name: "Bob",
            encryptedImageRef: encryptedRef
        )

        #expect(profile != nil)
        #expect(profile?.name == "Bob")
        #expect(profile?.hasEncryptedImage == true)
        #expect(profile?.encryptedImage.isValid == true)
        #expect(profile?.effectiveImageUrl == "https://s3.example.com/encrypted.bin")
    }

    @Test("Invalid inbox ID returns nil")
    func invalidInboxIdReturnsNil() {
        let profile = ConversationProfile(
            inboxIdString: "not-valid-hex",
            name: "Test"
        )

        #expect(profile == nil)
    }

    @Test("Empty inbox ID returns nil")
    func emptyInboxIdReturnsNil() {
        let profile = ConversationProfile(
            inboxIdString: "",
            name: "Test"
        )

        #expect(profile == nil)
    }

    @Test("Effective image URL prefers encrypted over legacy")
    func effectiveImageUrlPrefersEncrypted() {
        var profile = ConversationProfile()
        profile.inboxID = Data(repeating: 0x11, count: 32)
        profile.name = "Test"
        profile.image = "https://legacy.com/avatar.jpg"

        var encryptedRef = EncryptedImageRef()
        encryptedRef.url = "https://encrypted.com/avatar.bin"
        encryptedRef.salt = Data(repeating: 0xAB, count: 32)
        encryptedRef.nonce = Data(repeating: 0xCD, count: 12)
        profile.encryptedImage = encryptedRef

        #expect(profile.effectiveImageUrl == "https://encrypted.com/avatar.bin")
    }

    @Test("Effective image URL falls back to legacy")
    func effectiveImageUrlFallsBackToLegacy() {
        var profile = ConversationProfile()
        profile.inboxID = Data(repeating: 0x11, count: 32)
        profile.image = "https://legacy.com/avatar.jpg"

        #expect(profile.effectiveImageUrl == "https://legacy.com/avatar.jpg")
    }

    @Test("Inbox ID string conversion")
    func inboxIdStringConversion() {
        var profile = ConversationProfile()
        profile.inboxID = Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77])

        #expect(profile.inboxIdString == "0011223344556677")
    }
}

@Suite("EncryptedImageRef Tests")
struct EncryptedImageRefTests {
    @Test("Valid encrypted image ref")
    func validEncryptedImageRef() {
        var ref = EncryptedImageRef()
        ref.url = "https://example.com/image.bin"
        ref.salt = Data(repeating: 0xAB, count: 32)
        ref.nonce = Data(repeating: 0xCD, count: 12)

        #expect(ref.isValid == true)
    }

    @Test("Invalid - empty URL")
    func invalidEmptyUrl() {
        var ref = EncryptedImageRef()
        ref.url = ""
        ref.salt = Data(repeating: 0xAB, count: 32)
        ref.nonce = Data(repeating: 0xCD, count: 12)

        #expect(ref.isValid == false)
    }

    @Test("Invalid - wrong salt size")
    func invalidWrongSaltSize() {
        var ref = EncryptedImageRef()
        ref.url = "https://example.com/image.bin"
        ref.salt = Data(repeating: 0xAB, count: 16)  // Should be 32
        ref.nonce = Data(repeating: 0xCD, count: 12)

        #expect(ref.isValid == false)
    }

    @Test("Invalid - wrong nonce size")
    func invalidWrongNonceSize() {
        var ref = EncryptedImageRef()
        ref.url = "https://example.com/image.bin"
        ref.salt = Data(repeating: 0xAB, count: 32)
        ref.nonce = Data(repeating: 0xCD, count: 16)  // Should be 12

        #expect(ref.isValid == false)
    }
}

@Suite("Profile Collection Tests")
struct ProfileCollectionTests {
    private let inboxId1: String = "0011223344556677889900112233445566778899001122334455667788990011"
    private let inboxId2: String = "1122334455667788990011223344556677889900112233445566778899001100"

    @Test("Upsert adds new profile")
    func upsertAddsNewProfile() {
        var profiles: [ConversationProfile] = []
        let profile = ConversationProfile(inboxIdString: inboxId1, name: "Alice")!

        profiles.upsert(profile)

        #expect(profiles.count == 1)
        #expect(profiles[0].name == "Alice")
    }

    @Test("Upsert updates existing profile")
    func upsertUpdatesExistingProfile() {
        var profiles: [ConversationProfile] = []
        let profile1 = ConversationProfile(inboxIdString: inboxId1, name: "Alice")!
        let profile2 = ConversationProfile(inboxIdString: inboxId1, name: "Alice Updated")!

        profiles.upsert(profile1)
        profiles.upsert(profile2)

        #expect(profiles.count == 1)
        #expect(profiles[0].name == "Alice Updated")
    }

    @Test("Find profile by inbox ID")
    func findProfileByInboxId() {
        var profiles: [ConversationProfile] = []
        profiles.upsert(ConversationProfile(inboxIdString: inboxId1, name: "Alice")!)
        profiles.upsert(ConversationProfile(inboxIdString: inboxId2, name: "Bob")!)

        let found = profiles.find(inboxId: inboxId2)

        #expect(found?.name == "Bob")
    }

    @Test("Find returns nil for unknown inbox ID")
    func findReturnsNilForUnknown() {
        var profiles: [ConversationProfile] = []
        profiles.upsert(ConversationProfile(inboxIdString: inboxId1, name: "Alice")!)

        let found = profiles.find(inboxId: inboxId2)

        #expect(found == nil)
    }

    @Test("Remove profile by inbox ID")
    func removeProfileByInboxId() {
        var profiles: [ConversationProfile] = []
        profiles.upsert(ConversationProfile(inboxIdString: inboxId1, name: "Alice")!)
        profiles.upsert(ConversationProfile(inboxIdString: inboxId2, name: "Bob")!)

        let removed = profiles.remove(inboxId: inboxId1)

        #expect(removed == true)
        #expect(profiles.count == 1)
        #expect(profiles[0].name == "Bob")
    }

    @Test("Remove returns false for unknown inbox ID")
    func removeReturnsFalseForUnknown() {
        var profiles: [ConversationProfile] = []
        profiles.upsert(ConversationProfile(inboxIdString: inboxId1, name: "Alice")!)

        let removed = profiles.remove(inboxId: inboxId2)

        #expect(removed == false)
        #expect(profiles.count == 1)
    }
}
