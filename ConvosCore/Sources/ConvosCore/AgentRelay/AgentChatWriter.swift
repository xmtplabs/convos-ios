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

protocol AgentTurnProviderReading: Sendable {
    func provider(requestId: String) throws -> ExternalAgentProvider?
}

public final class AgentChatWriter: AgentChatWriterProtocol, AgentTurnProviderReading {
    private let database: AgentChatDatabase

    public init(database: AgentChatDatabase) {
        self.database = database
    }

    public func insertPending(_ turn: AgentTurn) throws {
        try database.pool.write { db in
            try turn.insert(db)
        }
    }

    func provider(requestId: String) throws -> ExternalAgentProvider? {
        try database.pool.read { db in
            try AgentTurn.fetchOne(db, key: requestId)?.provider
        }
    }

    public func markCompleted(requestId: String, result: AgentRelayTurnResult, provider: ExternalAgentProvider) throws {
        try database.pool.write { db in
            guard var turn = try AgentTurn.fetchOne(db, key: requestId) else {
                let completedTurn = AgentTurn(
                    requestId: requestId,
                    provider: provider,
                    status: .completed,
                    prompt: Constant.collectedElsewherePrompt,
                    resultMessage: result.message,
                    resultLinks: result.links,
                    createdAt: result.completedAt,
                    expiresAt: result.completedAt,
                    completedAt: result.completedAt
                )
                try completedTurn.insert(db)
                return
            }
            guard turn.status != .completed else { return }

            // Existing rows keep their stored provider; this argument is only used when inserting.
            turn.status = .completed
            turn.resultMessage = result.message
            turn.resultLinks = result.links
            turn.errorCode = nil
            turn.completedAt = result.completedAt
            try turn.update(db)
        }
    }

    public func markFailed(requestId: String, errorCode: String) throws {
        try updateExisting(requestId: requestId) { turn in
            guard turn.status == .pending else { return }
            turn.status = .failed
            turn.errorCode = errorCode
        }
    }

    public func markExpired(requestId: String) throws {
        try updateExisting(requestId: requestId) { turn in
            guard turn.status == .pending else { return }
            turn.status = .expired
            turn.errorCode = nil
        }
    }

    public func markCollectedElsewhere(requestId: String) throws {
        try updateExisting(requestId: requestId) { turn in
            guard turn.status == .pending else { return }
            turn.status = .collectedElsewhere
            turn.errorCode = nil
        }
    }

    public func markAcked(requestId: String) throws {
        try updateExisting(requestId: requestId) { turn in
            turn.ackedAt = Date()
        }
    }

    public func deleteAll() throws {
        try database.pool.write { db in
            _ = try AgentTurn.deleteAll(db)
        }
    }

    private func updateExisting(requestId: String, changes: (inout AgentTurn) -> Void) throws {
        try database.pool.write { db in
            guard var turn = try AgentTurn.fetchOne(db, key: requestId) else {
                Log.warning("Agent turn update ignored for missing request \(requestId.prefix(12))")
                return
            }
            changes(&turn)
            try turn.update(db)
        }
    }

    private enum Constant {
        static let collectedElsewherePrompt: String = "(completed on another device)"
    }
}
