import Combine
import ConvosMessagingProtocols
import Foundation
import GRDB

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
        // Stage 6e Phase B: route through the `MessagingClient`
        // abstraction. `messagingConversation(with:)` returns a
        // `MessagingConversation`; admin / super-admin checks live on
        // `MessagingGroup`. No XMTPiOS types in this file.
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client
        let group = try await loadGroup(client: client, conversationId: conversationId)

        let isCurrentUserAdmin = try await group.isAdmin(inboxId: client.inboxId)
        let isCurrentUserSuperAdmin = try await group.isSuperAdmin(inboxId: client.inboxId)

        // Get all conversation members to analyze the permission structure
        let members = try await group.members()
        var multipleAdminsSeen = false
        var adminsCount = 0
        for member in members {
            let isAdmin = (try? await group.isAdmin(inboxId: member.inboxId)) ?? false
            let isSuperAdmin = (try? await group.isSuperAdmin(inboxId: member.inboxId)) ?? false
            if isAdmin || isSuperAdmin {
                adminsCount += 1
                if adminsCount > 1 {
                    multipleAdminsSeen = true
                    break
                }
            }
        }
        let hasMultipleAdmins = multipleAdminsSeen

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
        // Stage 6e Phase B: route through the `MessagingClient`
        // abstraction (see `getConversationPermissions(for:)` above).
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client
        let group = try await loadGroup(client: client, conversationId: conversationId)

        // Use the abstraction-layer methods to check member roles
        if try await group.isSuperAdmin(inboxId: memberInboxId) {
            return .superAdmin
        } else if try await group.isAdmin(inboxId: memberInboxId) {
            return .admin
        } else {
            // Check if member exists in the conversation
            let members = try await group.members()
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
        // Stage 6e Phase B: route through the `MessagingClient`
        // abstraction. `MessagingMember.consentState` is already
        // `MessagingConsentState`, which maps to `Consent` via the
        // `MessagingConsentState.consent` boundary helper.
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client
        let group = try await loadGroup(client: client, conversationId: conversationId)

        let members = try await group.members()

        var conversationMemberInfos: [ConversationMemberInfo] = []
        for member in members {
            // Determine role using the abstraction-layer methods
            let memberRole: MemberRole
            if try await group.isSuperAdmin(inboxId: member.inboxId) {
                memberRole = .superAdmin
            } else if try await group.isAdmin(inboxId: member.inboxId) {
                memberRole = .admin
            } else {
                memberRole = .member
            }

            let conversationMemberInfo = ConversationMemberInfo(
                inboxId: member.inboxId,
                role: memberRole,
                consent: member.consentState.consent,
                addedAt: Date() // XMTP doesn't provide exact add date, use current
            )

            conversationMemberInfos.append(conversationMemberInfo)
        }

        return conversationMemberInfos
    }

    func addAdmin(memberInboxId: String, to conversationId: String) async throws {
        // Stage 6e Phase B: route through the `MessagingClient`
        // abstraction.
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client
        let group = try await loadGroup(client: client, conversationId: conversationId)
        try await group.addAdmin(inboxId: memberInboxId)
    }

    func removeAdmin(memberInboxId: String, from conversationId: String) async throws {
        // Stage 6e Phase B: route through the `MessagingClient`
        // abstraction.
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client
        let group = try await loadGroup(client: client, conversationId: conversationId)
        try await group.removeAdmin(inboxId: memberInboxId)
    }

    func addSuperAdmin(memberInboxId: String, to conversationId: String) async throws {
        // Stage 6e Phase B: route through the `MessagingClient`
        // abstraction.
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client
        let group = try await loadGroup(client: client, conversationId: conversationId)
        try await group.addSuperAdmin(inboxId: memberInboxId)
    }

    func removeSuperAdmin(memberInboxId: String, from conversationId: String) async throws {
        // Stage 6e Phase B: route through the `MessagingClient`
        // abstraction.
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client
        let group = try await loadGroup(client: client, conversationId: conversationId)
        try await group.removeSuperAdmin(inboxId: memberInboxId)
    }

    func addMembers(inboxIds: [String], to conversationId: String) async throws {
        // Stage 6e Phase B: route through the `MessagingClient`
        // abstraction.
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client
        let group = try await loadGroup(client: client, conversationId: conversationId)
        try await group.addMembers(inboxIds: inboxIds)
    }

    func removeMembers(inboxIds: [String], from conversationId: String) async throws {
        // Stage 6e Phase B: route through the `MessagingClient`
        // abstraction.
        let client = try await self.inboxStateManager.waitForInboxReadyResult().client
        let group = try await loadGroup(client: client, conversationId: conversationId)
        try await group.removeMembers(inboxIds: inboxIds)
    }

    // MARK: - Private Helper Methods

    /// Looks up a `MessagingGroup` for `conversationId` via the
    /// `MessagingClient` abstraction. Throws
    /// `conversationNotFound` for both missing conversations and DMs
    /// (which the permission methods all assume to be groups).
    private func loadGroup(
        client: any MessagingClient,
        conversationId: String
    ) async throws -> any MessagingGroup {
        guard let group = try await client.messagingGroup(with: conversationId) else {
            throw ConversationPermissionsError.conversationNotFound(
                conversationId: conversationId
            )
        }
        return group
    }

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
