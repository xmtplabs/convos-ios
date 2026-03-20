import ConvosAppData
import ConvosProfiles
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
