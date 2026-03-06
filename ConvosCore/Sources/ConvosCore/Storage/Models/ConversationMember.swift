import Foundation

// MARK: - ConversationMember

public struct ConversationMember: Codable, Hashable, Identifiable, Sendable {
    public var id: String { profile.id }
    public let profile: Profile
    public let role: MemberRole
    public let isCurrentUser: Bool
    public let isAgent: Bool

    public init(profile: Profile, role: MemberRole, isCurrentUser: Bool, isAgent: Bool = false) {
        self.profile = profile
        self.role = role
        self.isCurrentUser = isCurrentUser
        self.isAgent = isAgent
    }
}

public extension Array where Element == ConversationMember {
    var formattedNamesString: String {
        map { $0.profile }.formattedNamesString
    }

    func sortedByRole() -> [ConversationMember] {
        sorted { member1, member2 in
            // Show current user first
            if member1.isCurrentUser { return true }
            if member2.isCurrentUser { return false }

            // Sort by role hierarchy: superAdmin > admin > member
            let priority1 = member1.role.priority
            let priority2 = member2.role.priority

            if priority1 != priority2 {
                return priority1 < priority2
            }

            // Same role, sort alphabetically by name
            return member1.profile.displayName < member2.profile.displayName
        }
    }
}
