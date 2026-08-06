import Foundation
import GRDB

/// Per-conversation marker recording that this installation has already
/// broadcast its own `ProfileSnapshot` into the conversation. Presence of a
/// row means the local user advertised its identity to the group's members, so
/// stream and catch-up redelivery of the same conversation don't re-broadcast
/// on every sight.
struct DBConversationInitialSnapshot: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "conversation_initial_snapshot"

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let sentAt: Column = Column(CodingKeys.sentAt)
    }

    let conversationId: String
    let sentAt: Date
}
