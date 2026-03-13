@testable import ConvosProfiles
import Foundation
import Testing

@Suite("ProfileUpdate Codec Tests")
struct ProfileUpdateCodecTests {
    let codec: ProfileUpdateCodec = ProfileUpdateCodec()

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

    @Test("Encode and decode profile update with agent member kind")
    func roundTripAgentMemberKind() throws {
        var update = ProfileUpdate(name: "My Agent")
        update.memberKind = .agent

        let encoded = try codec.encode(content: update)
        let decoded = try codec.decode(content: encoded)

        #expect(decoded.name == "My Agent")
        #expect(decoded.memberKind == .agent)
    }

    @Test("Member kind defaults to unspecified")
    func memberKindDefaultsToUnspecified() throws {
        let update = ProfileUpdate(name: "Alice")

        let encoded = try codec.encode(content: update)
        let decoded = try codec.decode(content: encoded)

        #expect(decoded.memberKind == .unspecified)
    }
}

@Suite("ProfileSnapshot Codec Tests")
struct ProfileSnapshotCodecTests {
    let codec: ProfileSnapshotCodec = ProfileSnapshotCodec()
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

    @Test("Snapshot preserves member kind")
    func snapshotPreservesMemberKind() throws {
        var agentProfile = try #require(MemberProfile(
            inboxIdString: inboxIdHex,
            name: "My Agent"
        ))
        agentProfile.memberKind = .agent

        let snapshot = ProfileSnapshot(profiles: [agentProfile])
        let encoded = try codec.encode(content: snapshot)
        let decoded = try codec.decode(content: encoded)

        #expect(decoded.profiles.count == 1)
        #expect(decoded.profiles[0].memberKind == .agent)
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

@Suite("ProfileMetadata Tests")
struct ProfileMetadataTests {
    let updateCodec: ProfileUpdateCodec = ProfileUpdateCodec()
    let snapshotCodec: ProfileSnapshotCodec = ProfileSnapshotCodec()

    @Test("ProfileMetadataValue round-trips through proto")
    func metadataValueRoundTrip() {
        let stringVal = MetadataValue(ProfileMetadataValue.string("hello"))
        #expect(stringVal.typed == .string("hello"))

        let numberVal = MetadataValue(ProfileMetadataValue.number(3.14))
        #expect(numberVal.typed == .number(3.14))

        let boolVal = MetadataValue(ProfileMetadataValue.bool(true))
        #expect(boolVal.typed == .bool(true))
    }

    @Test("Empty MetadataValue returns nil typed")
    func emptyMetadataValue() {
        let empty = MetadataValue()
        #expect(empty.typed == nil)
    }

    @Test("ProfileUpdate with metadata round-trips through codec")
    func updateWithMetadata() throws {
        let metadata: ProfileMetadata = [
            "bio": .string("Swift developer"),
            "opacity": .number(0.85),
            "verified": .bool(true)
        ]
        let update = ProfileUpdate(name: "Alice", metadata: metadata)

        let encoded = try updateCodec.encode(content: update)
        let decoded = try updateCodec.decode(content: encoded)

        #expect(decoded.name == "Alice")
        #expect(decoded.profileMetadata["bio"] == .string("Swift developer"))
        #expect(decoded.profileMetadata["opacity"] == .number(0.85))
        #expect(decoded.profileMetadata["verified"] == .bool(true))
        #expect(decoded.profileMetadata.count == 3)
    }

    @Test("ProfileUpdate without metadata has empty profileMetadata")
    func updateWithoutMetadata() throws {
        let update = ProfileUpdate(name: "Bob")

        let encoded = try updateCodec.encode(content: update)
        let decoded = try updateCodec.decode(content: encoded)

        #expect(decoded.profileMetadata.isEmpty)
    }

    @Test("MemberProfile with metadata round-trips through snapshot codec")
    func snapshotWithMetadata() throws {
        let inboxId = String(repeating: "ab", count: 32)
        let metadata: ProfileMetadata = [
            "status": .string("online"),
            "score": .number(42.0)
        ]
        guard var profile = MemberProfile(inboxIdString: inboxId, name: "Charlie", metadata: metadata) else {
            Issue.record("Failed to create MemberProfile")
            return
        }
        let snapshot = ProfileSnapshot(profiles: [profile])

        let encoded = try snapshotCodec.encode(content: snapshot)
        let decoded = try snapshotCodec.decode(content: encoded)

        #expect(decoded.profiles.count == 1)
        let decodedProfile = decoded.profiles[0]
        #expect(decodedProfile.name == "Charlie")
        #expect(decodedProfile.profileMetadata["status"] == .string("online"))
        #expect(decodedProfile.profileMetadata["score"] == .number(42.0))
    }

    @Test("ProfileMetadata converts between Swift and proto maps")
    func metadataMapConversion() {
        let metadata: ProfileMetadata = [
            "key1": .string("value1"),
            "key2": .number(99.9),
            "key3": .bool(false)
        ]

        let protoMap = metadata.asProtoMap
        let roundTripped = protoMap.asProfileMetadata

        #expect(roundTripped == metadata)
    }

    @Test("ProfileMetadataValue is Codable")
    func metadataValueCodable() throws {
        let values: [ProfileMetadataValue] = [
            .string("test"),
            .number(2.718),
            .bool(true)
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for value in values {
            let data = try encoder.encode(value)
            let decoded = try decoder.decode(ProfileMetadataValue.self, from: data)
            #expect(decoded == value)
        }
    }

    @Test("ProfileMetadata dictionary is Codable for DB storage")
    func metadataDictionaryCodable() throws {
        let metadata: ProfileMetadata = [
            "bio": .string("Hello world"),
            "level": .number(5.0),
            "premium": .bool(true)
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let data = try encoder.encode(metadata)
        let decoded = try decoder.decode(ProfileMetadata.self, from: data)

        #expect(decoded == metadata)
    }
}
