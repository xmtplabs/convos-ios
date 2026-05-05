import Foundation
import GRDB

public struct DBLiveBubble: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName: String = "liveBubble"

    public var sessionId: String
    public var senderInboxId: String
    public var text: String
    public var revision: Int64
    public var updatedAt: Date

    public init(
        sessionId: String,
        senderInboxId: String,
        text: String,
        revision: Int64,
        updatedAt: Date
    ) {
        self.sessionId = sessionId
        self.senderInboxId = senderInboxId
        self.text = text
        self.revision = revision
        self.updatedAt = updatedAt
    }
}
