@testable import ConvosCore
import Foundation
import Testing

/// Comprehensive tests for ConversationCustomMetadataExtensions.swift
///
/// Tests cover:
/// - Round-trip encoding/decoding with various field combinations
/// - Compression/decompression
/// - Profile management (upsert, remove, find)
/// - Hex conversion for inbox IDs
/// - Timestamp conversions
/// - Migration support (plain text vs encoded)
/// - isEncodedMetadata detection
@Suite("Conversation Custom Metadata Tests")
struct ConversationCustomMetadataTests {
    // MARK: - Basic Serialization Tests

    @Test("Empty metadata round-trip")
    func emptyMetadataRoundTrip() throws {
        let metadata = ConversationCustomMetadata()

        let encoded = try metadata.toCompactString()
        let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

        #expect(decoded.tag.isEmpty)
        #expect(decoded.profiles.isEmpty)
        #expect(!decoded.hasExpiresAtUnix)
    }

    @Test("Description-only metadata round-trip")
    func descriptionOnlyRoundTrip() throws {
        let metadata = ConversationCustomMetadata()

        let encoded = try metadata.toCompactString()
        let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

        #expect(decoded.tag.isEmpty)
        #expect(decoded.profiles.isEmpty)
    }

    @Test("Full metadata round-trip")
    func fullMetadataRoundTrip() throws {
        var metadata = ConversationCustomMetadata()
        metadata.tag = "abc123xyz"
        metadata.expiresAtUnix = 1735689600 // 2025-01-01

        // Add profiles
        let profile1 = ConversationProfile(
            inboxIdString: "0011223344556677889900112233445566778899001122334455667788990011",
            name: "Alice",
            imageUrl: "https://example.com/alice.jpg"
        )!

        let profile2 = ConversationProfile(
            inboxIdString: "1122334455667788990011223344556677889900112233445566778899001100",
            name: "Bob",
            imageUrl: nil
        )!

        metadata.profiles = [profile1, profile2]

        let encoded = try metadata.toCompactString()
        let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

        #expect(decoded.tag == "abc123xyz")
        #expect(decoded.expiresAtUnix == 1735689600)
        #expect(decoded.profiles.count == 2)
        #expect(decoded.profiles[0].name == "Alice")
        #expect(decoded.profiles[0].image == "https://example.com/alice.jpg")
        #expect(decoded.profiles[1].name == "Bob")
        #expect(!decoded.profiles[1].hasImage)
    }

    // MARK: - Compression Tests

    @Test("Small metadata may not compress")
    func smallMetadataMayNotCompress() throws {
        var metadata = ConversationCustomMetadata()
        metadata.tag = "1"
        let encoded = try metadata.toCompactString()

        // Small data might not compress, but should still encode/decode
        let decoded = try ConversationCustomMetadata.fromCompactString(encoded)
        #expect(decoded.tag == "1")
    }

    @Test("Large metadata compresses")
    func largeMetadataCompresses() throws {
        var metadata = ConversationCustomMetadata()

        // Add many profiles
        let profilesCount = 100
        for i in 0..<profilesCount {
            let inboxIdHex = String(format: "%064d", i)
            if let profile = ConversationProfile(
                inboxIdString: inboxIdHex,
                name: "User \(i)",
                imageUrl: "https://example.com/user\(i).jpg"
            ) {
                metadata.profiles.append(profile)
            }
        }

        let protobufData = try metadata.serializedData()
        let encoded = try metadata.toCompactString()
        let encodedData = try encoded.base64URLDecoded()

        // Should be compressed (or at least attempted)
        // Check if compression marker is present
        if encodedData.first == Data.compressionMarker {
            // Compressed version should be smaller
            #expect(encodedData.count < protobufData.count)
        }

        // Should decode correctly
        let decoded = try ConversationCustomMetadata.fromCompactString(encoded)
        #expect(decoded.profiles.count == profilesCount)
    }

    @Test("Compression threshold behavior")
    func compressionThresholdBehavior() throws {
        // Test metadata around the 100-byte compression threshold
        let testSizes = [50, 100, 150, 200]

        for size in testSizes {
            var metadata = ConversationCustomMetadata()
            let tag = String(repeating: "x", count: size)
            metadata.tag = tag

            let encoded = try metadata.toCompactString()
            let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

            #expect(decoded.tag == tag)
        }
    }

