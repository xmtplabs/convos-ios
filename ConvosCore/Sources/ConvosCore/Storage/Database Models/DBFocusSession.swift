import Foundation
import GRDB

public enum DBFocusSessionState: String, Codable, Sendable {
    case started
    case stopped
}

public struct DBFocusSession: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName: String = "focusSession"

    public var sessionId: String
    public var conversationId: String
    public var focusedInboxId: String?
    public var state: DBFocusSessionState
    public var startedAt: Date
    public var stoppedAt: Date?

    public init(
        sessionId: String,
        conversationId: String,
        focusedInboxId: String?,
        state: DBFocusSessionState,
        startedAt: Date,
        stoppedAt: Date?
    ) {
        self.sessionId = sessionId
        self.conversationId = conversationId
        self.focusedInboxId = focusedInboxId
        self.state = state
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
    }
}
