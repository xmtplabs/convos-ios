import Foundation

/// Mock implementation of ConversationMetadataWriterProtocol for testing
public final class MockConversationMetadataWriter: ConversationMetadataWriterProtocol, @unchecked Sendable {
    public var updatedNames: [(name: String, conversationId: String)] = []
    public var updatedDescriptions: [(description: String, conversationId: String)] = []
    public var updatedImageUrls: [(url: String, conversationId: String)] = []
    public var addedMembers: [(memberIds: [String], conversationId: String)] = []
    public var removedMembers: [(memberIds: [String], conversationId: String)] = []
    public var promotedAdmins: [(memberId: String, conversationId: String)] = []
    public var demotedAdmins: [(memberId: String, conversationId: String)] = []
    public var promotedSuperAdmins: [(memberId: String, conversationId: String)] = []
    public var demotedSuperAdmins: [(memberId: String, conversationId: String)] = []
    public var updatedImages: [(image: ImageType, conversation: Conversation)] = []
    public var updatedExpiresAt: [(expiresAt: Date, conversationId: String)] = []

    public init() {}

    public func updateName(_ name: String, for conversationId: String) async throws {
        updatedNames.append((name: name, conversationId: conversationId))
    }

    public func updateDescription(_ description: String, for conversationId: String) async throws {
        updatedDescriptions.append((description: description, conversationId: conversationId))
    }

    public func updateImageUrl(_ imageURL: String, for conversationId: String) async throws {
        updatedImageUrls.append((url: imageURL, conversationId: conversationId))
    }

    public func addMembers(_ memberInboxIds: [String], to conversationId: String) async throws {
        addedMembers.append((memberIds: memberInboxIds, conversationId: conversationId))
    }

    public func removeMembers(_ memberInboxIds: [String], from conversationId: String) async throws {
        removedMembers.append((memberIds: memberInboxIds, conversationId: conversationId))
    }

    public func promoteToAdmin(_ memberInboxId: String, in conversationId: String) async throws {
        promotedAdmins.append((memberId: memberInboxId, conversationId: conversationId))
    }

    public func demoteFromAdmin(_ memberInboxId: String, in conversationId: String) async throws {
        demotedAdmins.append((memberId: memberInboxId, conversationId: conversationId))
    }

    public func promoteToSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws {
        promotedSuperAdmins.append((memberId: memberInboxId, conversationId: conversationId))
    }

    public func demoteFromSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws {
        demotedSuperAdmins.append((memberId: memberInboxId, conversationId: conversationId))
    }

    public func updateImage(_ image: ImageType, for conversation: Conversation) async throws {
        updatedImages.append((image: image, conversation: conversation))
    }

    public func updateExpiresAt(_ expiresAt: Date, for conversationId: String) async throws {
        updatedExpiresAt.append((expiresAt: expiresAt, conversationId: conversationId))
    }
}
