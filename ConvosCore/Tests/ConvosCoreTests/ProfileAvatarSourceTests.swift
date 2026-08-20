@testable import ConvosCore
import Foundation
import Testing

/// Which avatar a rendered profile shows, now that identity comes from the
/// backend but the legacy per-conversation slot is still on disk.
struct ProfileAvatarSourceTests {
    private func canonicalRow(avatarUrl: String?) -> DBProfile {
        DBProfile(
            inboxId: "alice",
            name: "Alice",
            profileSource: .profileUpdate,
            avatarUrl: avatarUrl,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private func legacySlot() -> DBProfileAvatar {
        DBProfileAvatar(
            inboxId: "alice",
            conversationId: "c1",
            url: "https://legacy.example/encrypted",
            salt: Data(repeating: 1, count: 32),
            nonce: Data(repeating: 2, count: 12),
            encryptionKey: Data(repeating: 3, count: 32),
            profileSource: .profileUpdate,
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    @Test("the backend URL wins, and brings no decryption with it")
    func prefersRemoteAvatar() {
        let profile = Profile.from(
            profile: canonicalRow(avatarUrl: "https://cdn.example/profiles/a.jpg"),
            avatar: legacySlot(),
            inboxId: "alice",
            conversationId: "c1"
        )
        #expect(profile.avatar == "https://cdn.example/profiles/a.jpg")
        #expect(profile.isAvatarEncrypted == false)
        #expect(profile.avatarKey == nil)
        #expect(profile.avatarSalt == nil)
        #expect(profile.avatarNonce == nil)
    }

    /// Someone who has not upgraded has no backend row yet. Dropping straight to
    /// a monogram would blank faces that are already on screen, so the encrypted
    /// slot keeps rendering until the remote fetch fills in.
    @Test("falls back to the legacy encrypted slot until the inbox resolves")
    func fallsBackToLegacyAvatar() {
        let profile = Profile.from(
            profile: canonicalRow(avatarUrl: nil),
            avatar: legacySlot(),
            inboxId: "alice",
            conversationId: "c1"
        )
        #expect(profile.avatar == "https://legacy.example/encrypted")
        #expect(profile.isAvatarEncrypted)
    }

    @Test("no avatar anywhere leaves the monogram to render")
    func noAvatarAtAll() {
        let profile = Profile.from(
            profile: canonicalRow(avatarUrl: nil),
            avatar: nil,
            inboxId: "alice",
            conversationId: "c1"
        )
        #expect(profile.avatar == nil)
        #expect(profile.isAvatarEncrypted == false)
        #expect(profile.displayName == "Alice")
    }
}
