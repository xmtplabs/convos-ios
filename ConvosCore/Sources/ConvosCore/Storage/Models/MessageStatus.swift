import Foundation

// MARK: - MessageStatus

public enum MessageStatus: String, Hashable, Codable, Sendable {
    case unpublished, published, failed, unknown
}
