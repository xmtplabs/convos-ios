import ConvosAppData
import Foundation
import GRDB

/// Local user's global profile, stored as a singleton row.
///
/// The single-inbox identity model gives each user one global profile broadcast to
/// every conversation they participate in. Enforced as a singleton by anchoring the
/// row to a fixed primary key (`DBMyProfile.singletonId`).
struct DBMyProfile: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "myProfile"
    static let singletonId: String = "me"

    enum Columns {
        static let id: Column = Column(CodingKeys.id)
        static let name: Column = Column(CodingKeys.name)
        static let avatar: Column = Column(CodingKeys.avatar)
        static let avatarSalt: Column = Column(CodingKeys.avatarSalt)
        static let avatarNonce: Column = Column(CodingKeys.avatarNonce)
        static let avatarKey: Column = Column(CodingKeys.avatarKey)
        static let metadata: Column = Column(CodingKeys.metadata)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let id: String
    let name: String?
    let avatar: String?
    let avatarSalt: Data?
    let avatarNonce: Data?
    let avatarKey: Data?
    let metadata: ProfileMetadata?
    let updatedAt: Date

    init(
        name: String?,
        avatar: String?,
        avatarSalt: Data? = nil,
        avatarNonce: Data? = nil,
        avatarKey: Data? = nil,
        metadata: ProfileMetadata? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = Self.singletonId
        self.name = name
        self.avatar = avatar
        self.avatarSalt = avatarSalt
        self.avatarNonce = avatarNonce
        self.avatarKey = avatarKey
        self.metadata = metadata
        self.updatedAt = updatedAt
    }

    var encryptedImageRef: EncryptedImageRef? {
        guard let url = avatar,
              let salt = avatarSalt,
              let nonce = avatarNonce,
              salt.count == 32,
              nonce.count == 12 else {
            return nil
        }
        var ref = EncryptedImageRef()
        ref.url = url
        ref.salt = salt
        ref.nonce = nonce
        return ref
    }
}

extension DBMyProfile {
    static func fetchSingleton(_ db: Database) throws -> DBMyProfile? {
        try fetchOne(db, key: singletonId)
    }
}
