import Foundation

// MARK: - DBMessageType

public enum DBMessageType: String, Codable {
    case original,
         reply,
         reaction
}
