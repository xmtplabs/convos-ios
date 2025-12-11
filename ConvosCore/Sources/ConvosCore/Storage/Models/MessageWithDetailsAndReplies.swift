import Foundation
import GRDB

// MARK: - MessageWithDetailsAndReplies

struct MessageWithDetailsAndReplies: Codable, FetchableRecord, PersistableRecord, Hashable {
    let message: DBMessage
    let sender: ConversationMemberProfileWithRole
    let reactions: [DBMessage]
    let replies: [DBMessage]
}
