import ConvosAppData
import Foundation
import GRDB

/// The current user's canonical identity, keyed by `inboxId`. Authored locally
/// when the user edits their profile; the durable publish queue fans changes out
/// to conversations. Distinct from `DBProfile`, which holds other people's
/// identities merged from inbound messages.
///
/// Not wired into rendering or publishing yet; introduced ahead of the
/// `ProfilesRepository` that owns it.
struct DBSelfProfile: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "selfProfile"

    enum Columns {
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let name: Column = Column(CodingKeys.name)
        static let metadata: Column = Column(CodingKeys.metadata)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let inboxId: String
    var name: String?
    var metadata: ProfileMetadata?
    var updatedAt: Date

    init(
        inboxId: String,
        name: String? = nil,
        metadata: ProfileMetadata? = nil,
        updatedAt: Date
    ) {
        self.inboxId = inboxId
        self.name = name
        self.metadata = metadata
        self.updatedAt = updatedAt
    }
}

extension DBSelfProfile {
    static func fetchOne(_ db: Database, inboxId: String) throws -> DBSelfProfile? {
        try fetchOne(db, key: inboxId)
    }
}
