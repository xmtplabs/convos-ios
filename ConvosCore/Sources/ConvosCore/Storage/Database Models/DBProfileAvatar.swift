import Foundation
import GRDB

/// A person's avatar for one conversation, keyed by `(inboxId, conversationId)`.
/// Avatars are per-conversation because each is encrypted with that
/// conversation's group key, so the same source image yields a different
/// `(url, salt, nonce, encryptionKey)` per conversation. The display resolver
/// prefers the slot for the conversation being rendered and falls back to the
/// most recently updated slot.
///
/// Not wired into rendering or sync yet; introduced ahead of the
/// `ProfilesRepository` that owns it.
struct DBProfileAvatar: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "profileAvatar"

    enum Columns {
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let url: Column = Column(CodingKeys.url)
        static let salt: Column = Column(CodingKeys.salt)
        static let nonce: Column = Column(CodingKeys.nonce)
        static let encryptionKey: Column = Column(CodingKeys.encryptionKey)
        static let profileSource: Column = Column(CodingKeys.profileSource)
        static let contentDigest: Column = Column(CodingKeys.contentDigest)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let inboxId: String
    let conversationId: String
    var url: String?
    var salt: Data?
    var nonce: Data?
    var encryptionKey: Data?
    var profileSource: ProfileSource
    /// Reserved for the cross-conversation image-digest optimization (ADR 014).
    /// Always nil until that work lands.
    var contentDigest: String?
    var updatedAt: Date

    init(
        inboxId: String,
        conversationId: String,
        url: String? = nil,
        salt: Data? = nil,
        nonce: Data? = nil,
        encryptionKey: Data? = nil,
        profileSource: ProfileSource,
        contentDigest: String? = nil,
        updatedAt: Date
    ) {
        self.inboxId = inboxId
        self.conversationId = conversationId
        self.url = url
        self.salt = salt
        self.nonce = nonce
        self.encryptionKey = encryptionKey
        self.profileSource = profileSource
        self.contentDigest = contentDigest
        self.updatedAt = updatedAt
    }

    var hasValidEncryptedAvatar: Bool {
        guard let salt, let nonce, url != nil else {
            return false
        }
        return salt.count == 32 && nonce.count == 12
    }
}

extension DBProfileAvatar {
    static func fetchOne(
        _ db: Database,
        inboxId: String,
        conversationId: String
    ) throws -> DBProfileAvatar? {
        try fetchOne(
            db,
            key: [
                Columns.inboxId.name: inboxId,
                Columns.conversationId.name: conversationId
            ]
        )
    }

    static func fetchAll(_ db: Database, inboxId: String) throws -> [DBProfileAvatar] {
        try filter(Columns.inboxId == inboxId).fetchAll(db)
    }
}
