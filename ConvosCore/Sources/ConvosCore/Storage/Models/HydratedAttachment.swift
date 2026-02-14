import Foundation

public struct HydratedAttachment: Hashable, Codable, Sendable {
    public let key: String
    public let isRevealed: Bool
    public let isHiddenByOwner: Bool
    public let width: Int?
    public let height: Int?

    public var aspectRatio: CGFloat? {
        guard let w = width, let h = height, h > 0 else { return nil }
        return CGFloat(w) / CGFloat(h)
    }

    public init(key: String, isRevealed: Bool = false, isHiddenByOwner: Bool = false, width: Int? = nil, height: Int? = nil) {
        self.key = key
        self.isRevealed = isRevealed
        self.isHiddenByOwner = isHiddenByOwner
        self.width = width
        self.height = height
    }
}
