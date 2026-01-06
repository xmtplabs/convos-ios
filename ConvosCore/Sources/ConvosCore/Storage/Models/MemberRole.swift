import Foundation

// MARK: - MemberRole

public enum MemberRole: String, Codable, Hashable, CaseIterable, Sendable {
    case member, admin, superAdmin = "super_admin"

    public var displayName: String {
        switch self {
        case .member:
            return ""
        case .admin:
            return "Admin"
        case .superAdmin:
            return "Super Admin"
        }
    }

    public var priority: Int {
        switch self {
        case .superAdmin: return 1
        case .admin: return 2
        case .member: return 3
        }
    }
}
