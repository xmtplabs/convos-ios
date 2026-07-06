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
