import Foundation
import GRDB

public protocol AgentChatRepositoryProtocol: Sendable {
    /// Newest last.
    func turns(limit: Int) throws -> [AgentTurn]
    func observeTurns(limit: Int) -> AsyncValueObservation<[AgentTurn]>
    func pendingTurns() throws -> [AgentTurn]
    func turn(requestId: String) throws -> AgentTurn?
}

public final class AgentChatRepository: AgentChatRepositoryProtocol {
    private let database: AgentChatDatabase

    public init(database: AgentChatDatabase) {
        self.database = database
    }

    public func turns(limit: Int) throws -> [AgentTurn] {
        []
    }

    public func observeTurns(limit: Int) -> AsyncValueObservation<[AgentTurn]> {
        ValueObservation
            .tracking { _ in [AgentTurn]() }
            .values(in: database.pool)
    }

    public func pendingTurns() throws -> [AgentTurn] {
        []
    }

    public func turn(requestId: String) throws -> AgentTurn? {
        nil
    }
}
