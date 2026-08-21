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
        static let remoteAvatarUrl: Column = Column(CodingKeys.remoteAvatarUrl)
        static let remoteVersion: Column = Column(CodingKeys.remoteVersion)
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
    /// The avatar URL the backend holds for this user, as returned by the last
    /// successful write. This is what the fan-out advertises to other people -
    /// `imageData` is the local source bytes, which nobody else can see.
    let remoteAvatarUrl: String?
    /// The backend's version for this profile, echoed on the fan-out so a
    /// recipient holding it can skip a fetch.
    let remoteVersion: Int?
    let updatedAt: Date

    init(
        inboxId: String,
        name: String? = nil,
        imageData: Data? = nil,
        imageAssetIdentifier: String? = nil,
        imageContentDigest: String? = nil,
        metadata: ProfileMetadata? = nil,
        remoteAvatarUrl: String? = nil,
        remoteVersion: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.inboxId = inboxId
        self.name = name
        self.imageData = imageData
        self.imageAssetIdentifier = imageAssetIdentifier
        self.imageContentDigest = imageContentDigest
        self.metadata = metadata
        self.remoteAvatarUrl = remoteAvatarUrl
        self.remoteVersion = remoteVersion
        self.updatedAt = updatedAt
    }
}

extension DBMyProfile {
    static func fetchAll(_ db: Database, inboxIds: [String]) throws -> [DBMyProfile] {
        try fetchAll(db, keys: inboxIds)
    }
}
