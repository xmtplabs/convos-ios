import Foundation
import GRDB

public protocol AgentChatRepositoryProtocol: Sendable {
    /// Newest last.
    func turns(limit: Int) throws -> [AgentTurn]
    func observeTurns(limit: Int) -> AsyncValueObservation<[AgentTurn]>
    func pendingTurns() throws -> [AgentTurn]
    func turn(requestId: String) throws -> AgentTurn?
}

public extension AgentChatRepositoryProtocol {
    func turnsStream(limit: Int) -> AsyncStream<[AgentTurn]> {
        let observation = observeTurns(limit: limit)
        return AsyncStream { continuation in
            let task = Task {
                do {
                    for try await value in observation {
                        continuation.yield(value)
                    }
                } catch {
                    Log.error("Agent turn observation failed")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

public final class AgentChatRepository: AgentChatRepositoryProtocol {
    private let database: AgentChatDatabase

    public init(database: AgentChatDatabase) {
        self.database = database
    }

    public func turns(limit: Int) throws -> [AgentTurn] {
        try database.pool.read { db in
            let newestFirst = try AgentTurn
                .order(Column("createdAt").desc)
                .limit(max(0, limit))
                .fetchAll(db)
            return Array(newestFirst.reversed())
        }
    }

    public func observeTurns(limit: Int) -> AsyncValueObservation<[AgentTurn]> {
        ValueObservation
            .tracking { db in
                let newestFirst = try AgentTurn
                    .order(Column("createdAt").desc)
                    .limit(max(0, limit))
                    .fetchAll(db)
                return Array(newestFirst.reversed())
            }
            .values(in: database.pool)
    }

    public func pendingTurns() throws -> [AgentTurn] {
        try database.pool.read { db in
            try AgentTurn
                .filter(Column("status") == AgentTurnStatus.pending.rawValue)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    public func turn(requestId: String) throws -> AgentTurn? {
        try database.pool.read { db in
            try AgentTurn.fetchOne(db, key: requestId)
        }
    }
}
