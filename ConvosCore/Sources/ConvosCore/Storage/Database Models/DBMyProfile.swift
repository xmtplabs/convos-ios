import Foundation
import GRDB

/// The local user's intended global profile, keyed by `inboxId`.
struct DBMyProfile: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "myProfile"

    enum Columns {
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let name: Column = Column(CodingKeys.name)
        static let imageData: Column = Column(CodingKeys.imageData)
        static let imageAssetIdentifier: Column = Column(CodingKeys.imageAssetIdentifier)
        static let metadata: Column = Column(CodingKeys.metadata)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let inboxId: String
    let name: String?
    let imageData: Data?
    /// Photos library `PHAsset.localIdentifier` for the source image, when picked from the
    /// user's library. Used by activate-sync to detect when the global photo has changed and
    /// trigger a fresh per-conversation upload.
    let imageAssetIdentifier: String?
    let metadata: ProfileMetadata?
    let updatedAt: Date

    init(
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
}
