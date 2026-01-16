import Combine
import Foundation
import GRDB
@preconcurrency import XMTPiOS

// MARK: - Conversation Permissions Repository Protocol

public protocol ConversationPermissionsRepositoryProtocol {
    func getConversationPermissions(for conversationId: String) async throws -> ConversationPermissionPolicySet
    func getMemberRole(memberInboxId: String, in conversationId: String) async throws -> MemberRole
    func canPerformAction(memberInboxId: String, action: ConversationPermissionAction, in conversationId: String) async throws -> Bool
    func getConversationMembers(for conversationId: String) async throws -> [ConversationMemberInfo]
    func addAdmin(memberInboxId: String, to conversationId: String) async throws
    func removeAdmin(memberInboxId: String, from conversationId: String) async throws
    func addSuperAdmin(memberInboxId: String, to conversationId: String) async throws
    func removeSuperAdmin(memberInboxId: String, from conversationId: String) async throws
    func addMembers(inboxIds: [String], to conversationId: String) async throws
    func removeMembers(inboxIds: [String], from conversationId: String) async throws
}

// MARK: - Conversation Permission Types

public enum ConversationPermissionAction: String, CaseIterable, Sendable {
    case addMember = "add_member_policy"
    case removeMember = "remove_member_policy"
    case addAdmin = "add_admin_policy"
    case removeAdmin = "remove_admin_policy"
    case updateConversationName = "update_group_name_policy"
    case updateConversationDescription = "update_group_description_policy"
    case updateConversationImage = "update_group_image_url_policy"
    case updateMessageDisappearing = "update_group_pinned_frame_url_policy"
}

public enum ConversationPermissionLevel: String, Sendable {
    case allow
    case deny
    case admin
    case superAdmin = "super_admin"
    case unknown
}

public struct ConversationPermissionPolicySet: Sendable {
    let addMemberPolicy: ConversationPermissionLevel
    let removeMemberPolicy: ConversationPermissionLevel
    let addAdminPolicy: ConversationPermissionLevel
    let removeAdminPolicy: ConversationPermissionLevel
    let updateConversationNamePolicy: ConversationPermissionLevel
    let updateConversationDescriptionPolicy: ConversationPermissionLevel
    let updateConversationImagePolicy: ConversationPermissionLevel
    let updateMessageDisappearingPolicy: ConversationPermissionLevel

    static let defaultPolicy: ConversationPermissionPolicySet = ConversationPermissionPolicySet(
        addMemberPolicy: .admin,
        removeMemberPolicy: .admin,
        addAdminPolicy: .superAdmin,
        removeAdminPolicy: .superAdmin,
        updateConversationNamePolicy: .admin,
        updateConversationDescriptionPolicy: .admin,
        updateConversationImagePolicy: .admin,
        updateMessageDisappearingPolicy: .admin
    )

    static let restrictivePolicy: ConversationPermissionPolicySet = ConversationPermissionPolicySet(
        addMemberPolicy: .superAdmin,
        removeMemberPolicy: .superAdmin,
        addAdminPolicy: .superAdmin,
        removeAdminPolicy: .superAdmin,
        updateConversationNamePolicy: .superAdmin,
        updateConversationDescriptionPolicy: .superAdmin,
        updateConversationImagePolicy: .superAdmin,
        updateMessageDisappearingPolicy: .superAdmin
    )

    static let superAdminPolicy: ConversationPermissionPolicySet = ConversationPermissionPolicySet(
        addMemberPolicy: .admin,
        removeMemberPolicy: .admin,
        addAdminPolicy: .superAdmin,
        removeAdminPolicy: .superAdmin,
        updateConversationNamePolicy: .admin,
        updateConversationDescriptionPolicy: .admin,
        updateConversationImagePolicy: .admin,
        updateMessageDisappearingPolicy: .admin
    )

    static let adminPolicy: ConversationPermissionPolicySet = ConversationPermissionPolicySet(
        addMemberPolicy: .admin,
        removeMemberPolicy: .admin,
        addAdminPolicy: .superAdmin,
        removeAdminPolicy: .deny,
        updateConversationNamePolicy: .admin,
        updateConversationDescriptionPolicy: .admin,
        updateConversationImagePolicy: .admin,
        updateMessageDisappearingPolicy: .admin
    )

