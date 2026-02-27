@testable import ConvosAppData
import Foundation
import Testing

@Suite("Compression Edge Cases")
struct CompressionEdgeCaseTests {
    @Test("Data below compression threshold stays uncompressed")
    func belowThresholdUncompressed() throws {
        var metadata = ConversationCustomMetadata()
        metadata.tag = "tiny"

        let encoded = try metadata.toCompactString()
        let data = try encoded.base64URLDecoded()

        #expect(data.first != Data.compressionMarker)
    }

    @Test("Decompression rejects data exceeding max size")
    func decompressRejectsOversized() {
        var fakeCompressed = Data()
        let marker = Data.compressionMarker
        fakeCompressed.append(marker)
        let hugeSize: UInt32 = 20 * 1024 * 1024
        fakeCompressed.append(contentsOf: [
            UInt8((hugeSize >> 24) & 0xFF),
            UInt8((hugeSize >> 16) & 0xFF),
            UInt8((hugeSize >> 8) & 0xFF),
            UInt8(hugeSize & 0xFF),
        ])
        fakeCompressed.append(Data(repeating: 0x00, count: 10))

        let result = fakeCompressed.dropFirst().decompressedWithSize(maxSize: 10 * 1024 * 1024)
        #expect(result == nil)
    }

    @Test("Decompression rejects suspicious compression ratio")
    func decompressRejectsSuspiciousRatio() {
        var data = Data()
        let claimedSize: UInt32 = 1_000_000
        data.append(contentsOf: [
            UInt8((claimedSize >> 24) & 0xFF),
            UInt8((claimedSize >> 16) & 0xFF),
            UInt8((claimedSize >> 8) & 0xFF),
            UInt8(claimedSize & 0xFF),
        ])
        data.append(Data([0x01]))

        let result = data.decompressedWithSize(maxSize: 10 * 1024 * 1024)
        #expect(result == nil)
    }

    @Test("Compressed data round-trips correctly")
    func compressedDataRoundTrip() throws {
        let largeData = Data(repeating: 0x42, count: 500)

        guard let compressed = largeData.compressedIfSmaller() else {
            return
        }

        let decompressed = compressed.dropFirst().decompressedWithSize(maxSize: 10 * 1024 * 1024)
        #expect(decompressed == largeData)
    }
}

@Suite("AppData Limit Tests")
struct AppDataLimitTests {
    @Test("appDataByteLimit is 8KB")
    func limitIs8KB() {
        #expect(ConversationCustomMetadata.appDataByteLimit == 8 * 1024)
    }

    @Test("Large metadata can approach 8KB limit")
    func largeMetadataSize() throws {
        var metadata = ConversationCustomMetadata()
        metadata.tag = String(repeating: "x", count: 100)

        for i in 0..<50 {
            let inboxId = String(format: "%064x", i)
            if let profile = ConversationProfile(
                inboxIdString: inboxId,
                name: "User with a reasonably long name \(i)",
                imageUrl: "https://example.com/avatars/user-\(i)-profile-image.jpg"
            ) {
                metadata.profiles.append(profile)
            }
        }

        let encoded = try metadata.toCompactString()
        let size = encoded.utf8.count
        #expect(size > 0)
        #expect(size <= ConversationCustomMetadata.appDataByteLimit)
    }
}

@Suite("AppDataError Tests")
struct AppDataErrorTests {
    @Test("Error descriptions are not empty")
    func errorDescriptions() {
        let errors: [AppDataError] = [
            .decompressionFailed,
            .invalidBase64,
            .appDataLimitExceeded(currentSize: 9000, limit: 8192),
        ]

        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test("appDataLimitExceeded includes sizes in description")
    func limitExceededDescription() {
        let error = AppDataError.appDataLimitExceeded(currentSize: 9000, limit: 8192)
        let desc = error.errorDescription ?? ""
        #expect(desc.contains("9000"))
        #expect(desc.contains("8192"))
    }
}

@Suite("Profile Array Helper Tests")
struct ProfileArrayHelperTests {
    private let inboxId1: String = "0011223344556677889900112233445566778899001122334455667788990011"
    private let inboxId2: String = "1122334455667788990011223344556677889900112233445566778899001100"

    @Test("Array upsert adds new profile")
    func arrayUpsertAddsNew() {
        var profiles: [ConversationProfile] = []
        // swiftlint:disable:next force_unwrapping
        let profile = ConversationProfile(inboxIdString: inboxId1, name: "Alice")!
        profiles.upsert(profile)

        #expect(profiles.count == 1)
        #expect(profiles[0].name == "Alice")
    }

    @Test("Array upsert updates existing")
    func arrayUpsertUpdates() {
        var profiles: [ConversationProfile] = []
        // swiftlint:disable:next force_unwrapping
        profiles.upsert(ConversationProfile(inboxIdString: inboxId1, name: "Alice")!)
        // swiftlint:disable:next force_unwrapping
        profiles.upsert(ConversationProfile(inboxIdString: inboxId1, name: "Alice V2")!)

        #expect(profiles.count == 1)
        #expect(profiles[0].name == "Alice V2")
    }

    @Test("Array find returns correct profile")
    func arrayFind() {
        var profiles: [ConversationProfile] = []
        // swiftlint:disable:next force_unwrapping
        profiles.append(ConversationProfile(inboxIdString: inboxId1, name: "Alice")!)
        // swiftlint:disable:next force_unwrapping
        profiles.append(ConversationProfile(inboxIdString: inboxId2, name: "Bob")!)

        #expect(profiles.find(inboxId: inboxId2)?.name == "Bob")
        #expect(profiles.find(inboxId: "nonexistent") == nil)
    }

    @Test("Array remove returns true when found")
    func arrayRemove() {
        var profiles: [ConversationProfile] = []
        // swiftlint:disable:next force_unwrapping
        profiles.append(ConversationProfile(inboxIdString: inboxId1, name: "Alice")!)

        #expect(profiles.remove(inboxId: inboxId1) == true)
        #expect(profiles.isEmpty)
        #expect(profiles.remove(inboxId: inboxId1) == false)
    }
}

@Suite("Hex Edge Cases")
struct HexEdgeCaseTests {
    @Test("Empty hex string returns empty Data")
    func emptyHexString() {
        #expect(Data(hexString: "") == Data())
    }

    @Test("Just 0x prefix returns empty Data")
    func just0xPrefix() {
        #expect(Data(hexString: "0x") == Data())
    }

    @Test("toHexString on empty data returns empty string")
    func emptyDataToHex() {
        #expect(Data().toHexString().isEmpty)
    }

    @Test("Case insensitive hex parsing")
    func caseInsensitive() {
        let lower = Data(hexString: "aabbcc")
        let upper = Data(hexString: "AABBCC")
        #expect(lower == upper)
    }
}

@Suite("EncryptedImageRef Edge Cases")
struct EncryptedImageRefEdgeCaseTests {
    @Test("Invalid with wrong nonce size")
    func invalidWrongNonceSize() {
        var ref = EncryptedImageRef()
        ref.url = "https://example.com/image.bin"
        ref.salt = Data(repeating: 0xAB, count: 32)
        ref.nonce = Data(repeating: 0xCD, count: 16)

        #expect(ref.isValid == false)
    }

    @Test("Invalid with empty salt and nonce")
    func invalidEmptyComponents() {
        var ref = EncryptedImageRef()
        ref.url = "https://example.com/image.bin"

        #expect(ref.isValid == false)
    }

    @Test("Default EncryptedImageRef is invalid")
    func defaultIsInvalid() {
        let ref = EncryptedImageRef()
        #expect(ref.isValid == false)
    }
}
