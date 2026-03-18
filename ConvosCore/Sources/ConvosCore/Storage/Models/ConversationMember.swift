import Foundation

// MARK: - ConversationMember

public struct ConversationMember: Codable, Hashable, Identifiable, Sendable {
    public var id: String { profile.id }
    public let profile: Profile
    public let role: MemberRole
    public let isCurrentUser: Bool
    public let isAgent: Bool
    public let isVerifiedAssistant: Bool
    public let invitedBy: Profile?
    public let joinedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case profile, role, isCurrentUser, isAgent, isVerifiedAssistant, invitedBy, joinedAt
    }

    public init(
        profile: Profile,
        role: MemberRole,
        isCurrentUser: Bool,
        isAgent: Bool = false,
        isVerifiedAssistant: Bool = false,
        invitedBy: Profile? = nil,
        joinedAt: Date? = nil
    ) {
        self.profile = profile
        self.role = role
        self.isCurrentUser = isCurrentUser
        self.isAgent = isAgent
        self.isVerifiedAssistant = isVerifiedAssistant
        self.invitedBy = invitedBy
        self.joinedAt = joinedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.profile = try container.decode(Profile.self, forKey: .profile)
        self.role = try container.decode(MemberRole.self, forKey: .role)
        self.isCurrentUser = try container.decode(Bool.self, forKey: .isCurrentUser)
        self.isAgent = try container.decodeIfPresent(Bool.self, forKey: .isAgent) ?? false
        self.isVerifiedAssistant = try container.decodeIfPresent(Bool.self, forKey: .isVerifiedAssistant) ?? false
        self.invitedBy = try container.decodeIfPresent(Profile.self, forKey: .invitedBy)
        self.joinedAt = try container.decodeIfPresent(Date.self, forKey: .joinedAt)
    }

    public var displayName: String {
        if let name = profile.name, !name.isEmpty {
            return name
        }
        if isAgent && !isVerifiedAssistant {
            return "Agent"
        }
        return profile.displayName
    }
}

public extension Array where Element == ConversationMember {
    var formattedNamesString: String {
        map { $0.profile }.formattedNamesString
    }

    func sortedByRole() -> [ConversationMember] {
        sorted { member1, member2 in
            if member1.isCurrentUser { return true }
            if member2.isCurrentUser { return false }

            let priority1 = member1.role.priority
            let priority2 = member2.role.priority

            if priority1 != priority2 {
                return priority1 < priority2
            }

            return member1.profile.displayName < member2.profile.displayName
        }
    }
}
