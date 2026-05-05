import Combine
import Foundation

public final class MockFocusSessionRepository: FocusSessionRepositoryProtocol, @unchecked Sendable {
    private let sessionSubject: CurrentValueSubject<DBFocusSession?, Never> = .init(nil)
    private let bubblesSubject: CurrentValueSubject<[DBLiveBubble], Never> = .init([])

    public init() {}

    public func activeSession(in conversationId: String) async throws -> DBFocusSession? {
        sessionSubject.value
    }

    public func latestSessionPublisher(in conversationId: String) -> AnyPublisher<DBFocusSession?, Never> {
        sessionSubject.eraseToAnyPublisher()
    }

    public func liveBubblesPublisher(sessionId: String) -> AnyPublisher<[DBLiveBubble], Never> {
        bubblesSubject.eraseToAnyPublisher()
    }

    public func setSession(_ session: DBFocusSession?) {
        sessionSubject.send(session)
    }

    public func setBubbles(_ bubbles: [DBLiveBubble]) {
        bubblesSubject.send(bubbles)
    }
}
