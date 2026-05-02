@testable import ConvosCore
import Foundation
import Testing

/// Pins the invariant that every `with(…)` helper on `DBMemberProfile` preserves
/// the per-conversation `metadata` field. `MyProfileWriter.syncFromGlobalProfile`
/// only ever rebuilds member rows through these helpers, so as long as each one
/// copies metadata forward, activate-sync cannot wipe per-conversation metadata
/// when the global profile is updated.
@Suite("DBMemberProfile.with(...) preserves metadata")
struct DBMemberProfileWithHelpersTests {
    private static let baseMetadata: ProfileMetadata = [
        "emoji": .string("🎯"),
        "credits": .number(42),
        "verified": .bool(true)
    ]

    private static func base() -> DBMemberProfile {
        DBMemberProfile(
            conversationId: "convo-1",
            inboxId: "inbox-1",
            name: "Alice",
            avatar: "https://example.com/old.enc",
            avatarSalt: Data(repeating: 0x01, count: 32),
            avatarNonce: Data(repeating: 0x02, count: 12),
            avatarKey: Data(repeating: 0x03, count: 32),
            avatarLastRenewed: Date(timeIntervalSince1970: 1_000),
            imageSourceAssetIdentifier: "asset-old",
            imageSourceContentDigest: "digest-old",
            memberKind: nil,
            metadata: baseMetadata
        )
    }

    @Test("with(name:) preserves metadata")
    func withNamePreservesMetadata() {
        let updated = Self.base().with(name: "Bob")
        #expect(updated.name == "Bob")
        #expect(updated.metadata == Self.baseMetadata)
    }

    @Test("with(name:) clearing the name still preserves metadata")
    func withNilNamePreservesMetadata() {
        let updated = Self.base().with(name: nil)
        #expect(updated.name == nil)
        #expect(updated.metadata == Self.baseMetadata)
    }

    @Test("with(avatar:salt:nonce:key:) preserves metadata for an upload")
    func withAvatarUploadPreservesMetadata() {
        let updated = Self.base().with(
            avatar: "https://example.com/new.enc",
            salt: Data(repeating: 0x10, count: 32),
            nonce: Data(repeating: 0x11, count: 12),
            key: Data(repeating: 0x12, count: 32)
        )
        #expect(updated.avatar == "https://example.com/new.enc")
        #expect(updated.metadata == Self.baseMetadata)
    }

    @Test("with(avatar:salt:nonce:key:) preserves metadata for a removal")
    func withAvatarRemovalPreservesMetadata() {
        let updated = Self.base().with(avatar: nil, salt: nil, nonce: nil, key: nil)
        #expect(updated.avatar == nil)
        #expect(updated.avatarSalt == nil)
        #expect(updated.avatarNonce == nil)
        #expect(updated.avatarKey == nil)
        #expect(updated.metadata == Self.baseMetadata)
    }

    @Test("with(imageSourceContentDigest:) preserves metadata")
    func withDigestPreservesMetadata() {
        let updated = Self.base().with(imageSourceContentDigest: "digest-new")
        #expect(updated.imageSourceContentDigest == "digest-new")
        #expect(updated.metadata == Self.baseMetadata)
    }

    @Test("with(imageSourceContentDigest: nil) preserves metadata")
    func withNilDigestPreservesMetadata() {
        let updated = Self.base().with(imageSourceContentDigest: nil)
        #expect(updated.imageSourceContentDigest == nil)
        #expect(updated.metadata == Self.baseMetadata)
    }

    @Test("activate-sync write chain preserves metadata end to end")
    func activateSyncChainPreservesMetadata() {
        // Mirrors `update(avatar:imageSourceContentDigest:)` for an upload.
        let updated = Self.base()
            .with(
                avatar: "https://example.com/new.enc",
                salt: Data(repeating: 0x10, count: 32),
                nonce: Data(repeating: 0x11, count: 12),
                key: Data(repeating: 0x12, count: 32)
            )
            .with(imageSourceContentDigest: "digest-new")
        #expect(updated.metadata == Self.baseMetadata)
        #expect(updated.imageSourceContentDigest == "digest-new")
    }

    @Test("with(avatar:) (single-arg) preserves metadata")
    func withAvatarSingleArgPreservesMetadata() {
        let updated = Self.base().with(avatar: "https://example.com/other.enc")
        #expect(updated.avatar == "https://example.com/other.enc")
        #expect(updated.metadata == Self.baseMetadata)
    }

    @Test("with(memberKind:) preserves metadata")
    func withMemberKindPreservesMetadata() {
        let updated = Self.base().with(memberKind: .agent)
        #expect(updated.metadata == Self.baseMetadata)
    }

    @Test("with(avatarLastRenewed:) preserves metadata")
    func withAvatarLastRenewedPreservesMetadata() {
        let updated = Self.base().with(avatarLastRenewed: Date(timeIntervalSince1970: 9_999))
        #expect(updated.metadata == Self.baseMetadata)
    }
}
