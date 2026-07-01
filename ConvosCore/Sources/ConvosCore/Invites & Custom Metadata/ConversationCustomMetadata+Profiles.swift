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
    /// `ProfileSnapshot` message. The wire format carries only encrypted image
    /// refs, so a plain (unencrypted) avatar URL is represented by name with
    /// the image omitted rather than fabricating an encrypted ref. Returns nil
    /// when the inbox id is not valid hex and so cannot be put on the wire.
    var snapshotMemberProfile: MemberProfile? {
        let encryptedImage: EncryptedProfileImageRef? = encryptedImageRef.map(EncryptedProfileImageRef.init)
        guard var profile = MemberProfile(
            inboxIdString: inboxId,
            name: name,
            encryptedImage: encryptedImage,
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
    /// Mirrors `DBMemberProfile.snapshotMemberProfile`: only encrypted image
    /// refs go on the wire, so a plain avatar is represented by name with the
    /// image omitted. Returns nil when the inbox id is not valid hex.
    func snapshotMemberProfile(avatar: DBProfileAvatar?) -> MemberProfile? {
        let encryptedImage: EncryptedProfileImageRef? = avatar?.snapshotEncryptedImageRef
        guard var profile = MemberProfile(
            inboxIdString: inboxId,
            name: name,
            encryptedImage: encryptedImage,
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

extension DBProfileAvatar {
    /// The wire-format encrypted image ref for a snapshot, or nil when the slot
    /// is a plain/absent avatar (only encrypted refs are put on the wire).
    var snapshotEncryptedImageRef: EncryptedProfileImageRef? {
        guard hasValidEncryptedAvatar, let url, let salt, let nonce else { return nil }
        var ref = EncryptedProfileImageRef()
        ref.url = url
        ref.salt = salt
        ref.nonce = nonce
        return ref
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
