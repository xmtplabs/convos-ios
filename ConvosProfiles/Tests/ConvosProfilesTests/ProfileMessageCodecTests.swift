@testable import ConvosProfiles
import Foundation
import Testing

@Suite("ProfileUpdate Codec Tests")
struct ProfileUpdateCodecTests {
    let codec = ProfileUpdateCodec()

    @Test("Encode and decode profile update with name only")
    func roundTripNameOnly() throws {
        let update = ProfileUpdate(name: "Alice")

        let encoded = try codec.encode(content: update)
        let decoded = try codec.decode(content: encoded)

        #expect(decoded.hasName)
        #expect(decoded.name == "Alice")
        #expect(!decoded.hasEncryptedImage)
    }

    @Test("Encode and decode profile update with name and encrypted image")
    func roundTripNameAndImage() throws {
        var imageRef = EncryptedProfileImageRef()
        imageRef.url = "https://example.com/avatar.enc"
        imageRef.salt = Data(repeating: 0xAB, count: 32)
        imageRef.nonce = Data(repeating: 0xCD, count: 12)

        let update = ProfileUpdate(name: "Bob", encryptedImage: imageRef)

        let encoded = try codec.encode(content: update)
        let decoded = try codec.decode(content: encoded)

        #expect(decoded.name == "Bob")
        #expect(decoded.hasEncryptedImage)
        #expect(decoded.encryptedImage.url == "https://example.com/avatar.enc")
        #expect(decoded.encryptedImage.salt.count == 32)
        #expect(decoded.encryptedImage.nonce.count == 12)
    }

    @Test("Encode and decode empty profile update (clears profile)")
    func roundTripEmpty() throws {
        let update = ProfileUpdate()

        let encoded = try codec.encode(content: update)
        let decoded = try codec.decode(content: encoded)

        #expect(!decoded.hasName)
        #expect(!decoded.hasEncryptedImage)
    }

    @Test("Should not push")
    func shouldNotPush() throws {
        let update = ProfileUpdate(name: "Alice")
        #expect(try codec.shouldPush(content: update) == false)
    }

    @Test("Fallback returns nil")
    func fallbackReturnsNil() throws {
        let update = ProfileUpdate(name: "Alice")
        #expect(try codec.fallback(content: update) == nil)
    }
}

@Suite("ProfileSnapshot Codec Tests")
struct ProfileSnapshotCodecTests {
    let codec = ProfileSnapshotCodec()
    let inboxIdHex: String = "0011223344556677889900112233445566778899001122334455667788990011"

    @Test("Encode and decode snapshot with multiple profiles")
    func roundTripMultipleProfiles() throws {
        let profile1 = try #require(MemberProfile(
            inboxIdString: inboxIdHex,
            name: "Alice"
        ))

        let inboxId2 = "aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899"
        var imageRef = EncryptedProfileImageRef()
        imageRef.url = "https://example.com/bob.enc"
        imageRef.salt = Data(repeating: 0x01, count: 32)
        imageRef.nonce = Data(repeating: 0x02, count: 12)

        let profile2 = try #require(MemberProfile(
            inboxIdString: inboxId2,
            name: "Bob",
            encryptedImage: imageRef
        ))

        let snapshot = ProfileSnapshot(profiles: [profile1, profile2])

        let encoded = try codec.encode(content: snapshot)
        let decoded = try codec.decode(content: encoded)

        #expect(decoded.profiles.count == 2)
        #expect(decoded.profiles[0].name == "Alice")
        #expect(decoded.profiles[0].inboxIdString == inboxIdHex)
        #expect(decoded.profiles[1].name == "Bob")
        #expect(decoded.profiles[1].hasEncryptedImage)
        #expect(decoded.profiles[1].encryptedImage.url == "https://example.com/bob.enc")
    }

    @Test("Encode and decode empty snapshot")
    func roundTripEmpty() throws {
        let snapshot = ProfileSnapshot(profiles: [])

        let encoded = try codec.encode(content: snapshot)
        let decoded = try codec.decode(content: encoded)

        #expect(decoded.profiles.isEmpty)
    }

    @Test("Should not push")
    func shouldNotPush() throws {
        let snapshot = ProfileSnapshot()
        #expect(try codec.shouldPush(content: snapshot) == false)
    }

    @Test("Snapshot findProfile lookup")
    func snapshotFindProfile() throws {
        let profile = try #require(MemberProfile(
            inboxIdString: inboxIdHex,
            name: "Alice"
        ))
        let snapshot = ProfileSnapshot(profiles: [profile])

        let found = snapshot.findProfile(inboxId: inboxIdHex)
        #expect(found != nil)
        #expect(found?.name == "Alice")

        let notFound = snapshot.findProfile(inboxId: "ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff00")
        #expect(notFound == nil)
    }
}

