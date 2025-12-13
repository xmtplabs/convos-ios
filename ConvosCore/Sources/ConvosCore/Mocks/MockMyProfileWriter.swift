import Foundation

/// Mock implementation of MyProfileWriterProtocol for testing
public final class MockMyProfileWriter: MyProfileWriterProtocol, @unchecked Sendable {
    public var updatedDisplayNames: [(name: String, conversationId: String)] = []
    public var updatedAvatars: [(image: ImageType?, conversationId: String)] = []

    public init() {}

    public func update(displayName: String, conversationId: String) async throws {
        updatedDisplayNames.append((name: displayName, conversationId: conversationId))
    }

    public func update(avatar: ImageType?, conversationId: String) async throws {
        updatedAvatars.append((image: avatar, conversationId: conversationId))
    }
}
