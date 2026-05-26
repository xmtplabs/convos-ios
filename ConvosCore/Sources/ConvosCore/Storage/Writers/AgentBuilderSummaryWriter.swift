import Foundation
import GRDB

public protocol AgentBuilderSummaryWriterProtocol: Sendable {
    func save(_ summary: AgentBuilderSummary, for conversationId: String) async throws
    func delete(for conversationId: String) async throws
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
}
