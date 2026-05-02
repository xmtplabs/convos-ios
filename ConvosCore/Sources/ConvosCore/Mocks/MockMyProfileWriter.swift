import Foundation

/// Mock implementation of MyProfileWriterProtocol for testing
public final class MockMyProfileWriter: MyProfileWriterProtocol, @unchecked Sendable {
    public struct AvatarUpdate {
        public let image: ImageType?
        public let imageSourceContentDigest: String?
        public let conversationId: String
    }

    public var updatedDisplayNames: [(name: String, conversationId: String)] = []
    public var updatedAvatars: [AvatarUpdate] = []
    public var updatedMetadata: [(metadata: ProfileMetadata?, conversationId: String)] = []
    public var publishedMetadata: [(metadata: ProfileMetadata?, conversationId: String)] = []
    public var publishError: (any Error)?

    public init() {}

    public func update(displayName: String, conversationId: String) async throws {
        updatedDisplayNames.append((name: displayName, conversationId: conversationId))
    }

    public func update(avatar: ImageType?, imageSourceContentDigest: String?, conversationId: String) async throws {
        updatedAvatars.append(.init(
            image: avatar,
            imageSourceContentDigest: imageSourceContentDigest,
            conversationId: conversationId
        ))
    }

    public func update(metadata: ProfileMetadata?, conversationId: String) async throws {
        updatedMetadata.append((metadata: metadata, conversationId: conversationId))
    }

    public func updateAndPublish(metadata: ProfileMetadata?, conversationId: String) async throws {
        publishedMetadata.append((metadata: metadata, conversationId: conversationId))
        if let publishError {
            throw publishError
        }
    }

    public var syncedConversationIds: [String] = []

    public func syncFromGlobalProfile(conversationId: String) async throws {
        syncedConversationIds.append(conversationId)
    }
}
