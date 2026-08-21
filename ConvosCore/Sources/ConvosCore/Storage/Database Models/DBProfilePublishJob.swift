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
/// exactly once. `sourceVersion` pins the `DBProfileAvatarSource.version` the
/// job publishes so superseded jobs drop without uploading; the single plain
/// upload for that version is cached on the source (`uploadedUrl`), not per job.
///
/// The legacy per-job crypto columns (`ciphertext`, `salt`, `nonce`, `groupKey`,
/// `filename`, `uploadedURL`) predate the write-side removal of image
/// encryption. They remain in the table for old rows but are no longer written
/// or read; GRDB ignores the extra columns.
struct DBProfilePublishJob: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "profilePublishJob"

    enum Columns {
        static let id: Column = Column(CodingKeys.id)
        static let seq: Column = Column(CodingKeys.seq)
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let sourceVersion: Column = Column(CodingKeys.sourceVersion)
        static let hasAvatar: Column = Column(CodingKeys.hasAvatar)
        static let state: Column = Column(CodingKeys.state)
        static let attemptCount: Column = Column(CodingKeys.attemptCount)
        static let nextAttemptAt: Column = Column(CodingKeys.nextAttemptAt)
        static let lastError: Column = Column(CodingKeys.lastError)
        static let profileUpdatedAt: Column = Column(CodingKeys.profileUpdatedAt)
        static let createdAt: Column = Column(CodingKeys.createdAt)
        static let updatedAt: Column = Column(CodingKeys.updatedAt)
    }

    let id: String
    let seq: Int64
    let conversationId: String
    var sourceVersion: Int64?
    var hasAvatar: Bool
    var state: ProfilePublishJobState
    var attemptCount: Int64
    var nextAttemptAt: Date
    var lastError: String?
    /// The `DBMyProfile.updatedAt` current when this job was enqueued. Stamped
    /// into `ConversationLocalState.publishedProfileUpdatedAt` after delivery
    /// instead of the send-time value: the job's content decisions (`hasAvatar`,
    /// `sourceVersion`) were pinned at enqueue, so stamping a newer edit's
    /// timestamp would mark the conversation current without that edit's
    /// content ever being sent (a name-only job enqueued before an avatar edit
    /// would otherwise suppress the avatar's publish forever). Nil (legacy
    /// rows) skips the stamp, costing at most one duplicate publish.
    var profileUpdatedAt: Date?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        seq: Int64,
        conversationId: String,
        sourceVersion: Int64? = nil,
        hasAvatar: Bool = false,
        state: ProfilePublishJobState = .pending,
        attemptCount: Int64 = 0,
        nextAttemptAt: Date,
        lastError: String? = nil,
        profileUpdatedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.seq = seq
        self.conversationId = conversationId
        self.sourceVersion = sourceVersion
        self.hasAvatar = hasAvatar
        self.state = state
        self.attemptCount = attemptCount
        self.nextAttemptAt = nextAttemptAt
        self.lastError = lastError
        self.profileUpdatedAt = profileUpdatedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension DBProfilePublishJob {
    static func fetchOne(_ db: Database, id: String) throws -> DBProfilePublishJob? {
        try fetchOne(db, key: id)
    }
}
