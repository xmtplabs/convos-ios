import Foundation

/// Mock implementation of MyProfileWriterProtocol for testing
public final class MockMyProfileWriter: MyProfileWriterProtocol, @unchecked Sendable {
    public var updatedDisplayNames: [(name: String, conversationId: String)] = []
    public var updatedAvatars: [(image: ImageType?, imageSourceAssetIdentifier: String?, conversationId: String)] = []
    public var updatedMetadata: [(metadata: ProfileMetadata?, conversationId: String)] = []
    public var publishedMetadata: [(metadata: ProfileMetadata?, conversationId: String)] = []
    public var publishError: (any Error)?

    public init() {}

    public func update(displayName: String, conversationId: String) async throws {
        updatedDisplayNames.append((name: displayName, conversationId: conversationId))
    }

    public func update(avatar: ImageType?, imageSourceAssetIdentifier: String?, conversationId: String) async throws {
        updatedAvatars.append((
            image: avatar,
            imageSourceAssetIdentifier: imageSourceAssetIdentifier,
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
