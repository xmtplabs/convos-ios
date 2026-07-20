import Combine
import Foundation
import GRDB

public protocol AgentBuilderSummaryRepositoryProtocol: Sendable {
    /// One-shot fetch — used by `ConversationViewModel.init` to hydrate the
    /// summary the first time the view appears.
    func summary(for conversationId: String) async throws -> AgentBuilderSummary?
    /// Synchronous variant for view-construction paths that can't await — e.g.
    /// seeding `MessagesListRepository.agentBuilderSummary` *before*
    /// `fetchInitial()` so the very first list emission already carries the
    /// summary card. Without this, the publisher subscription fires a tick
    /// after `fetchInitial`, briefly flashing the raw pre-Make history.
    func summarySync(for conversationId: String) -> AgentBuilderSummary?
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

    public func summarySync(for conversationId: String) -> AgentBuilderSummary? {
        do {
            return try databaseReader.read { db in
                guard let record = try DBAgentBuilderSummary.fetchOne(db, key: conversationId) else { return nil }
                return try record.toAgentBuilderSummary()
            }
        } catch {
            Log.error("AgentBuilderSummaryRepository: summarySync failed for \(conversationId): \(error.localizedDescription)")
            return nil
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
