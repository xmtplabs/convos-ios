import ConvosAppData
import Foundation

/// Derived read accessors over a parsed appData blob, re-homed from the retired
/// `XMTPiOS.Group` extensions. Call sites obtain the metadata through
/// `AppDataCoordinator.currentAppData(conversationId:)` (fresh network blob
/// folded with pending local intent) and derive values here.
extension ConversationCustomMetadata {
    var expiresAtDate: Date? {
        guard hasExpiresAtUnix else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(expiresAtUnix))
    }

    var conversationEmoji: String? {
        guard hasEmoji, !emoji.isEmpty else { return nil }
        return emoji
    }

    /// Whether the blob carries the agent-DM marker. The agent's identity comes
    /// from the membership itself (member kind plus attestation), not from the
    /// marker; callers gating UI should also require exactly 2 members with an
    /// agent as the other member.
    var isAgentDm: Bool {
        hasAgentDm
    }

    /// The parent ("origin") conversation an agent DM was created from, as a
    /// hex conversation id, or nil when not recorded.
    var agentDmOriginConversationId: String? {
        guard hasAgentDm, agentDm.hasOriginConversationID else { return nil }
        let data = agentDm.originConversationID
        return data.isEmpty ? nil : data.toHexString()
    }

    /// The deployed Space web URL, or nil while none has been published. The
    /// Assistant Worker is the sole authority; clients never write this value.
    var publishedSpaceURL: String? {
        guard hasSpaceURL, !spaceURL.isEmpty else { return nil }
        return spaceURL
    }

    /// The group's legacy image-encryption key. Image encryption is removed on
    /// the write side; a legacy key still decrypts a peer's encrypted avatar or
    /// group image on the read path.
    var legacyImageEncryptionKey: Data? {
        guard hasImageEncryptionKey else { return nil }
        return imageEncryptionKey
    }

    /// A legacy encrypted group-image ref, kept for the read path: a group
    /// whose image predates the write-side encryption removal still decrypts.
    var legacyEncryptedGroupImage: EncryptedImageRef? {
        guard hasEncryptedGroupImage, encryptedGroupImage.isValid else { return nil }
        return encryptedGroupImage
    }

    /// The member profile rows carried in the blob, paired with the legacy
    /// group key so encrypted avatar refs remain decryptable.
    func memberProfiles(conversationId: String) -> [DBMemberProfile] {
        memberProfiles(conversationId: conversationId, withKey: legacyImageEncryptionKey)
    }

    func memberProfiles(conversationId: String, withKey groupKey: Data?) -> [DBMemberProfile] {
        profiles.map { (profile: ConversationProfile) -> DBMemberProfile in
            let avatarUrl: String?
            let salt: Data?
            let nonce: Data?
            let key: Data?

            if profile.hasEncryptedImage, profile.encryptedImage.isValid {
                avatarUrl = profile.encryptedImage.url
                salt = profile.encryptedImage.salt
                nonce = profile.encryptedImage.nonce
                key = groupKey
            } else {
                avatarUrl = profile.hasImage ? profile.image : nil
                salt = nil
                nonce = nil
                key = nil
            }

            return .init(
                conversationId: conversationId,
                inboxId: profile.inboxIdString,
                name: profile.hasName ? profile.name : nil,
                avatar: avatarUrl,
                avatarSalt: salt,
                avatarNonce: nonce,
                avatarKey: key
            )
        }
    }
}
