@testable import ConvosCore
import Foundation
import Testing

/// Pins the invariant that every `with(...)` helper on `DBMemberProfile`
/// preserves the per-conversation `metadata` field. Inbound merge paths rebuild
/// member rows through these helpers, so as long as each one copies metadata
/// forward, an identity update cannot wipe per-conversation metadata.
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

/// Pins the projection from an authoritative `DBMemberProfile` row to the
/// `MemberProfile` carried inside a `ProfileSnapshot`. This is the path that
/// lets a late joiner learn an agent (or any appData-sourced member) even when
/// no recent profile message exists for it.
@Suite("DBMemberProfile.snapshotMemberProfile projection")
struct DBMemberProfileSnapshotProjectionTests {
    private static let hexInboxId: String = String(repeating: "ab", count: 32)

    @Test("Agent row projects name and agent kind, with no image")
    func agentRowProjectsNameAndKind() throws {
        let row = DBMemberProfile(
            conversationId: "convo-1",
            inboxId: Self.hexInboxId,
            name: "My Agent",
            avatar: nil,
            memberKind: .agent,
            metadata: ["templateId": .string("t1")]
        )
        let projected = try #require(row.snapshotMemberProfile)
        #expect(projected.inboxIdString == Self.hexInboxId)
        #expect(projected.name == "My Agent")
        #expect(projected.memberKind == .agent)
        #expect(!projected.hasEncryptedImage)
        #expect(projected.metadata["templateId"]?.stringValue == "t1")
    }

    @Test("A valid encrypted avatar projects an encrypted image ref")
    func encryptedAvatarProjectsImage() throws {
        let row = DBMemberProfile(
            conversationId: "convo-1",
            inboxId: Self.hexInboxId,
            name: "Alice",
            avatar: "https://example.com/a.enc",
            avatarSalt: Data(repeating: 0x01, count: 32),
            avatarNonce: Data(repeating: 0x02, count: 12)
        )
        let projected = try #require(row.snapshotMemberProfile)
        #expect(projected.hasEncryptedImage)
        #expect(projected.encryptedImage.url == "https://example.com/a.enc")
        #expect(projected.encryptedImage.salt.count == 32)
        #expect(projected.encryptedImage.nonce.count == 12)
    }

    @Test("A plain avatar URL is dropped: name kept, no fabricated encrypted ref")
    func plainAvatarOmitsImage() throws {
        let row = DBMemberProfile(
            conversationId: "convo-1",
            inboxId: Self.hexInboxId,
            name: "Alice",
            avatar: "https://example.com/plain.png"
        )
        let projected = try #require(row.snapshotMemberProfile)
        #expect(projected.name == "Alice")
        #expect(!projected.hasEncryptedImage)
    }

    @Test("A non-hex inbox id cannot be put on the wire and projects nil")
    func nonHexInboxIdProjectsNil() {
        let row = DBMemberProfile(
            conversationId: "convo-1",
            inboxId: "not-hex",
            name: "Alice",
            avatar: nil
        )
        #expect(row.snapshotMemberProfile == nil)
    }
}

/// Pins the never-clear invariant shared by every inbound apply path (stream,
/// NSE push, catch-up/history): a name-less or blank `ProfileUpdate` must never
/// wipe a name we already have, which would render the member as "Somebody".
/// All three paths funnel through `DBMemberProfile.withInboundName`, so this is
/// the single place the invariant is tested.
@Suite("DBMemberProfile.withInboundName never clears an existing name")
struct DBMemberProfileInboundNameTests {
    private static func profile(name: String?) -> DBMemberProfile {
        DBMemberProfile(conversationId: "convo-1", inboxId: "inbox-1", name: name, avatar: nil)
    }

    @Test("a real incoming name wins")
    func realNameWins() {
        #expect(Self.profile(name: "Bob").withInboundName("Robert").name == "Robert")
    }

    @Test("a nil incoming name preserves the existing name")
    func nilPreservesExisting() {
        #expect(Self.profile(name: "Bob").withInboundName(nil).name == "Bob")
    }

    @Test("an empty incoming name preserves the existing name")
    func emptyPreservesExisting() {
        #expect(Self.profile(name: "Bob").withInboundName("").name == "Bob")
    }

    @Test("a whitespace-only incoming name preserves the existing name")
    func whitespacePreservesExisting() {
        #expect(Self.profile(name: "Bob").withInboundName("   ").name == "Bob")
    }

    @Test("a real name is set when none existed")
    func firstNameIsSet() {
        #expect(Self.profile(name: nil).withInboundName("Bob").name == "Bob")
    }

    @Test("a blank incoming name with no existing name stays nil")
    func blankWithNoExistingStaysNil() {
        #expect(Self.profile(name: nil).withInboundName(nil).name == nil)
        #expect(Self.profile(name: nil).withInboundName("").name == nil)
    }
}
