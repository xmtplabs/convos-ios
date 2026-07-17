import Foundation
import GRDB

struct DBConversationReadReceipt: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName: String = "conversation_read_receipts"

    var conversationId: String
    var inboxId: String
    var readAtNs: Int64

    static let memberProfile: BelongsToAssociation<DBConversationReadReceipt, DBMemberProfile> = belongsTo(
        DBMemberProfile.self,
        using: ForeignKey(
            ["inboxId", "conversationId"],
            to: ["inboxId", "conversationId"]
        )
    )
}
