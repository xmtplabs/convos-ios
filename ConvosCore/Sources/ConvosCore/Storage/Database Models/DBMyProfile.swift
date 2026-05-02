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
        static let imageContentDigest: Column = Column(CodingKeys.imageContentDigest)
        static let metadata: Column = Column(CodingKeys.metadata)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let inboxId: String
    let name: String?
    let imageData: Data?
    /// Photos library `PHAsset.localIdentifier` for the source image, used purely for picker
    /// preselection UX. Not used for change detection — the picker may return nil here under
    /// limited library access, so we rely on `imageContentDigest` for that.
    let imageAssetIdentifier: String?
    /// Stable, content-addressed digest of `imageData` (base64 SHA-256). Activate-sync
    /// compares this against `DBMemberProfile.imageSourceContentDigest` to decide whether a
    /// per-conversation re-upload is needed.
    let imageContentDigest: String?
    let metadata: ProfileMetadata?
    let updatedAt: Date

    init(
        inboxId: String,
        name: String? = nil,
        imageData: Data? = nil,
        imageAssetIdentifier: String? = nil,
        imageContentDigest: String? = nil,
        metadata: ProfileMetadata? = nil,
        updatedAt: Date = Date()
    ) {
        self.inboxId = inboxId
        self.name = name
        self.imageData = imageData
        self.imageAssetIdentifier = imageAssetIdentifier
        self.imageContentDigest = imageContentDigest
        self.metadata = metadata
        self.updatedAt = updatedAt
    }
}