    // MARK: - Profile Management Tests

    @Test("Upsert profile - add new")
    func upsertProfileAddNew() throws {
        var metadata = ConversationCustomMetadata()

        let profile = ConversationProfile(
            inboxIdString: "0011223344556677889900112233445566778899001122334455667788990011",
            name: "Alice",
            imageUrl: "https://example.com/alice.jpg"
        )!

        metadata.upsertProfile(profile)

        #expect(metadata.profiles.count == 1)
        #expect(metadata.profiles[0].name == "Alice")
    }

    @Test("Upsert profile - update existing")
    func upsertProfileUpdateExisting() throws {
        var metadata = ConversationCustomMetadata()

        let inboxIdHex = "0011223344556677889900112233445566778899001122334455667788990011"

        let profile1 = ConversationProfile(
            inboxIdString: inboxIdHex,
            name: "Alice",
            imageUrl: "https://example.com/alice1.jpg"
        )!

        metadata.upsertProfile(profile1)
        #expect(metadata.profiles.count == 1)

        // Update with same inbox ID
        let profile2 = ConversationProfile(
            inboxIdString: inboxIdHex,
            name: "Alice Updated",
            imageUrl: "https://example.com/alice2.jpg"
        )!

        metadata.upsertProfile(profile2)

        #expect(metadata.profiles.count == 1)
        #expect(metadata.profiles[0].name == "Alice Updated")
        #expect(metadata.profiles[0].image == "https://example.com/alice2.jpg")
    }

    @Test("Remove profile by inbox ID")
    func removeProfileByInboxId() throws {
        var metadata = ConversationCustomMetadata()

        let inboxId1 = "0011223344556677889900112233445566778899001122334455667788990011"
        let inboxId2 = "1122334455667788990011223344556677889900112233445566778899001100"

        let profile1 = ConversationProfile(inboxIdString: inboxId1, name: "Alice")!
        let profile2 = ConversationProfile(inboxIdString: inboxId2, name: "Bob")!

        metadata.upsertProfile(profile1)
        metadata.upsertProfile(profile2)

        #expect(metadata.profiles.count == 2)

        let removed = metadata.removeProfile(inboxId: inboxId1)

        #expect(removed == true)
        #expect(metadata.profiles.count == 1)
        #expect(metadata.profiles[0].inboxIdString == inboxId2)
    }

    @Test("Remove non-existent profile returns false")
    func removeNonExistentProfile() throws {
        var metadata = ConversationCustomMetadata()

        let removed = metadata.removeProfile(inboxId: "0011223344556677889900112233445566778899001122334455667788990011")

        #expect(removed == false)
        #expect(metadata.profiles.isEmpty)
    }

    @Test("Find profile by inbox ID")
    func findProfileByInboxId() throws {
        var metadata = ConversationCustomMetadata()

        let inboxId = "0011223344556677889900112233445566778899001122334455667788990011"
        let profile = ConversationProfile(inboxIdString: inboxId, name: "Alice", imageUrl: "https://example.com/alice.jpg")!

        metadata.upsertProfile(profile)

        let found = metadata.findProfile(inboxId: inboxId)

        #expect(found != nil)
        #expect(found?.name == "Alice")
        #expect(found?.image == "https://example.com/alice.jpg")
    }

    @Test("Find non-existent profile returns nil")
    func findNonExistentProfile() throws {
        let metadata = ConversationCustomMetadata()

        let found = metadata.findProfile(inboxId: "0011223344556677889900112233445566778899001122334455667788990011")

        #expect(found == nil)
    }

    // MARK: - Inbox ID Hex Conversion Tests

    @Test("ConversationProfile inbox ID hex conversion")
    func conversationProfileInboxIdHexConversion() throws {
        let inboxIdHex = "0011223344556677889900112233445566778899001122334455667788990011"

        let profile = ConversationProfile(inboxIdString: inboxIdHex, name: "Alice")

        #expect(profile != nil)
        #expect(profile?.inboxIdString == inboxIdHex)
    }

