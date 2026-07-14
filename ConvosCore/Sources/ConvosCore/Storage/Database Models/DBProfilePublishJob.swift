import Foundation
import GRDB

/// Lifecycle of a single publish job. `pending` is ready to be claimed,
/// `uploading` is in flight, `done` is complete and may be reaped.
enum ProfilePublishJobState: String, Codable, Hashable {
    case pending
    case uploading
    case done
}

/// A durable unit of work in the profile publish queue: deliver the current
/// user's profile (name-only, or with an avatar) to one conversation. Survives
/// process death so an offline edit eventually reaches every conversation
/// exactly once. Cached crypto fields let a restart re-upload identical bytes;
/// `sourceVersion` pins the `DBProfileAvatarSource.version` the job publishes so
/// superseded jobs drop without uploading.
///
/// Not wired into publishing yet; introduced ahead of the `ProfilePublisher`
/// that drains it.
struct DBProfilePublishJob: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "profilePublishJob"

    enum Columns {
        static let id: Column = Column(CodingKeys.id)
        static let seq: Column = Column(CodingKeys.seq)
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let sourceVersion: Column = Column(CodingKeys.sourceVersion)
        static let hasAvatar: Column = Column(CodingKeys.hasAvatar)
        static let state: Column = Column(CodingKeys.state)
        static let ciphertext: Column = Column(CodingKeys.ciphertext)
        static let salt: Column = Column(CodingKeys.salt)
        static let nonce: Column = Column(CodingKeys.nonce)
        static let groupKey: Column = Column(CodingKeys.groupKey)
        static let filename: Column = Column(CodingKeys.filename)
        static let uploadedURL: Column = Column(CodingKeys.uploadedURL)
        static let attemptCount: Column = Column(CodingKeys.attemptCount)
        static let nextAttemptAt: Column = Column(CodingKeys.nextAttemptAt)
        static let lastError: Column = Column(CodingKeys.lastError)
        static let createdAt: Column = Column(CodingKeys.createdAt)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let id: String
    let seq: Int64
    let conversationId: String
    var sourceVersion: Int64?
    var hasAvatar: Bool
    var state: ProfilePublishJobState
    var ciphertext: Data?
    var salt: Data?
    var nonce: Data?
    var groupKey: Data?
    var filename: String?
    var uploadedURL: String?
    var attemptCount: Int64
    var nextAttemptAt: Date
    var lastError: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        seq: Int64,
        conversationId: String,
        sourceVersion: Int64? = nil,
        hasAvatar: Bool = false,
        state: ProfilePublishJobState = .pending,
        ciphertext: Data? = nil,
        salt: Data? = nil,
        nonce: Data? = nil,
        groupKey: Data? = nil,
        filename: String? = nil,
        uploadedURL: String? = nil,
        attemptCount: Int64 = 0,
        nextAttemptAt: Date,
        lastError: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.seq = seq
        self.conversationId = conversationId
        self.sourceVersion = sourceVersion
        self.hasAvatar = hasAvatar
        self.state = state
        self.ciphertext = ciphertext
        self.salt = salt
        self.nonce = nonce
        self.groupKey = groupKey
        self.filename = filename
        self.uploadedURL = uploadedURL
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension DBProfilePublishJob {
    static func fetchOne(_ db: Database, id: String) throws -> DBProfilePublishJob? {
        try fetchOne(db, key: id)
    }
}
