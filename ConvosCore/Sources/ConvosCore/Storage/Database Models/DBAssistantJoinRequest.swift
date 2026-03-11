import Foundation
import GRDB

struct DBAssistantJoinRequest: Codable, FetchableRecord, Hashable {
    let conversationId: String
    let status: String
    let date: Date
}
