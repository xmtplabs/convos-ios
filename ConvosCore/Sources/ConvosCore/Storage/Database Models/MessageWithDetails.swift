import Foundation
import GRDB

// MARK: - MessageWithDetails

struct MessageWithDetails: Codable, FetchableRecord, Hashable {
    let message: DBMessage
    let messageSender: DBConversationMemberProfileWithRole
    let messageReactions: [DBMessage]
    let sourceMessage: DBMessage?
}

struct MessageWithDetailsLite: Codable, FetchableRecord, Hashable {
    let message: DBMessage
    let messageSender: DBConversationMemberProfileWithRole
    let sourceMessage: DBMessage?

    func withReactions(_ reactions: [DBMessage]) -> MessageWithDetails {
        MessageWithDetails(
            message: message,
            messageSender: messageSender,
            messageReactions: reactions,
            sourceMessage: sourceMessage
        )
    }
}