    static let memberPolicy: ConversationPermissionPolicySet = ConversationPermissionPolicySet(
        addMemberPolicy: .admin,
        removeMemberPolicy: .admin,
        addAdminPolicy: .deny,
        removeAdminPolicy: .deny,
        updateConversationNamePolicy: .admin,
        updateConversationDescriptionPolicy: .admin,
        updateConversationImagePolicy: .admin,
        updateMessageDisappearingPolicy: .admin
    )
}

public struct ConversationMemberInfo: Sendable {
    let inboxId: String
    let role: MemberRole
    let consent: Consent
    let addedAt: Date
}

// MARK: - Conversation Permissions Repository Implementation

final class ConversationPermissionsRepository: ConversationPermissionsRepositoryProtocol {
    private let inboxStateManager: any InboxStateManagerProtocol
    private let databaseReader: any DatabaseReader

    init(inboxStateManager: any InboxStateManagerProtocol,
         databaseReader: any DatabaseReader) {
        self.inboxStateManager = inboxStateManager
        self.databaseReader = databaseReader
    }

    // MARK: - Public Methods

    func getConversationPermissions(for conversationId: String) async throws -> ConversationPermissionPolicySet {
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client
        guard let conversation = try await client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationPermissionsError.conversationNotFound(conversationId: conversationId)
        }

        let isCurrentUserAdmin = try group.isAdmin(inboxId: client.inboxId)
        let isCurrentUserSuperAdmin = try group.isSuperAdmin(inboxId: client.inboxId)

        // Get all conversation members to analyze the permission structure
        let members = try await conversation.members()
        let hasMultipleAdmins = members.filter { member in
            (try? group.isAdmin(inboxId: member.inboxId)) == true ||
            (try? group.isSuperAdmin(inboxId: member.inboxId)) == true
        }.count > 1

