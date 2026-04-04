import Foundation
import GRDB

public struct DBDMLink: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName: String = "dmLink"

    public enum Columns {
        static let originConversationId: Column = Column(CodingKeys.originConversationId)
        static let memberInboxId: Column = Column(CodingKeys.memberInboxId)
        static let dmConversationId: Column = Column(CodingKeys.dmConversationId)
        static let convoTag: Column = Column(CodingKeys.convoTag)
        static let createdAt: Column = Column(CodingKeys.createdAt)
    }

    public let originConversationId: String
    public let memberInboxId: String
    public let dmConversationId: String
    public let convoTag: String
    public let createdAt: Date
}
