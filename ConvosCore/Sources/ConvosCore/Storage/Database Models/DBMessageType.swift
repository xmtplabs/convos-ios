import Foundation

// MARK: - DBMessageType

public enum DBMessageType: String, Codable, Sendable {
    case original,
         reply,
         reaction
}
