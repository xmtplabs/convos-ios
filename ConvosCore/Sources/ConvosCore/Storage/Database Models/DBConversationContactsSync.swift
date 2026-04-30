import Foundation
import GRDB

/// Per-conversation marker tracking whether the contact-sync coordinator has
/// run for that conversation. Presence of a row indicates the local user has
/// taken an explicit action in the conversation and the other members have
/// already been pulled into the contacts table.
struct DBConversationContactsSync: Codable, FetchableRecord, PersistableRecord, Hashable {
    static let databaseTableName: String = "conversation_contacts_sync"

    enum Columns {
        static let conversationId: Column = Column(CodingKeys.conversationId)
        static let contactsSyncedAt: Column = Column(CodingKeys.contactsSyncedAt)
    }

    let conversationId: String
    let contactsSyncedAt: Date
}
