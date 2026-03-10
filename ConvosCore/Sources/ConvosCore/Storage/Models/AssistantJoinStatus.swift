import Foundation

public enum AssistantJoinStatus: String, Equatable, Hashable, Sendable, Codable {
    case pending
    case noAgentsAvailable
    case failed
}
