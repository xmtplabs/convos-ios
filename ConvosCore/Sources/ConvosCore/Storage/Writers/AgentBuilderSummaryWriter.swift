import Foundation
import GRDB

public protocol AgentBuilderSummaryWriterProtocol: Sendable {
    func save(_ summary: AgentBuilderSummary, for conversationId: String) async throws
    func delete(for conversationId: String) async throws
    /// Stamp the row's `connectionsAppliedAt` with the given timestamp.
    /// Idempotent — overwrites any existing value. Used by the replayer
    /// after a successful pass so subsequent launches don't re-fire grants
    /// the user may have manually revoked.
    func markConnectionsApplied(for conversationId: String, at date: Date) async throws
}

public final class AgentBuilderSummaryWriter: AgentBuilderSummaryWriterProtocol, Sendable {
    private let databaseWriter: any DatabaseWriter

    public init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    public func save(_ summary: AgentBuilderSummary, for conversationId: String) async throws {
        let record: DBAgentBuilderSummary = try summary.toDBAgentBuilderSummary(conversationId: conversationId)
        try await databaseWriter.write { db in
            try record.save(db)
        }
    }

    public func delete(for conversationId: String) async throws {
        try await databaseWriter.write { db in
            try DBAgentBuilderSummary.deleteOne(db, key: conversationId)
        }
    }

    public func markConnectionsApplied(for conversationId: String, at date: Date) async throws {
        try await databaseWriter.write { db in
            try db.execute(
                sql: "UPDATE agentBuilderSummary SET connectionsAppliedAt = ? WHERE conversationId = ?",
                arguments: [date, conversationId]
            )
        }
    }
}
