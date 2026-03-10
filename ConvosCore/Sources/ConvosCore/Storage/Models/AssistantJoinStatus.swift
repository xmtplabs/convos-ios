import Foundation

public enum AssistantJoinStatus: Equatable, Hashable, Sendable {
    case pending
    case noAgentsAvailable
    case failed
}