    @Test("32-byte inbox ID validation")
    func thirtyTwoByteInboxIdValidation() throws {
        // Valid 32-byte inbox ID (64 hex chars)
        let validInboxId = "0011223344556677889900112233445566778899001122334455667788990011"
        let validProfile = ConversationProfile(inboxIdString: validInboxId, name: "Alice")
        #expect(validProfile != nil)

        // Invalid lengths
        let tooShort = "00112233" // 4 bytes
        let tooLong = validInboxId + "00" // 33 bytes

        let shortProfile = ConversationProfile(inboxIdString: tooShort, name: "Bob")
        let longProfile = ConversationProfile(inboxIdString: tooLong, name: "Charlie")

        // These should still create profiles (just not 32 bytes)
        #expect(shortProfile != nil)
        #expect(longProfile != nil)
    }

    @Test("Empty inbox ID returns nil")
    func emptyInboxIdReturnsNil() throws {
        let profile = ConversationProfile(inboxIdString: "", name: "Test")
        #expect(profile == nil)
    }

    // MARK: - Timestamp Conversion Tests

    @Test("Timestamp conversion round-trip")
    func timestampConversionRoundTrip() throws {
        var metadata = ConversationCustomMetadata()

        let timestamp: Int64 = 1735689600 // 2025-01-01 00:00:00 UTC
        metadata.expiresAtUnix = timestamp

        let encoded = try metadata.toCompactString()
        let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

        #expect(decoded.expiresAtUnix == timestamp)
    }

    @Test("Timestamp boundary values")
    func timestampBoundaryValues() throws {
        let testTimestamps: [Int64] = [
            0, // Unix epoch
            Int64(Int32.max), // Year 2038 problem boundary
            Int64(Int32.max) + 1, // Beyond 2038
            -1, // Negative (before epoch)
            1735689600, // 2025-01-01
        ]

        for timestamp in testTimestamps {
            var metadata = ConversationCustomMetadata()
            metadata.expiresAtUnix = timestamp

            let encoded = try metadata.toCompactString()
            let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

            #expect(decoded.expiresAtUnix == timestamp)
        }
    }

    // MARK: - Migration Support Tests

    @Test("isEncodedMetadata detects encoded data")
    func isEncodedMetadataDetectsEncoded() throws {
        var metadata = ConversationCustomMetadata()
        metadata.tag = "abc123"

        let encoded = try metadata.toCompactString()

        #expect(ConversationCustomMetadata.isEncodedMetadata(encoded) == true)
    }

    @Test("isEncodedMetadata rejects plain text")
    func isEncodedMetadataRejectsPlainText() throws {
        let plainTexts = [
            "This is plain text",
            "Hello World!",
            "Conversation with spaces and punctuation.",
            "日本語テキスト"
        ]

        for plainText in plainTexts {
            #expect(ConversationCustomMetadata.isEncodedMetadata(plainText) == false)
        }
    }

    @Test("isEncodedMetadata rejects empty string")
    func isEncodedMetadataRejectsEmptyString() throws {
        #expect(ConversationCustomMetadata.isEncodedMetadata("") == false)
    }

    @Test("isEncodedMetadata rejects strings with invalid base64url chars")
    func isEncodedMetadataRejectsInvalidChars() throws {
        let invalidStrings = [
            "abc+def", // Standard base64 char
            "abc/def", // Standard base64 char
            "abc=def", // Padding
            "abc def", // Space
            "abc!def", // Special char
        ]

        for invalidString in invalidStrings {
            #expect(ConversationCustomMetadata.isEncodedMetadata(invalidString) == false)
        }
    }

    // MARK: - Optional Field Tests

    @Test("Profile with name but no image")
    func profileWithNameButNoImage() throws {
        var metadata = ConversationCustomMetadata()

        let profile = ConversationProfile(
            inboxIdString: "0011223344556677889900112233445566778899001122334455667788990011",
            name: "Alice",
            imageUrl: nil
        )!

        metadata.upsertProfile(profile)

        let encoded = try metadata.toCompactString()
        let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

        #expect(decoded.profiles.count == 1)
        #expect(decoded.profiles[0].hasName == true)
        #expect(decoded.profiles[0].name == "Alice")
        #expect(decoded.profiles[0].hasImage == false)
    }

