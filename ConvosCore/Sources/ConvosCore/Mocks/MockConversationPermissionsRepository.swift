import Foundation

/// Mock implementation of ConversationPermissionsRepositoryProtocol for testing
public final class MockConversationPermissionsRepository: ConversationPermissionsRepositoryProtocol, @unchecked Sendable {
    public var mockPermissions: ConversationPermissionPolicySet = .defaultPolicy
    public var mockMemberRole: MemberRole = .member
    public var mockCanPerformAction: Bool = true
    public var mockMembers: [ConversationMemberInfo] = []

    public init() {}

    public func addAdmin(memberInboxId: String, to conversationId: String) async throws {}

    public func removeAdmin(memberInboxId: String, from conversationId: String) async throws {}

    public func addSuperAdmin(memberInboxId: String, to conversationId: String) async throws {}

    public func removeSuperAdmin(memberInboxId: String, from conversationId: String) async throws {}

    public func addMembers(inboxIds: [String], to conversationId: String) async throws {}

    public func removeMembers(inboxIds: [String], from conversationId: String) async throws {}

    public func getConversationPermissions(for conversationId: String) async throws -> ConversationPermissionPolicySet {
        mockPermissions
    }

    public func getMemberRole(memberInboxId: String, in conversationId: String) async throws -> MemberRole {
        mockMemberRole
    }

    public func canPerformAction(
        memberInboxId: String,
        action: ConversationPermissionAction,
        in conversationId: String
    ) async throws -> Bool {
        mockCanPerformAction
    }

    public func getConversationMembers(for conversationId: String) async throws -> [ConversationMemberInfo] {
        mockMembers
    }
}
