import Foundation
import GRDB

/// Pending profile broadcasts to conversations.
///
/// When the global profile changes, one entry is enqueued per conversation so the
/// broadcast worker (introduced in C8) can send a `ProfileUpdate` to each group
/// newest-conversation-first, retrying with backoff and persisting across restarts.
struct DBProfileBroadcastQueue: Codable, FetchableRecord, PersistableRecord, Identifiable, Hashable {
    static let databaseTableName: String = "profileBroadcastQueue"

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let enqueuedAt: Column = Column(CodingKeys.enqueuedAt)
        static let lastAttemptAt: Column = Column(CodingKeys.lastAttemptAt)
        static let failureCount: Column = Column(CodingKeys.failureCount)
    }

    var id: String { conversationId }
    let conversationId: String
    let enqueuedAt: Date
    let lastAttemptAt: Date?
    let failureCount: Int

    init(
        conversationId: String,
        enqueuedAt: Date = Date(),
        lastAttemptAt: Date? = nil,
        failureCount: Int = 0
    ) {
        self.conversationId = conversationId
        self.enqueuedAt = enqueuedAt
        self.lastAttemptAt = lastAttemptAt
        self.failureCount = failureCount
    }

    func with(lastAttemptAt: Date?, failureCount: Int) -> DBProfileBroadcastQueue {
        .init(
            conversationId: conversationId,
            enqueuedAt: enqueuedAt,
            lastAttemptAt: lastAttemptAt,
            failureCount: failureCount
        )
    }
}
