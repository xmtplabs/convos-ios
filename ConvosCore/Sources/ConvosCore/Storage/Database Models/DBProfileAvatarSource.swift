import Foundation
import GRDB

/// The current user's plaintext source avatar, keyed by `inboxId`. Held so the
/// durable publish queue can upload the same image once and fan the resulting
/// plain URL out to each conversation without re-prompting the user. `version`
/// is bumped each time the user sets a new avatar; publish jobs pin a version so
/// stale jobs drop without uploading. `uploadedUrl` caches the single plain
/// upload for the current `version` (nil on a new version), so the serialized
/// drain loop uploads exactly once and every later per-conversation job (and
/// any crash-recovery re-run) reuses it.
struct DBProfileAvatarSource: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "profileAvatarSource"

    enum Columns {
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let plaintext: Column = Column(CodingKeys.plaintext)
        static let version: Column = Column(CodingKeys.version)
        static let uploadedUrl: Column = Column(CodingKeys.uploadedUrl)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let inboxId: String
    var plaintext: Data
    var version: Int64
    var uploadedUrl: String?
    var updatedAt: Date

    init(inboxId: String, plaintext: Data, version: Int64, uploadedUrl: String? = nil, updatedAt: Date) {
        self.inboxId = inboxId
        self.plaintext = plaintext
        self.version = version
        self.uploadedUrl = uploadedUrl
        self.updatedAt = updatedAt
    }
}

extension DBProfileAvatarSource {
    static func fetchOne(_ db: Database, inboxId: String) throws -> DBProfileAvatarSource? {
        try fetchOne(db, key: inboxId)
    }
}
