import Foundation

public enum AssistantJoinStatus: String, Equatable, Hashable, Sendable, Codable {
    case pending
    case noAgentsAvailable = "no_agents_available"
    case failed

    public var displayDuration: TimeInterval {
        switch self {
        case .pending: 15
        case .noAgentsAvailable, .failed: 3
        }
    }
}
