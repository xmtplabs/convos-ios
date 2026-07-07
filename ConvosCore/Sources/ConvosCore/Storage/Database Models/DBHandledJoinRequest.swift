import Foundation
import GRDB

/// A join-request message that already admitted its sender to a group.
/// Keyed by XMTP message ID; see `DatabaseHandledJoinRequestStore`.
struct DBHandledJoinRequest: FetchableRecord, PersistableRecord, Codable, Hashable {
    static let databaseTableName: String = "handledJoinRequest"

    enum Columns {
        static let messageId: Column = Column(CodingKeys.messageId)
        static let handledAt: Column = Column(CodingKeys.handledAt)
    }

    let messageId: String
    let handledAt: Date
}