        // Determine permission policy based on conversation structure and user role
        if isCurrentUserSuperAdmin {
            // Super admins get full control but still follow hierarchical model
            return ConversationPermissionPolicySet.superAdminPolicy
        } else if isCurrentUserAdmin {
            // Regular admins get standard admin permissions
            return ConversationPermissionPolicySet.adminPolicy
        } else if hasMultipleAdmins {
            // Conversation with multiple admins - more restrictive for members
            return ConversationPermissionPolicySet.memberPolicy
        } else {
            // Single admin conversation or member-only view - use default
            return ConversationPermissionPolicySet.defaultPolicy
        }
    }

    func getMemberRole(memberInboxId: String, in conversationId: String) async throws -> MemberRole {
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client

        guard let conversation = try await client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationPermissionsError.conversationNotFound(conversationId: conversationId)
        }

        // Use XMTP SDK methods to check member roles
        if try group.isSuperAdmin(inboxId: memberInboxId) {
            return .superAdmin
        } else if try group.isAdmin(inboxId: memberInboxId) {
            return .admin
        } else {
            // Check if member exists in the conversation
            let members = try await conversation.members()
            let memberExists = members.contains { $0.inboxId == memberInboxId }
            if memberExists {
                return .member
            } else {
                throw ConversationPermissionsError.memberNotFound(memberInboxId: memberInboxId)
            }
        }
    }

    func canPerformAction(
        memberInboxId: String,
        action: ConversationPermissionAction,
        in conversationId: String
    ) async throws -> Bool {
        // Get member role
        let memberRole = try await getMemberRole(memberInboxId: memberInboxId, in: conversationId)

        // Get conversation permissions
        let permissions = try await getConversationPermissions(for: conversationId)

        // Determine the required permission level for this action
        let requiredPermission: ConversationPermissionLevel
        switch action {
        case .addMember:
            requiredPermission = permissions.addMemberPolicy
        case .removeMember:
            requiredPermission = permissions.removeMemberPolicy
        case .addAdmin:
            requiredPermission = permissions.addAdminPolicy
        case .removeAdmin:
            requiredPermission = permissions.removeAdminPolicy
        case .updateConversationName:
            requiredPermission = permissions.updateConversationNamePolicy
        case .updateConversationDescription:
            requiredPermission = permissions.updateConversationDescriptionPolicy
        case .updateConversationImage:
            requiredPermission = permissions.updateConversationImagePolicy
        case .updateMessageDisappearing:
            requiredPermission = permissions.updateMessageDisappearingPolicy
        }

        // Check if member meets the required permission level
        return checkPermission(memberRole: memberRole, requiredLevel: requiredPermission)
    }

    func getConversationMembers(for conversationId: String) async throws -> [ConversationMemberInfo] {
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client

        guard let conversation = try await client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationPermissionsError.conversationNotFound(conversationId: conversationId)
        }

        // Get members from XMTP - members is a property, not a function
        let members = try await conversation.members()

        // Convert to our format
        var conversationMemberInfos: [ConversationMemberInfo] = []

        for member in members {
            // Determine role using XMTP SDK methods
            let memberRole: MemberRole
            if try group.isSuperAdmin(inboxId: member.inboxId) {
                memberRole = .superAdmin
            } else if try group.isAdmin(inboxId: member.inboxId) {
                memberRole = .admin
            } else {
                memberRole = .member
            }

            // Convert XMTP ConsentState to app's Consent type
            let consent: Consent
            switch member.consentState {
            case .allowed:
                consent = .allowed
            case .denied:
                consent = .denied
            case .unknown:
                consent = .unknown
            }

            let conversationMemberInfo = ConversationMemberInfo(
                inboxId: member.inboxId,
                role: memberRole,
                consent: consent,
                addedAt: Date() // XMTP doesn't provide exact add date, use current
            )

            conversationMemberInfos.append(conversationMemberInfo)
        }

        return conversationMemberInfos
    }

    func addAdmin(memberInboxId: String, to conversationId: String) async throws {
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client

        guard let conversation = try await client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationPermissionsError.conversationNotFound(conversationId: conversationId)
        }

        try await group.addAdmin(inboxId: memberInboxId)
    }

    func removeAdmin(memberInboxId: String, from conversationId: String) async throws {
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client

        guard let conversation = try await client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationPermissionsError.conversationNotFound(conversationId: conversationId)
        }

        try await group.removeAdmin(inboxId: memberInboxId)
    }

    func addSuperAdmin(memberInboxId: String, to conversationId: String) async throws {
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client

        guard let conversation = try await client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationPermissionsError.conversationNotFound(conversationId: conversationId)
        }

        try await group.addSuperAdmin(inboxId: memberInboxId)
    }

    func removeSuperAdmin(memberInboxId: String, from conversationId: String) async throws {
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client

        guard let conversation = try await client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationPermissionsError.conversationNotFound(conversationId: conversationId)
        }

        try await group.removeSuperAdmin(inboxId: memberInboxId)
    }

    func addMembers(inboxIds: [String], to conversationId: String) async throws {
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client

        guard let conversation = try await client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationPermissionsError.conversationNotFound(conversationId: conversationId)
        }

        _ = try await group.addMembers(inboxIds: inboxIds)
    }

    func removeMembers(inboxIds: [String], from conversationId: String) async throws {
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client

        guard let conversation = try await client.conversation(with: conversationId),
              case .group(let group) = conversation else {
            throw ConversationPermissionsError.conversationNotFound(conversationId: conversationId)
        }

        try await group.removeMembers(inboxIds: inboxIds)
    }

    // MARK: - Private Helper Methods

    private func checkPermission(memberRole: MemberRole, requiredLevel: ConversationPermissionLevel) -> Bool {
        switch requiredLevel {
        case .allow:
            return true
        case .deny:
            return false
        case .admin:
            return memberRole == .admin || memberRole == .superAdmin
        case .superAdmin:
            return memberRole == .superAdmin
        case .unknown:
            return false
        }
    }
}

// MARK: - Conversation Permissions Errors

enum ConversationPermissionsError: LocalizedError {
    case clientNotAvailable
    case conversationNotFound(conversationId: String)
    case memberNotFound(memberInboxId: String)
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .clientNotAvailable:
            return "XMTP client is not available"
        case .conversationNotFound(let conversationId):
            return "Conversation not found: \(conversationId)"
        case .memberNotFound(let memberInboxId):
            return "Member not found: \(memberInboxId)"
        case .permissionDenied:
            return "Permission denied for this action"
        }
    }
}
