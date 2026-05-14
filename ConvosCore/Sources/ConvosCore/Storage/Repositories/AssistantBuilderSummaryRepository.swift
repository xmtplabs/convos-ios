import Combine
import Foundation
import GRDB

public protocol AssistantBuilderSummaryRepositoryProtocol: Sendable {
    /// One-shot fetch — used by `ConversationViewModel.init` to hydrate the
    /// summary the first time the view appears.
    func summary(for conversationId: String) async throws -> AssistantBuilderSummary?
    /// Synchronous variant for view-construction paths that can't await — e.g.
    /// seeding `MessagesListRepository.assistantBuilderSummary` *before*
    /// `fetchInitial()` so the very first list emission already carries the
    /// summary card. Without this, the publisher subscription fires a tick
    /// after `fetchInitial`, briefly flashing the raw pre-Make history.
    func summarySync(for conversationId: String) -> AssistantBuilderSummary?
    /// Reactive observation — emits the current row plus any subsequent
    /// inserts / deletes from the writer.
    func summaryPublisher(for conversationId: String) -> AnyPublisher<AssistantBuilderSummary?, Never>
}

public final class AssistantBuilderSummaryRepository: AssistantBuilderSummaryRepositoryProtocol, Sendable {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func summary(for conversationId: String) async throws -> AssistantBuilderSummary? {
        try await databaseReader.read { db in
            guard let record = try DBAssistantBuilderSummary.fetchOne(db, key: conversationId) else { return nil }
            return try record.toAssistantBuilderSummary()
        }
    }

    public func summarySync(for conversationId: String) -> AssistantBuilderSummary? {
        do {
            return try databaseReader.read { db in
                guard let record = try DBAssistantBuilderSummary.fetchOne(db, key: conversationId) else { return nil }
                return try record.toAssistantBuilderSummary()
            }
        } catch {
            Log.error("AssistantBuilderSummaryRepository: summarySync failed for \(conversationId): \(error.localizedDescription)")
            return nil
        }
    }

    public func summaryPublisher(for conversationId: String) -> AnyPublisher<AssistantBuilderSummary?, Never> {
        ValueObservation
            .tracking { db in
                try DBAssistantBuilderSummary.fetchOne(db, key: conversationId)
            }
            .publisher(in: databaseReader)
            .map { record -> AssistantBuilderSummary? in
                guard let record else { return nil }
                return try? record.toAssistantBuilderSummary()
            }
            .replaceError(with: nil)
            .eraseToAnyPublisher()
    }
}
