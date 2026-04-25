import Foundation

// MARK: - Permission / role enums

/// A policy slot on a `MessagingPermissionPolicySet` — e.g. "who can
/// add members?", "who can update the group image?". Mirrors
/// `XMTPiOS.PermissionOption`.
public enum MessagingPermission: String, Hashable, Sendable, Codable {
    case allow
    case deny
    case admin
    case superAdmin
    case unknown
}

/// A member's role on a group. Mirrors `XMTPiOS.PermissionLevel`.
public enum MessagingMemberRole: String, Hashable, Sendable, Codable {
    case member
    case admin
    case superAdmin
}

// MARK: - Policy set

/// The complete set of policy slots on a group.
///
/// Matches the `XMTPiOS.PermissionPolicySet` fields consumed in
/// `StreamProcessor.swift:145-148` and `ConversationPermissionsRepository`.
public struct MessagingPermissionPolicySet: Hashable, Sendable, Codable {
    public var addMemberPolicy: MessagingPermission
    public var removeMemberPolicy: MessagingPermission
    public var addAdminPolicy: MessagingPermission
    public var removeAdminPolicy: MessagingPermission
    public var updateGroupNamePolicy: MessagingPermission
    public var updateGroupDescriptionPolicy: MessagingPermission
    public var updateGroupImagePolicy: MessagingPermission
    public var updateMessageDisappearingPolicy: MessagingPermission
    public var updateAppDataPolicy: MessagingPermission

    public init(
        addMemberPolicy: MessagingPermission,
        removeMemberPolicy: MessagingPermission,
        addAdminPolicy: MessagingPermission,
        removeAdminPolicy: MessagingPermission,
        updateGroupNamePolicy: MessagingPermission,
        updateGroupDescriptionPolicy: MessagingPermission,
        updateGroupImagePolicy: MessagingPermission,
        updateMessageDisappearingPolicy: MessagingPermission,
        updateAppDataPolicy: MessagingPermission
    ) {
        self.addMemberPolicy = addMemberPolicy
        self.removeMemberPolicy = removeMemberPolicy
        self.addAdminPolicy = addAdminPolicy
        self.removeAdminPolicy = removeAdminPolicy
        self.updateGroupNamePolicy = updateGroupNamePolicy
        self.updateGroupDescriptionPolicy = updateGroupDescriptionPolicy
        self.updateGroupImagePolicy = updateGroupImagePolicy
        self.updateMessageDisappearingPolicy = updateMessageDisappearingPolicy
        self.updateAppDataPolicy = updateAppDataPolicy
    }
}

// MARK: - Member

/// A member of a `MessagingGroup` / `MessagingDm`. Mirrors the subset
/// of `XMTPiOS.Member` fields that Convos actually reads in
/// `ConversationWriter.swift:875`.
public struct MessagingMember: Hashable, Sendable, Codable {
    public let inboxId: MessagingInboxID
    public let identities: [MessagingIdentity]
    public let role: MessagingMemberRole
    public let consentState: MessagingConsentState

    public init(
        inboxId: MessagingInboxID,
        identities: [MessagingIdentity],
        role: MessagingMemberRole,
        consentState: MessagingConsentState
    ) {
        self.inboxId = inboxId
        self.identities = identities
        self.role = role
        self.consentState = consentState
    }
}
