import Foundation
import GRDB

// MARK: - DBConversationLatestMessage

struct DBConversationLatestMessage: Decodable, FetchableRecord {
    let conversation: DBConversation
    let latestMessage: DBMessage?
}
