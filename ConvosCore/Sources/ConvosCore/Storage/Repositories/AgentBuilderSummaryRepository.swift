import Combine
import Foundation
import GRDB

public protocol AgentBuilderSummaryRepositoryProtocol: Sendable {
    /// One-shot fetch - used by `ConversationViewModel.loadInitialMessages`
    /// to hydrate the summary (before the initial message fetch, so the very
    /// first list emission already carries the summary card) without
    /// blocking the main thread.
    func summary(for conversationId: String) async throws -> AgentBuilderSummary?
    /// Reactive observation — emits the current row plus any subsequent
    /// inserts / deletes from the writer.
    func summaryPublisher(for conversationId: String) -> AnyPublisher<AgentBuilderSummary?, Never>
}

public final class AgentBuilderSummaryRepository: AgentBuilderSummaryRepositoryProtocol, Sendable {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func summary(for conversationId: String) async throws -> AgentBuilderSummary? {
        try await databaseReader.read { db in
            guard let record = try DBAgentBuilderSummary.fetchOne(db, key: conversationId) else { return nil }
            return try record.toAgentBuilderSummary()
        }
    }

    public func summaryPublisher(for conversationId: String) -> AnyPublisher<AgentBuilderSummary?, Never> {
        ValueObservation
            .tracking { db in
                try DBAgentBuilderSummary.fetchOne(db, key: conversationId)
            }
            .publisher(in: databaseReader)
            .map { record -> AgentBuilderSummary? in
                guard let record else { return nil }
                return try? record.toAgentBuilderSummary()
            }
            .replaceError(with: nil)
            .eraseToAnyPublisher()
    }
}
