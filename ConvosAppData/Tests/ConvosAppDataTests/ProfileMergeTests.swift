@testable import ConvosAppData
import Foundation
import Testing

/// Coverage for `ConversationProfile.merged(over:)` and
/// `ConversationCustomMetadata.mergeProfile(_:)` - the merge-don't-clobber
/// semantics that stop a device with incomplete local state from downgrading
/// a member's richer profile entry in group metadata. Regression coverage for
/// the 2026-06-04 incident where a profile rewrite from a freshly-launched
/// paired device dropped the user's avatar fields (metadata shrank
/// 1478 -> 1376 bytes) and the degraded profile got the user removed from the
/// group.
@Suite("ConversationProfile merge Tests")
struct ProfileMergeTests {
    private static let inboxIdHex: String = "436afb6134c259f150e8b38a35e5d4ea"

    private static func validImageRef(url: String = "https://assets.example/avatar.bin") -> EncryptedImageRef {
        var ref = EncryptedImageRef()
        ref.url = url
        ref.salt = Data(repeating: 0xAB, count: 32)
        ref.nonce = Data(repeating: 0xCD, count: 12)
        return ref
    }

    private static func richProfile(name: String = "Jarod") -> ConversationProfile {
        var profile = ConversationProfile(
            inboxIdString: inboxIdHex,
            name: name,
            encryptedImageRef: validImageRef()
        ) ?? ConversationProfile()
        profile.connections = #"{"services":["calendar"]}"#
        return profile
    }

    private static func nameOnlyProfile(name: String = "Jarod") -> ConversationProfile {
        ConversationProfile(inboxIdString: inboxIdHex, name: name) ?? ConversationProfile()
    }

    // MARK: - merged(over:)

    @Test("Avatar-less incoming profile preserves the existing encrypted image")
    func preservesEncryptedImage() {
        let merged = Self.nameOnlyProfile().merged(over: Self.richProfile())

        #expect(merged.hasEncryptedImage)
        #expect(merged.encryptedImage == Self.validImageRef())
    }

    @Test("Avatar-less incoming profile preserves an existing legacy image")
    func preservesLegacyImage() {
        var existing = Self.nameOnlyProfile()
        existing.image = "https://assets.example/legacy.png"

        let merged = Self.nameOnlyProfile().merged(over: existing)

        #expect(merged.hasImage)
        #expect(merged.image == "https://assets.example/legacy.png")
    }

    @Test("Connections are always preserved when the incoming side has none")
    func preservesConnections() {
        let merged = Self.nameOnlyProfile().merged(over: Self.richProfile())

        #expect(merged.hasConnections)
        #expect(merged.connections == #"{"services":["calendar"]}"#)
    }

    @Test("A name change applies while the avatar is preserved")
    func nameChangePreservesAvatar() {
        let merged = Self.nameOnlyProfile(name: "Jarod L").merged(over: Self.richProfile(name: "Jarod"))

        #expect(merged.name == "Jarod L")
        #expect(merged.effectiveImageUrl == Self.validImageRef().url)
    }

    @Test("An incoming valid encrypted image replaces the existing one")
    func richerIncomingImageWins() {
        let newRef = Self.validImageRef(url: "https://assets.example/new-avatar.bin")
        let incoming = ConversationProfile(
            inboxIdString: Self.inboxIdHex,
            name: "Jarod",
            encryptedImageRef: newRef
        ) ?? ConversationProfile()

        let merged = incoming.merged(over: Self.richProfile())

        #expect(merged.encryptedImage == newRef)
        // A new encrypted avatar must not resurrect a stale legacy image url.
        #expect(!merged.hasImage)
    }

    @Test("An incoming legacy image wins over an existing encrypted image")
    func incomingLegacyImageWins() {
        var incoming = Self.nameOnlyProfile()
        incoming.image = "https://assets.example/fresh-legacy.png"

        let merged = incoming.merged(over: Self.richProfile())

        #expect(merged.effectiveImageUrl == "https://assets.example/fresh-legacy.png")
        #expect(!merged.hasEncryptedImage)
    }

    // MARK: - mergeProfile(_:)

    @Test("mergeProfile appends when no existing entry matches")
    func mergeProfileAppendsNewInbox() {
        var metadata = ConversationCustomMetadata()
        metadata.mergeProfile(Self.nameOnlyProfile())

        #expect(metadata.profiles.count == 1)
        #expect(metadata.findProfile(inboxId: Self.inboxIdHex)?.name == "Jarod")
    }

    @Test("mergeProfile merges into the existing entry by inbox id")
    func mergeProfileMergesExisting() {
        var metadata = ConversationCustomMetadata()
        metadata.upsertProfile(Self.richProfile())

        metadata.mergeProfile(Self.nameOnlyProfile(name: "Jarod L"))

        #expect(metadata.profiles.count == 1)
        let final = metadata.findProfile(inboxId: Self.inboxIdHex)
        #expect(final?.name == "Jarod L")
        #expect(final?.effectiveImageUrl == Self.validImageRef().url)
        #expect(final?.hasConnections == true)
    }

    @Test("Merging an avatar-less profile never shrinks the encoded metadata")
    func mergeNeverShrinksEncodedMetadata() throws {
        var metadata = ConversationCustomMetadata()
        metadata.tag = "dL6ICreUdZ"
        metadata.upsertProfile(Self.richProfile())
        let beforeCount = try metadata.toCompactString().utf8.count

        metadata.mergeProfile(Self.nameOnlyProfile())
        let afterCount = try metadata.toCompactString().utf8.count

        #expect(afterCount >= beforeCount)
    }
}
