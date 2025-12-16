#if canImport(UIKit)
import Foundation
import UIKit

public class MockMyProfileWriter: MyProfileWriterProtocol {
    public init() {}
    public func update(displayName: String, conversationId: String) {}
    public func update(avatar: UIImage?, conversationId: String) async throws {}
}

#endif