@Suite("ProfileMessageHelpers Tests")
struct ProfileMessageHelpersTests {
    let validInboxId: String = "0011223344556677889900112233445566778899001122334455667788990011"

    @Test("MemberProfile init with valid hex inbox ID")
    func memberProfileValidInit() {
        let profile = MemberProfile(inboxIdString: validInboxId, name: "Alice")
        #expect(profile != nil)
        #expect(profile?.inboxIdString == validInboxId)
        #expect(profile?.name == "Alice")
    }

    @Test("MemberProfile init with invalid hex returns nil")
    func memberProfileInvalidHex() {
        let profile = MemberProfile(inboxIdString: "not-hex")
        #expect(profile == nil)
    }

    @Test("MemberProfile init with empty string returns nil")
    func memberProfileEmptyString() {
        let profile = MemberProfile(inboxIdString: "")
        #expect(profile == nil)
    }

    @Test("EncryptedProfileImageRef isValid")
    func imageRefValidation() {
        var valid = EncryptedProfileImageRef()
        valid.url = "https://example.com/test.enc"
        valid.salt = Data(repeating: 0xAB, count: 32)
        valid.nonce = Data(repeating: 0xCD, count: 12)
        #expect(valid.isValid)

        var noUrl = EncryptedProfileImageRef()
        noUrl.salt = Data(repeating: 0xAB, count: 32)
        noUrl.nonce = Data(repeating: 0xCD, count: 12)
        #expect(!noUrl.isValid)

        var badSalt = EncryptedProfileImageRef()
        badSalt.url = "https://example.com/test.enc"
        badSalt.salt = Data(repeating: 0xAB, count: 16)
        badSalt.nonce = Data(repeating: 0xCD, count: 12)
        #expect(!badSalt.isValid)
    }

    @Test("EncryptedProfileImageRef converts to and from EncryptedImageRef")
    func imageRefConversion() {
        var appDataRef = EncryptedImageRef()
        appDataRef.url = "https://example.com/test.enc"
        appDataRef.salt = Data(repeating: 0x01, count: 32)
        appDataRef.nonce = Data(repeating: 0x02, count: 12)

        let profileRef = EncryptedProfileImageRef(appDataRef)
        #expect(profileRef.url == appDataRef.url)
        #expect(profileRef.salt == appDataRef.salt)
        #expect(profileRef.nonce == appDataRef.nonce)

        let roundTripped = profileRef.asEncryptedImageRef
        #expect(roundTripped.url == appDataRef.url)
        #expect(roundTripped.salt == appDataRef.salt)
        #expect(roundTripped.nonce == appDataRef.nonce)
    }

    @Test("Snapshot size for 150 members is well under limits")
    func snapshotSizeAtScale() throws {
        var profiles: [MemberProfile] = []
        for i in 0..<150 {
            let hexDigit = String(format: "%02x", i % 256)
            let inboxId = String(repeating: hexDigit, count: 32)

            var imageRef = EncryptedProfileImageRef()
            imageRef.url = "https://cdn.example.com/profiles/\(UUID().uuidString).enc"
            imageRef.salt = Data(repeating: UInt8(i % 256), count: 32)
            imageRef.nonce = Data(repeating: UInt8(i % 256), count: 12)

            guard let profile = MemberProfile(
                inboxIdString: inboxId,
                name: "Member \(i) with a reasonably long display name",
                encryptedImage: imageRef
            ) else { continue }
            profiles.append(profile)
        }

        let snapshot = ProfileSnapshot(profiles: profiles)
        let data: Data = try snapshot.serializedData()

        #expect(profiles.count == 150)
        #expect(data.count < 100_000)
    }
}
