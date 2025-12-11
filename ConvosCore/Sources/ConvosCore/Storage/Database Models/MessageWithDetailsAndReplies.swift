import Foundation
import GRDB

// MARK: - MessageWithDetailsAndReplies

struct MessageWithDetailsAndReplies: Codable, FetchableRecord, PersistableRecord, Hashable {
    let message: DBMessage
    let sender: DBConversationMemberProfileWithRole
    let reactions: [DBMessage]
    let replies: [DBMessage]
}
