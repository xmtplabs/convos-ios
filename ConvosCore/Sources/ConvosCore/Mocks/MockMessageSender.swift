import Foundation
@preconcurrency import XMTPiOS

/// Mock implementation of MessageSender for testing
public final class MockMessageSender: MessageSender, @unchecked Sendable {
    public var preparedMessages: [String] = []
    public var publishedCount: Int = 0
    public var mockConsentState: ConsentState = .allowed

    public init() {}

    public func sendExplode(expiresAt: Date) async throws {
        // No-op for mock
    }

    public func prepare(text: String) async throws -> String {
        let messageId = UUID().uuidString
        preparedMessages.append(messageId)
        return messageId
    }

    public func prepare(remoteAttachment: RemoteAttachment) async throws -> String {
        let messageId = UUID().uuidString
        preparedMessages.append(messageId)
        return messageId
    }

    public func publish() async throws {
        publishedCount += 1
    }

    public func publishMessage(messageId: String) async throws {
        publishedCount += 1
    }

    public func consentState() throws -> ConsentState {
        mockConsentState
    }
}

/// Mock implementation of ConversationSender for testing
public class MockConversationSender: ConversationSender, @unchecked Sendable {
    public var id: String
    public var addedMembers: [[String]] = []
    public var removedMembers: [[String]] = []
    public var preparedMessages: [String] = []
    public var publishedCount: Int = 0
    public var ensureInviteTagCalled: Bool = false

    public init(id: String = "mock-conversation-id") {
        self.id = id
    }

    public func add(members inboxIds: [String]) async throws {
        addedMembers.append(inboxIds)
    }

    public func remove(members inboxIds: [String]) async throws {
        removedMembers.append(inboxIds)
    }

    public func prepare(text: String) async throws -> String {
        let messageId = UUID().uuidString
        preparedMessages.append(messageId)
        return messageId
    }

    public func ensureInviteTag() async throws {
        ensureInviteTagCalled = true
    }

    public func publish() async throws {
        publishedCount += 1
    }
}

/// Mock implementation of GroupConversationSender for testing
public final class MockGroupConversationSender: MockConversationSender, GroupConversationSender, @unchecked Sendable {
    public var mockPermissionPolicySet: PermissionPolicySet = .init(
        addMemberPolicy: .unknown,
        removeMemberPolicy: .unknown,
        addAdminPolicy: .unknown,
        removeAdminPolicy: .unknown,
        updateGroupNamePolicy: .unknown,
        updateGroupDescriptionPolicy: .unknown,
        updateGroupImagePolicy: .unknown,
        updateMessageDisappearingPolicy: .unknown,
        updateAppDataPolicy: .allow
    )

    public override init(id: String = "mock-group-conversation-id") {
        super.init(id: id)
    }

    public func permissionPolicySet() throws -> PermissionPolicySet {
        mockPermissionPolicySet
    }

    public func updateAddMemberPermission(newPermissionOption: PermissionOption) async throws {
        // No-op for mock
    }
}
