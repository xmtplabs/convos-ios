import Foundation
import GRDB

// MARK: - MessageWithDetailsAndReplies

struct DBMessageWithDetailsAndReplies: Codable, FetchableRecord, PersistableRecord, Hashable {
    let message: DBMessage
    let sender: DBConversationMemberProfileWithRole
    let reactions: [DBMessage]
    let replies: [DBMessage]
}
