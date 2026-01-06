import Foundation

// MARK: - MessageSource

public enum MessageSource: String, Hashable, Codable, Sendable {
    case incoming, outgoing

    public var isIncoming: Bool {
        self == .incoming
    }
}