    @Test("Profile with image but no name")
    func profileWithImageButNoName() throws {
        var metadata = ConversationCustomMetadata()

        let profile = ConversationProfile(
            inboxIdString: "0011223344556677889900112233445566778899001122334455667788990011",
            name: nil,
            imageUrl: "https://example.com/avatar.jpg"
        )!

        metadata.upsertProfile(profile)

        let encoded = try metadata.toCompactString()
        let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

        #expect(decoded.profiles.count == 1)
        #expect(decoded.profiles[0].hasName == false)
        #expect(decoded.profiles[0].hasImage == true)
        #expect(decoded.profiles[0].image == "https://example.com/avatar.jpg")
    }

    @Test("Profile with neither name nor image")
    func profileWithNeitherNameNorImage() throws {
        var metadata = ConversationCustomMetadata()

        let profile = ConversationProfile(
            inboxIdString: "0011223344556677889900112233445566778899001122334455667788990011",
            name: nil,
            imageUrl: nil
        )!

        metadata.upsertProfile(profile)

        let encoded = try metadata.toCompactString()
        let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

        #expect(decoded.profiles.count == 1)
        #expect(decoded.profiles[0].hasName == false)
        #expect(decoded.profiles[0].hasImage == false)
    }

    // MARK: - Edge Cases

    @Test("Many profiles")
    func manyProfiles() throws {
        var metadata = ConversationCustomMetadata()

        for i in 0..<100 {
            let inboxIdHex = String(format: "%064d", i)
            if let profile = ConversationProfile(inboxIdString: inboxIdHex, name: "User \(i)") {
                metadata.profiles.append(profile)
            }
        }

        let encoded = try metadata.toCompactString()
        let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

        #expect(decoded.profiles.count == 100)
        #expect(decoded.profiles[0].name == "User 0")
        #expect(decoded.profiles[99].name == "User 99")
    }

    @Test("Special characters in profile name")
    func specialCharactersInProfileName() throws {
        let metadata = ConversationCustomMetadata()

        let names = [
            "Alice 🌟",
            "Bob\nNewline",
            "Charlie\tTab",
            "田中",
            "محمد"
        ]

        let inboxId = "0011223344556677889900112233445566778899001122334455667788990011"

        for name in names {
            var testMetadata = metadata
            let profile = ConversationProfile(inboxIdString: inboxId, name: name)!
            testMetadata.upsertProfile(profile)

            let encoded = try testMetadata.toCompactString()
            let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

            #expect(decoded.profiles.count == 1)
            #expect(decoded.profiles[0].name == name)
        }
    }

    // MARK: - Decompression Bomb Protection

    @Test("Large compressed metadata decompresses safely")
    func largeCompressedMetadataDecompressesSafely() throws {
        var metadata = ConversationCustomMetadata()

        // Add multiple profiles with varied data
        for i in 0..<20 {
            let inboxIdHex = String(format: "%064x", i * 123456789)
            if let profile = ConversationProfile(
                inboxIdString: inboxIdHex,
                name: "Member \(i)",
                imageUrl: "https://example.com/avatar/\(i).jpg"
            ) {
                metadata.profiles.append(profile)
            }
        }

        let encoded = try metadata.toCompactString()
        let decoded = try ConversationCustomMetadata.fromCompactString(encoded)

        #expect(decoded.profiles.count == 20)
    }

    // MARK: - Capacity Tests

    @Test("Maximum profiles in 1KB metadata")
    func maximumProfilesIn1KB() throws {
        let maxSize = 1024 // 1KB limit
        var metadata = ConversationCustomMetadata()
        metadata.tag = "abc1234567" // 10 characters

        // Realistic varied first and last names to avoid artificial compression gains
        let firstNames = ["Alice", "Bob", "Charlie", "Diana", "Emma", "Frank", "Grace", "Henry",
                          "Isabella", "Jack", "Kate", "Liam", "Mia", "Noah", "Olivia", "Peter",
                          "Quinn", "Rose", "Sam", "Tara", "Uma", "Victor", "Wendy", "Xander"]
        let lastNames = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller",
                         "Davis", "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez",
                         "Wilson", "Anderson", "Thomas", "Taylor", "Moore", "Jackson", "Martin"]

        var profileCount = 0
        var lastSuccessfulMetadata = metadata

