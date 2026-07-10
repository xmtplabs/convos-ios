import Foundation
import GRDB

// MARK: - DBMemberDeparture

/// Marks a member who announced they are leaving a conversation (via the
/// protocol's leave-request message) but whose MLS remove-commit hasn't been
/// finalized yet. While the marker exists the member is excluded from the
/// persisted member rows, so every member-list surface drops the leaver
/// promptly instead of waiting for an authorized client to finalize the
/// removal.
///
/// Lifecycle:
/// - Written by `IncomingMessageWriter` when a leave-request message is
///   ingested (any ingest path: stream, catch-up, batch, notification
///   extension).
/// - Deleted by `ConversationWriter.persist` once a synced MLS member list
///   no longer contains the inbox (the removal finalized, the marker has
///   done its job).
/// - Deleted by `IncomingMessageWriter` when a membership change re-adds the
///   inbox (rejoin via invite after the removal finalized).
struct DBMemberDeparture: Codable, FetchableRecord, PersistableRecord, Hashable {
    static var databaseTableName: String { "member_departure" }

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let inboxId: Column = Column(CodingKeys.inboxId)
        static let dateNs: Column = Column(CodingKeys.dateNs)
    }

    let conversationId: String
    let inboxId: String
    let dateNs: Int64
}
