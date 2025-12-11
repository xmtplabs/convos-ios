import Foundation
import GRDB

// MARK: - MessageWithDetails

struct MessageWithDetails: Codable, FetchableRecord, PersistableRecord, Hashable {
    let message: DBMessage
    let messageSender: ConversationMemberProfileWithRole
    let messageReactions: [DBMessage]
    let sourceMessage: DBMessage?
}