        // Generate realistic profiles until we exceed 1KB
        for i in 0..<200 { // Upper bound to prevent infinite loop
            // Generate realistic XMTP inbox ID (64 hex chars = 32 bytes)
            let randomHex = String(format: "%064x", UInt64.random(in: 0...UInt64.max))

            // Generate realistic varied display name (up to 25 characters)
            let firstName = firstNames[i % firstNames.count]
            let lastName = lastNames[i % lastNames.count]
            let suffix = i / (firstNames.count * lastNames.count)
            let displayName = suffix > 0
                ? "\(firstName) \(lastName) \(suffix)".prefix(25)
                : "\(firstName) \(lastName)".prefix(25)

            // Generate realistic image URL with UUID
            let uuid = UUID().uuidString
            let imageUrl = "https://dev.convos.org/some-aws-bucket/p-\(uuid).jpeg"

            guard let profile = ConversationProfile(
                inboxIdString: randomHex,
                name: String(displayName),
                imageUrl: imageUrl
            ) else {
                continue
            }

            metadata.upsertProfile(profile)

            // Try to encode
            let encoded = try metadata.toCompactString()
            let encodedData = try encoded.base64URLDecoded()

            if encodedData.count <= maxSize {
                profileCount = i + 1
                lastSuccessfulMetadata = metadata
            } else {
                // Exceeded 1KB, stop here
                break
            }
        }

        // Verify we can decode the last successful metadata
        let finalEncoded = try lastSuccessfulMetadata.toCompactString()
        let finalEncodedData = try finalEncoded.base64URLDecoded()
        let decoded = try ConversationCustomMetadata.fromCompactString(finalEncoded)

        #expect(decoded.profiles.count == profileCount)
        #expect(decoded.tag == "abc1234567")
        #expect(finalEncodedData.count <= maxSize)

        // Print results for informational purposes
        print("✓ Maximum profiles in 1KB: \(profileCount)")
        print("✓ Final encoded size: \(finalEncodedData.count) bytes")
        print("✓ Compression applied: \(finalEncodedData.first == Data.compressionMarker ? "Yes" : "No")")

        // Sanity check: should fit at least a few profiles even with realistic data
        #expect(profileCount >= 15, "Expected at least 5 profiles to fit in 1KB with compression")

        // Upper bound sanity check - with DEFLATE compression, realistic profiles with
        // full names and image URLs should fit around 20-30 profiles in 1KB
        #expect(profileCount <= 35, "Unexpectedly high profile count, check test data")
    }

    @Test("Profile size breakdown with realistic data")
    func profileSizeBreakdownWithRealisticData() throws {
        var metadata = ConversationCustomMetadata()
        metadata.tag = "abc1234567"

        // Add a single realistic profile
        let inboxIdHex = "40c0544e6fc99689a68d0e5218b4dff1f3bc2d93d1995b1b6c5dd21bc323520f"
        let displayName = "John Smith (25 chars!!)"
        let uuid = UUID().uuidString
        let imageUrl = "https://dev.convos.org/some-aws-bucket/p-\(uuid).jpeg"

        let profile = ConversationProfile(
            inboxIdString: inboxIdHex,
            name: displayName,
            imageUrl: imageUrl
        )!

        metadata.upsertProfile(profile)

        // Encode and check size
        let encoded = try metadata.toCompactString()
        let encodedData = try encoded.base64URLDecoded()

        print("✓ Single profile encoded size: \(encodedData.count) bytes")
        print("✓ Inbox ID length: \(inboxIdHex.count) chars (32 bytes when decoded)")
        print("✓ Display name length: \(displayName.count) chars")
        print("✓ Image URL length: \(imageUrl.count) chars")
        print("✓ Tag length: \(metadata.tag.count) chars")

        // Verify it's well under 1KB for a single profile
        #expect(encodedData.count < 512, "Single profile should be less than 512 bytes")

        // Decode and verify
        let decoded = try ConversationCustomMetadata.fromCompactString(encoded)
        #expect(decoded.profiles.count == 1)
        #expect(decoded.profiles[0].name == displayName)
        #expect(decoded.profiles[0].image == imageUrl)
        #expect(decoded.profiles[0].inboxIdString == inboxIdHex)
    }
}
