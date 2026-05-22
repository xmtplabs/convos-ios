import Foundation
import GRDB

struct DBAgentJoinRequest: Codable, FetchableRecord, Hashable {
    let conversationId: String
    let status: String
    let date: Date
}
