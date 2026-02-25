@testable import ConvosAppData
import Foundation
import Testing

@Suite("ConversationCustomMetadata Serialization Tests")
struct SerializationTests {
    @Test("Round-trip serialization")
    func roundTripSerialization() throws {
        var metadata = ConversationCustomMetadata()
        metadata.tag = "test-tag-123"
        metadata.expiresAtUnix = 1234567890

        let encoded = try metadata.toCompactString()
        let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

        #expect(decoded.tag == "test-tag-123")
        #expect(decoded.expiresAtUnix == 1234567890)
    }

    @Test("Round-trip with profiles")
    func roundTripWithProfiles() throws {
        var metadata = ConversationCustomMetadata()
        metadata.tag = "invite-tag"

        let profile = try #require(ConversationProfile(
            inboxIdString: "0011223344556677889900112233445566778899001122334455667788990011",
            name: "Alice",
            imageUrl: "https://example.com/avatar.jpg"
        ))
        metadata.profiles.append(profile)

        let encoded = try metadata.toCompactString()
        let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

        #expect(decoded.profiles.count == 1)
        #expect(decoded.profiles[0].name == "Alice")
        #expect(decoded.profiles[0].image == "https://example.com/avatar.jpg")
    }

    @Test("Compression kicks in for large data")
    func compressionForLargeData() throws {
        var metadata = ConversationCustomMetadata()
        metadata.tag = String(repeating: "a", count: 200)

        // Add multiple profiles to increase size
        for i in 0..<10 {
            let inboxId = String(format: "%064x", i)
            if let profile = ConversationProfile(
                inboxIdString: inboxId,
                name: "User \(i)",
                imageUrl: "https://example.com/avatar\(i).jpg"
            ) {
                metadata.profiles.append(profile)
            }
        }

        let encoded = try metadata.toCompactString()
        let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

        #expect(decoded.profiles.count == 10)
        #expect(decoded.tag == metadata.tag)
    }

    @Test("Parse empty appData returns empty metadata")
    func parseEmptyAppData() {
        let metadata = ConversationCustomMetadata.parseAppData(nil)
        #expect(metadata.tag.isEmpty)
        #expect(metadata.profiles.isEmpty)
    }

    @Test("Parse invalid appData returns empty metadata")
    func parseInvalidAppData() {
        let metadata = ConversationCustomMetadata.parseAppData("not-valid-base64!")
        #expect(metadata.tag.isEmpty)
    }

    @Test("isEncodedMetadata detects valid encoded data")
    func isEncodedMetadataValid() throws {
        var metadata = ConversationCustomMetadata()
        metadata.tag = "test"
        let encoded = try metadata.toCompactString()

        #expect(ConversationCustomMetadata.isEncodedMetadata(encoded) == true)
    }

    @Test("isEncodedMetadata rejects plain text")
    func isEncodedMetadataRejectsPlainText() {
        #expect(ConversationCustomMetadata.isEncodedMetadata("Hello World!") == false)
        #expect(ConversationCustomMetadata.isEncodedMetadata("") == false)
    }
}

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
        let profile = ConversationProfile(inboxIdString: "not-valid-hex", name: "Test")
        #expect(profile == nil)
    }

    @Test("Effective image URL prefers encrypted")
    func effectiveImageUrlPrefersEncrypted() {
        var profile = ConversationProfile()
        profile.inboxID = Data(repeating: 0x11, count: 32)
        profile.image = "https://legacy.com/avatar.jpg"

        var encryptedRef = EncryptedImageRef()
        encryptedRef.url = "https://encrypted.com/avatar.bin"
        encryptedRef.salt = Data(repeating: 0xAB, count: 32)
        encryptedRef.nonce = Data(repeating: 0xCD, count: 12)
        profile.encryptedImage = encryptedRef

        #expect(profile.effectiveImageUrl == "https://encrypted.com/avatar.bin")
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
        ref.salt = Data(repeating: 0xAB, count: 16)
        ref.nonce = Data(repeating: 0xCD, count: 12)

        #expect(ref.isValid == false)
    }
}

@Suite("Metadata Profile Management Tests")
struct MetadataProfileTests {
    private let inboxId1: String = "0011223344556677889900112233445566778899001122334455667788990011"
    private let inboxId2: String = "1122334455667788990011223344556677889900112233445566778899001100"

    // swiftlint:disable:next force_unwrapping
    private func makeProfile(inboxId: String, name: String) -> ConversationProfile { ConversationProfile(inboxIdString: inboxId, name: name)! }

    @Test("Upsert profile to metadata")
    func upsertProfileToMetadata() {
        var metadata = ConversationCustomMetadata()
        let profile = makeProfile(inboxId: inboxId1, name: "Alice")

        metadata.upsertProfile(profile)

        #expect(metadata.profiles.count == 1)
        #expect(metadata.profiles[0].name == "Alice")
    }

    @Test("Upsert updates existing profile")
    func upsertUpdatesExisting() {
        var metadata = ConversationCustomMetadata()
        metadata.upsertProfile(makeProfile(inboxId: inboxId1, name: "Alice"))
        metadata.upsertProfile(makeProfile(inboxId: inboxId1, name: "Alice Updated"))

        #expect(metadata.profiles.count == 1)
        #expect(metadata.profiles[0].name == "Alice Updated")
    }

    @Test("Find profile in metadata")
    func findProfileInMetadata() {
        var metadata = ConversationCustomMetadata()
        metadata.upsertProfile(makeProfile(inboxId: inboxId1, name: "Alice"))
        metadata.upsertProfile(makeProfile(inboxId: inboxId2, name: "Bob"))

        let found = metadata.findProfile(inboxId: inboxId2)

        #expect(found?.name == "Bob")
    }

    @Test("Remove profile from metadata")
    func removeProfileFromMetadata() {
        var metadata = ConversationCustomMetadata()
        metadata.upsertProfile(makeProfile(inboxId: inboxId1, name: "Alice"))

        let removed = metadata.removeProfile(inboxId: inboxId1)

        #expect(removed == true)
        #expect(metadata.profiles.isEmpty)
    }
}

@Suite("Data Hex Tests")
struct DataHexTests {
    @Test("Hex string round-trip")
    func hexStringRoundTrip() {
        let original = Data([0x00, 0x11, 0x22, 0x33, 0xFF])
        let hexString = original.toHexString()
        let decoded = Data(hexString: hexString)

        #expect(hexString == "001122330xff".replacingOccurrences(of: "0x", with: ""))
        #expect(decoded == original)
    }

    @Test("Hex with 0x prefix")
    func hexWithPrefix() {
        let data = Data(hexString: "0x001122")
        #expect(data == Data([0x00, 0x11, 0x22]))
    }

    @Test("Invalid hex returns nil")
    func invalidHexReturnsNil() {
        #expect(Data(hexString: "gg") == nil)
        #expect(Data(hexString: "123") == nil)  // Odd length
    }
}
