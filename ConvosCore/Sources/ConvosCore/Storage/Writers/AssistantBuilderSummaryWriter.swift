import Foundation
import GRDB

public protocol AssistantBuilderSummaryWriterProtocol: Sendable {
    func save(_ summary: AssistantBuilderSummary, for conversationId: String) async throws
    func delete(for conversationId: String) async throws
}

public final class AssistantBuilderSummaryWriter: AssistantBuilderSummaryWriterProtocol, Sendable {
    private let databaseWriter: any DatabaseWriter

    public init(databaseWriter: any DatabaseWriter) {
        self.databaseWriter = databaseWriter
    }

    public func save(_ summary: AssistantBuilderSummary, for conversationId: String) async throws {
        let record: DBAssistantBuilderSummary = try summary.toDBAssistantBuilderSummary(conversationId: conversationId)
        try await databaseWriter.write { db in
            try record.save(db)
        }
    }

    public func delete(for conversationId: String) async throws {
        try await databaseWriter.write { db in
            try DBAssistantBuilderSummary.deleteOne(db, key: conversationId)
        }
    }
}
