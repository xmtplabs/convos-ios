import Foundation
import GRDB

/// The current user's plaintext source avatar, keyed by `inboxId`. Held so the
/// durable publish queue can re-encrypt the same image to each conversation's
/// group key without re-prompting the user. `version` is bumped each time the
/// user sets a new avatar; publish jobs pin a version so stale jobs drop without
/// uploading.
///
/// Not wired into publishing yet; introduced ahead of the `ProfilePublisher`
/// that owns it.
struct DBProfileAvatarSource: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "profileAvatarSource"

    enum Columns {
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let plaintext: Column = Column(CodingKeys.plaintext)
        static let version: Column = Column(CodingKeys.version)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let inboxId: String
    var plaintext: Data
    var version: Int64
    var updatedAt: Date
}

extension DBProfileAvatarSource {
    static func fetchOne(_ db: Database, inboxId: String) throws -> DBProfileAvatarSource? {
        try fetchOne(db, key: inboxId)
    }
}
