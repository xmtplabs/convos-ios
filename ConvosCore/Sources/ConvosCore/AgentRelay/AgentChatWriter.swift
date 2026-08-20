import Foundation
import GRDB

public protocol AgentChatWriterProtocol: Sendable {
    func insertPending(_ turn: AgentTurn) throws
    /// Upsert: inserts a completed row when none exists for `requestId`
    /// (a push for a turn another device minted), otherwise updates it.
    func markCompleted(requestId: String, result: AgentRelayTurnResult, provider: ExternalAgentProvider) throws
    func markFailed(requestId: String, errorCode: String) throws
    func markExpired(requestId: String) throws
    func markCollectedElsewhere(requestId: String) throws
    func markAcked(requestId: String) throws
    func deleteAll() throws
}

public final class AgentChatWriter: AgentChatWriterProtocol {
    private let database: AgentChatDatabase

    public init(database: AgentChatDatabase) {
        self.database = database
    }

    public func insertPending(_ turn: AgentTurn) throws {}

    public func markCompleted(requestId: String, result: AgentRelayTurnResult, provider: ExternalAgentProvider) throws {}

    public func markFailed(requestId: String, errorCode: String) throws {}

    public func markExpired(requestId: String) throws {}

    public func markCollectedElsewhere(requestId: String) throws {}

    public func markAcked(requestId: String) throws {}

    public func deleteAll() throws {}
}
