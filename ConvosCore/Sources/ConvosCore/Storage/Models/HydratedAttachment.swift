import Foundation

public struct HydratedAttachment: Hashable, Codable, Sendable {
    public let key: String
    public let isRevealed: Bool

    public init(key: String, isRevealed: Bool = false) {
        self.key = key
        self.isRevealed = isRevealed
    }
}
