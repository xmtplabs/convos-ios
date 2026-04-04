import Foundation
import GRDB

struct DBDMLinkDetails: Codable, FetchableRecord, Hashable {
    let originConversationName: String?
    let originMemberName: String?
}
