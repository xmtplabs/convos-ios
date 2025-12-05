import Foundation

public class MockMyProfileWriter: MyProfileWriterProtocol {
    public init() {}
    public func update(displayName: String, conversationId: String) {}
    public func update(avatar: Image?, conversationId: String) async throws {}
}
