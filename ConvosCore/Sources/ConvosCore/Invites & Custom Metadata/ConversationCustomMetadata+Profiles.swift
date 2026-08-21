import ConvosAppData
import Foundation

// MARK: - DBMemberProfile + ConversationProfile

extension DBMemberProfile {
    var conversationProfile: ConversationProfile? {
        guard let encryptedRef = encryptedImageRef else {
            return ConversationProfile(inboxIdString: inboxId, name: name, imageUrl: avatar)
        }
        return ConversationProfile(inboxIdString: inboxId, name: name, encryptedImageRef: encryptedRef)
    }
}

// MARK: - DBMemberProfile + Snapshot MemberProfile

extension DBMemberProfile {
    /// Projects this authoritative row into the `MemberProfile` used inside a
    /// `ProfileSnapshot` message. An encrypted slot rides the encrypted image
    /// ref; a plain (unencrypted) avatar rides the plain `image` URL. Returns
    /// nil when the inbox id is not valid hex and so cannot be put on the wire.
    var snapshotMemberProfile: MemberProfile? {
        let encryptedImage: EncryptedProfileImageRef? = encryptedImageRef.map(EncryptedProfileImageRef.init)
        let plainImage: String? = encryptedImage == nil && hasPlainAvatar ? avatar : nil
        guard var profile = MemberProfile(
            inboxIdString: inboxId,
            name: name,
            encryptedImage: encryptedImage,
            image: plainImage,
            metadata: metadata
        ) else {
            return nil
        }
        if let memberKind {
            profile.memberKind = memberKind.protoMemberKind
        }
        return profile
    }
}

// MARK: - Canonical Profile + Snapshot MemberProfile

extension DBProfile {
    /// Projects the canonical per-inbox identity plus a conversation's avatar
    /// slot into the `MemberProfile` used inside a `ProfileSnapshot` message.
    /// Mirrors `DBMemberProfile.snapshotMemberProfile`: an encrypted slot rides
    /// the encrypted image ref, a plain slot rides the plain `image` URL.
    /// Returns nil when the inbox id is not valid hex.
    func snapshotMemberProfile(avatar: DBProfileAvatar?) -> MemberProfile? {
        let encryptedImage: EncryptedProfileImageRef? = avatar?.snapshotEncryptedImageRef
        let plainImage: String? = encryptedImage == nil ? avatar?.snapshotPlainImageURL : nil
        guard var profile = MemberProfile(
            inboxIdString: inboxId,
            name: name,
            encryptedImage: encryptedImage,
            image: plainImage,
            metadata: metadata
        ) else {
            return nil
        }
        if let memberKind {
            profile.memberKind = memberKind.protoMemberKind
        }
        return profile
    }
}

extension DBMyProfile {
    /// Projects the locally-authored self identity plus a conversation's avatar
    /// slot into a snapshot `MemberProfile`. Self is excluded from `DBProfile`,
    /// so the snapshot builder folds this in to advertise the sender's own
    /// identity to joiners. Self is never an agent, so `memberKind` is omitted.
    /// Returns nil when the inbox id is not valid hex.
    func snapshotMemberProfile(avatar: DBProfileAvatar?) -> MemberProfile? {
        let encryptedImage: EncryptedProfileImageRef? = avatar?.snapshotEncryptedImageRef
        let plainImage: String? = encryptedImage == nil ? avatar?.snapshotPlainImageURL : nil
        return MemberProfile(
            inboxIdString: inboxId,
            name: name,
            encryptedImage: encryptedImage,
            image: plainImage,
            metadata: metadata
        )
    }
}

extension DBProfileAvatar {
    /// The wire-format encrypted image ref for a snapshot, or nil when the slot
    /// is a plain/absent avatar (an encrypted slot rides this; a plain one rides
    /// `snapshotPlainImageURL`).
    var snapshotEncryptedImageRef: EncryptedProfileImageRef? {
        guard hasValidEncryptedAvatar, let url, let salt, let nonce else { return nil }
        var ref = EncryptedProfileImageRef()
        ref.url = url
        ref.salt = salt
        ref.nonce = nonce
        return ref
    }

    /// The plain (cleartext) avatar URL for a snapshot, or nil when the slot is
    /// encrypted or absent. Peers now publish plain avatars; a plain slot has a
    /// URL and no crypto.
    var snapshotPlainImageURL: String? {
        guard !hasValidEncryptedAvatar, let url, !url.isEmpty else { return nil }
        return url
    }
}

// MARK: - MemberKind <-> DBMemberKind

extension MemberKind {
    var dbMemberKind: DBMemberKind? {
        switch self {
        case .agent: return .agent
        case .unspecified, .UNRECOGNIZED: return nil
        }
    }
}

extension DBMemberKind {
    var protoMemberKind: MemberKind {
        switch self {
        case .agent, .verifiedConvos, .verifiedUserOAuth: return .agent
        }
    }
}
