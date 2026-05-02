import Foundation

/// The local user's global profile, keyed by `inboxId`.
public struct MyProfile: Equatable, Hashable, Sendable {
    public let inboxId: String
    public let name: String?
    public let imageData: Data?
    public let imageAssetIdentifier: String?
    public let metadata: ProfileMetadata?
    public let updatedAt: Date

    public init(
        inboxId: String,
        name: String? = nil,
        imageData: Data? = nil,
        imageAssetIdentifier: String? = nil,
        metadata: ProfileMetadata? = nil,
        updatedAt: Date = Date()
    ) {
        self.inboxId = inboxId
        self.name = name
        self.imageData = imageData
        self.imageAssetIdentifier = imageAssetIdentifier
        self.metadata = metadata
        self.updatedAt = updatedAt
    }

    public var isEmpty: Bool {
        (name?.isEmpty ?? true) && imageData == nil && (metadata?.isEmpty ?? true)
    }
}
