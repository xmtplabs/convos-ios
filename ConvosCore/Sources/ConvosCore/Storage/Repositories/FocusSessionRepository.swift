import Combine
import Foundation
import GRDB

public protocol FocusSessionRepositoryProtocol: Sendable {
    /// One-shot fetch of the most recent `started` session for a conversation,
    /// or nil if none is active.
    func activeSession(in conversationId: String) async throws -> DBFocusSession?

    /// Publishes the most recent session for a conversation regardless of
    /// state. Callers inspect `state` to decide whether to render the focus
    /// canvas (`.started`) or the end-of-session CTA (`.stopped`).
    func latestSessionPublisher(in conversationId: String) -> AnyPublisher<DBFocusSession?, Never>

    /// Publishes the live bubble snapshots for a given session.
    func liveBubblesPublisher(sessionId: String) -> AnyPublisher<[DBLiveBubble], Never>
}

public final class FocusSessionRepository: FocusSessionRepositoryProtocol, Sendable {
    private let databaseReader: any DatabaseReader

    public init(databaseReader: any DatabaseReader) {
        self.databaseReader = databaseReader
    }

    public func activeSession(in conversationId: String) async throws -> DBFocusSession? {
        try await databaseReader.read { db in
            try DBFocusSession
                .filter(Column("conversationId") == conversationId
                        && Column("state") == DBFocusSessionState.started.rawValue)
                .order(Column("startedAt").desc)
                .fetchOne(db)
        }
    }

    public func latestSessionPublisher(in conversationId: String) -> AnyPublisher<DBFocusSession?, Never> {
        ValueObservation
            .tracking { db in
                try DBFocusSession
                    .filter(Column("conversationId") == conversationId)
                    .order(Column("startedAt").desc)
                    .fetchOne(db)
            }
            .publisher(in: databaseReader, scheduling: .immediate)
            .replaceError(with: nil)
            .eraseToAnyPublisher()
    }

    public func liveBubblesPublisher(sessionId: String) -> AnyPublisher<[DBLiveBubble], Never> {
        ValueObservation
            .tracking { db in
                try DBLiveBubble
                    .filter(Column("sessionId") == sessionId)
                    .fetchAll(db)
            }
            .publisher(in: databaseReader, scheduling: .immediate)
            .replaceError(with: [])
            .eraseToAnyPublisher()
    }
}
